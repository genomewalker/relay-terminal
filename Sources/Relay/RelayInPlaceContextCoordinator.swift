import Foundation
import CryptoKit

/// A conversation may change after /clear; the host, pane and kernel process
/// incarnation must remain the same throughout the transition.
struct RelayInPlaceContextBinding: Codable, Equatable, Sendable {
    let hostID: String
    let paneID: String
    let pid: Int
    let processStart: String
    let cwd: String

    var valid: Bool {
        !hostID.isEmpty && !paneID.isEmpty && pid > 0 && !processStart.isEmpty && cwd.hasPrefix("/")
    }
}

struct RelayInPlaceContextState: Codable, Equatable, Sendable {
    let binding: RelayInPlaceContextBinding
    let sessionID: String
    let generation: String
    let completedTurnID: String
    let idle: Bool
    let inputEmpty: Bool
    let noRunningTools: Bool
    let promptReady: Bool

    var ready: Bool {
        binding.valid && !sessionID.isEmpty && !generation.isEmpty && !completedTurnID.isEmpty
            && idle && inputEmpty && noRunningTools && promptReady
    }
}

struct RelayInPlaceContextCapsule: Codable, Equatable, Sendable {
    let transitionID: String
    let sourceSessionID: String
    let sourceTurnID: String
    let revision: Int
    let sha256: String
    let body: Data

    var valid: Bool {
        !transitionID.isEmpty && transitionID.utf8.count <= 200
            && !sourceSessionID.isEmpty && !sourceTurnID.isEmpty && revision > 0
            && !body.isEmpty && body.count <= 65_536
            && sha256 == SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }
}

struct RelayInPlaceClearReceipt: Codable, Equatable, Sendable {
    let transitionID: String
    let binding: RelayInPlaceContextBinding
    let sourceGeneration: String
    let clearedGeneration: String
    let sessionID: String
}

struct RelayInPlaceRestoreReceipt: Codable, Equatable, Sendable {
    let clear: RelayInPlaceClearReceipt
    let capsuleRevision: Int
    let capsuleSHA256: String
    let completedTurnID: String
}

/// Implementations use native session/hook evidence. An echoed command or
/// digest is not an acknowledgement. Gate operations are idempotent for this
/// transition; a gate must never release another transition's queued input.
protocol RelayInPlaceContextHost: Sendable {
    func state(binding: RelayInPlaceContextBinding) async throws -> RelayInPlaceContextState
    func verifyDurableCapsule(_ capsule: RelayInPlaceContextCapsule) async throws -> Bool
    func acquireInputGate(binding: RelayInPlaceContextBinding, transitionID: String) async throws
    /// Compare the exact source generation, kernel identity and clean prompt
    /// atomically immediately before submitting /clear. Do not retry transport.
    func clearOnce(source: RelayInPlaceContextState, transitionID: String) async throws
    /// Observe a SessionStart(clear) or equivalent native acknowledgement.
    func clearReceipt(source: RelayInPlaceContextState, transitionID: String) async throws -> RelayInPlaceClearReceipt?
    /// Compare the cleared generation and process identity before submitting.
    func restoreOnce(_ capsule: RelayInPlaceContextCapsule, clear: RelayInPlaceClearReceipt) async throws
    /// Prove the exact durable capsule was imported and its first turn completed.
    func restoreReceipt(_ capsule: RelayInPlaceContextCapsule, clear: RelayInPlaceClearReceipt) async throws -> RelayInPlaceRestoreReceipt?
    func releaseInputGate(binding: RelayInPlaceContextBinding, receipt: RelayInPlaceRestoreReceipt) async throws
}

enum RelayInPlaceContextResult: Equatable, Sendable {
    case completed(RelayInPlaceRestoreReceipt)
    case pendingClearAcknowledgement
    case pendingRestoreAcknowledgement
    case reconciliationRequired
    case unavailable
}

/// Uses the existing durable action store. Unknown command outcomes remain
/// claimed; subsequent calls reconcile receipts and never submit them again.
actor RelayInPlaceContextCoordinator {
    private let host: any RelayInPlaceContextHost
    private let actions: RelayClaudeRotationActionStore
    private var operating = false

    init(host: any RelayInPlaceContextHost, actions: RelayClaudeRotationActionStore) {
        self.host = host
        self.actions = actions
    }

    func transition(binding: RelayInPlaceContextBinding,
                    capsule: RelayInPlaceContextCapsule) async -> RelayInPlaceContextResult {
        guard !operating, binding.valid, capsule.valid else { return .unavailable }
        operating = true
        defer { operating = false }
        do {
            // Exclude the body from the manifest: its digest and durable storage
            // acknowledgement bind it without exceeding the action-store limit.
            let fingerprint = try digest([binding.hostID, binding.paneID, String(binding.pid),
                binding.processStart, binding.cwd, capsule.sourceSessionID, capsule.sourceTurnID,
                String(capsule.revision), capsule.sha256])
            let intent = capsule.transitionID
            guard try await host.verifyDurableCapsule(capsule) else { return .unavailable }
            let source: RelayInPlaceContextState
            if let manifest = try actions.read(intent: intent, action: "inplace-source"), manifest.completed {
                guard manifest.fingerprint == fingerprint, let data = manifest.result else {
                    return .reconciliationRequired
                }
                source = try JSONDecoder().decode(RelayInPlaceContextState.self, from: data)
            } else {
                source = try await host.state(binding: binding)
                guard source.binding == binding, source.ready,
                      source.sessionID == capsule.sourceSessionID,
                      source.completedTurnID == capsule.sourceTurnID else { return .unavailable }
                try claimMatching(intent: intent, action: "inplace-source", fingerprint: fingerprint)
                try actions.complete(intent: intent, action: "inplace-source", fingerprint: fingerprint,
                                     result: JSONEncoder().encode(source))
            }
            guard source.binding == binding, source.ready,
                  source.sessionID == capsule.sourceSessionID,
                  source.completedTurnID == capsule.sourceTurnID else { return .reconciliationRequired }
            try await host.acquireInputGate(binding: binding, transitionID: intent)
            guard try await host.state(binding: binding).binding == binding else { return .reconciliationRequired }

            let clear: RelayInPlaceClearReceipt
            if let saved = try result(RelayInPlaceClearReceipt.self, intent: intent,
                                      action: "inplace-clear", fingerprint: fingerprint) {
                clear = saved
            } else {
                // A claim is durable before any bytes reach the CLI. Failure
                // after this line can only be reconciled by native observation.
                if try actions.claim(intent: intent, action: "inplace-clear", fingerprint: fingerprint) {
                    try await host.clearOnce(source: source, transitionID: intent)
                } else {
                    try claimMatching(intent: intent, action: "inplace-clear", fingerprint: fingerprint)
                }
                guard let observed = try await host.clearReceipt(source: source, transitionID: intent) else {
                    return .pendingClearAcknowledgement
                }
                clear = observed
            }
            guard clear.transitionID == intent, clear.binding == binding,
                  clear.sourceGeneration == source.generation,
                  !clear.clearedGeneration.isEmpty, clear.clearedGeneration != source.generation,
                  !clear.sessionID.isEmpty else { return .reconciliationRequired }
            try actions.complete(intent: intent, action: "inplace-clear", fingerprint: fingerprint,
                                 result: JSONEncoder().encode(clear))

            let restored: RelayInPlaceRestoreReceipt
            if let saved = try result(RelayInPlaceRestoreReceipt.self, intent: intent,
                                      action: "inplace-restore", fingerprint: fingerprint) {
                restored = saved
            } else {
                if try actions.claim(intent: intent, action: "inplace-restore", fingerprint: fingerprint) {
                    try await host.restoreOnce(capsule, clear: clear)
                } else {
                    try claimMatching(intent: intent, action: "inplace-restore", fingerprint: fingerprint)
                }
                guard let observed = try await host.restoreReceipt(capsule, clear: clear) else {
                    return .pendingRestoreAcknowledgement
                }
                restored = observed
            }
            guard restored.clear == clear, restored.capsuleRevision == capsule.revision,
                  restored.capsuleSHA256 == capsule.sha256, !restored.completedTurnID.isEmpty,
                  restored.completedTurnID != source.completedTurnID else { return .reconciliationRequired }
            try actions.complete(intent: intent, action: "inplace-restore", fingerprint: fingerprint,
                                 result: JSONEncoder().encode(restored))
            try await host.releaseInputGate(binding: binding, receipt: restored)
            return .completed(restored)
        } catch {
            return .reconciliationRequired
        }
    }

    private func digest(_ fields: [String]) throws -> String {
        let data = try JSONEncoder().encode(fields)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func claimMatching(intent: String, action: String, fingerprint: String) throws {
        if try actions.claim(intent: intent, action: action, fingerprint: fingerprint) { return }
        guard try actions.read(intent: intent, action: action)?.fingerprint == fingerprint else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }

    private func result<T: Decodable>(_ type: T.Type, intent: String, action: String,
                                      fingerprint: String) throws -> T? {
        guard let record = try actions.read(intent: intent, action: action) else { return nil }
        guard record.fingerprint == fingerprint else { throw RelayRotationAdapterError.mismatchedEvidence }
        guard record.completed else { return nil }
        guard let data = record.result else { throw RelayRotationAdapterError.mismatchedEvidence }
        return try JSONDecoder().decode(type, from: data)
    }
}

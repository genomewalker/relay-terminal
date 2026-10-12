import Foundation

/// Stable identity for one agent incarnation. A reconnect or replacement must
/// receive a new generation so a delayed decision cannot target its successor.
struct RelaySupervisedSessionID: Hashable, Codable, Sendable {
    let paneID: UUID
    let sessionID: String
    let generation: UInt64
}

struct RelaySupervisorTelemetry: Equatable, Sendable {
    let identity: RelaySupervisedSessionID
    let observedAt: Date
    let hasActiveRequest: Bool
    let isReachable: Bool
    let outputBytesPerMinute: Int
    let retriesInWindow: Int
    let secondsSinceProgress: TimeInterval
    let contextTokens: Int?
    let contextLimit: Int?
    let restartsInWindow: Int
    let hasDurableCheckpoint: Bool
}

enum RelaySupervisorStage: Int, Codable, Comparable, Sendable {
    case observe
    case warn
    case stopNewWork
    case requestCheckpoint
    case gracefulInterrupt
    case terminateOrRestart

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var changesRuntimeState: Bool { self >= .stopNewWork }
}

enum RelaySupervisorFinding: String, Codable, Hashable, Sendable {
    case retryLoop
    case runawayOutput
    case stalled
    case tokenPressure
    case restartStorm
    case unreachable
}

struct RelaySupervisorRecommendation: Equatable, Sendable {
    let identity: RelaySupervisedSessionID
    let stage: RelaySupervisorStage
    let findings: Set<RelaySupervisorFinding>
    let observedAt: Date
    let requiresUserApproval: Bool
    let mayExecuteAutomatically: Bool
}

enum RelaySupervisorReceiptState: String, Codable, Sendable {
    case proposed
    case approved
    case rejected
    case expired
    case staleIdentity
}

enum RelaySupervisorExecutionCapability: String, Codable, Hashable, Sendable {
    case gracefulInterrupt
}

enum RelaySupervisorExecutionCommand: Equatable, Sendable {
    case gracefulInterrupt
}

enum RelaySupervisorExecutionRejection: Error, Equatable, Sendable {
    case alreadyConsumed
    case notApproved
    case expired
    case staleIdentity
    case unreachable
    case unsupportedStage
    case missingCapability
}

struct RelaySupervisorExecutionClaim: Equatable, Sendable {
    let receiptID: UUID
    let identity: RelaySupervisedSessionID
    let command: RelaySupervisorExecutionCommand
    let claimedAt: Date
}

struct RelaySupervisorActionReceipt: Equatable, Identifiable, Sendable {
    let id: UUID
    let identity: RelaySupervisedSessionID
    let stage: RelaySupervisorStage
    let createdAt: Date
    let expiresAt: Date
    var resolvedAt: Date?
    var state: RelaySupervisorReceiptState
}

/// Records the user's lifecycle decision without performing it. A separate
/// executor may consume an approved receipt exactly once after revalidating the
/// current session identity and its own capability policy.
struct RelaySupervisorActionBroker: Sendable {
    private(set) var receipts: [UUID: RelaySupervisorActionReceipt] = [:]

    mutating func propose(
        _ recommendation: RelaySupervisorRecommendation,
        now: Date = Date(),
        lifetime: TimeInterval = 60
    ) -> RelaySupervisorActionReceipt? {
        guard recommendation.stage.changesRuntimeState,
              recommendation.requiresUserApproval,
              !recommendation.mayExecuteAutomatically else { return nil }
        let receipt = RelaySupervisorActionReceipt(
            id: UUID(), identity: recommendation.identity, stage: recommendation.stage,
            createdAt: now, expiresAt: now.addingTimeInterval(lifetime),
            resolvedAt: nil, state: .proposed
        )
        receipts[receipt.id] = receipt
        return receipt
    }

    mutating func resolve(
        _ id: UUID,
        approve: Bool,
        currentIdentity: RelaySupervisedSessionID,
        now: Date = Date()
    ) -> RelaySupervisorActionReceipt? {
        guard var receipt = receipts[id], receipt.state == .proposed else { return nil }
        receipt.resolvedAt = now
        if now >= receipt.expiresAt {
            receipt.state = .expired
        } else if currentIdentity != receipt.identity {
            receipt.state = .staleIdentity
        } else {
            receipt.state = approve ? .approved : .rejected
        }
        receipts[id] = receipt
        return receipt
    }
}

/// The narrow execution boundary for approved lifecycle receipts. Every
/// receipt gets at most one claim attempt, including rejected attempts, so a
/// reconnect or UI retry cannot turn stale approval into a later side effect.
/// Capabilities describe concrete operations available on the exact live pane;
/// a recommendation alone never creates one.
struct RelaySupervisorActionExecutor: Sendable {
    private var consumedReceiptIDs = Set<UUID>()

    mutating func claim(
        _ receipt: RelaySupervisorActionReceipt,
        currentIdentity: RelaySupervisedSessionID,
        isReachable: Bool,
        capabilities: Set<RelaySupervisorExecutionCapability>,
        now: Date = Date()
    ) -> Result<RelaySupervisorExecutionClaim, RelaySupervisorExecutionRejection> {
        guard consumedReceiptIDs.insert(receipt.id).inserted else {
            return .failure(.alreadyConsumed)
        }
        guard receipt.state == .approved else { return .failure(.notApproved) }
        guard now < receipt.expiresAt else { return .failure(.expired) }
        guard currentIdentity == receipt.identity else { return .failure(.staleIdentity) }
        guard isReachable else { return .failure(.unreachable) }

        let command: RelaySupervisorExecutionCommand
        let capability: RelaySupervisorExecutionCapability
        switch receipt.stage {
        case .gracefulInterrupt:
            command = .gracefulInterrupt
            capability = .gracefulInterrupt
        case .observe, .warn, .stopNewWork, .requestCheckpoint, .terminateOrRestart:
            return .failure(.unsupportedStage)
        }
        guard capabilities.contains(capability) else { return .failure(.missingCapability) }
        return .success(RelaySupervisorExecutionClaim(
            receiptID: receipt.id,
            identity: receipt.identity,
            command: command,
            claimedAt: now
        ))
    }
}

struct RelaySupervisorConfiguration: Equatable, Sendable {
    var warningRetries = 5
    var severeRetries = 12
    var warningOutputBytesPerMinute = 20 * 1_024 * 1_024
    var severeOutputBytesPerMinute = 100 * 1_024 * 1_024
    var stalledSeconds: TimeInterval = 120
    var warningTokenFraction = 0.80
    var severeTokenFraction = 0.92
    var warningRestarts = 3
    var severeRestarts = 6
    var escalationCooldown: TimeInterval = 30
    var recoverySamples = 3
}

/// Deterministic authority boundary for the local supervisor. Models may rank
/// or explain the returned findings, but they cannot raise `stage`, change the
/// target identity, or execute a lifecycle action.
struct RelaySessionSupervisor: Sendable {
    private struct State: Sendable {
        var stage: RelaySupervisorStage = .observe
        var lastTransitionAt: Date?
        var healthySamples = 0
    }

    let configuration: RelaySupervisorConfiguration
    private var states: [RelaySupervisedSessionID: State] = [:]

    init(configuration: RelaySupervisorConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func evaluate(_ telemetry: RelaySupervisorTelemetry) -> RelaySupervisorRecommendation {
        var state = states[telemetry.identity] ?? State()
        let findings = findings(for: telemetry)

        if findings.isEmpty {
            state.healthySamples += 1
            if state.healthySamples >= configuration.recoverySamples {
                state.stage = .observe
                state.lastTransitionAt = telemetry.observedAt
                state.healthySamples = 0
            }
        } else {
            state.healthySamples = 0
            let requested = requestedStage(for: telemetry, findings: findings)
            let cooldownElapsed = state.lastTransitionAt.map {
                telemetry.observedAt.timeIntervalSince($0) >= configuration.escalationCooldown
            } ?? true
            if requested > state.stage, cooldownElapsed {
                // Escalation is deliberately one rung per fresh observation.
                state.stage = RelaySupervisorStage(rawValue: state.stage.rawValue + 1) ?? .terminateOrRestart
                state.lastTransitionAt = telemetry.observedAt
            } else if requested < state.stage {
                // A less severe sample does not silently revoke a safeguard.
                // Recovery requires consecutive fully healthy observations.
            }
        }

        states[telemetry.identity] = state
        return RelaySupervisorRecommendation(
            identity: telemetry.identity,
            stage: state.stage,
            findings: findings,
            observedAt: telemetry.observedAt,
            requiresUserApproval: state.stage.changesRuntimeState,
            mayExecuteAutomatically: false
        )
    }

    mutating func forget(_ identity: RelaySupervisedSessionID) {
        states.removeValue(forKey: identity)
    }

    /// Accepts model output only as an ordering/explanation hint. It can never
    /// create authority or increase severity beyond deterministic evidence.
    func boundedModelSuggestion(
        _ suggested: RelaySupervisorStage,
        for recommendation: RelaySupervisorRecommendation,
        identity: RelaySupervisedSessionID
    ) -> RelaySupervisorStage? {
        guard identity == recommendation.identity,
              suggested <= recommendation.stage else { return nil }
        return suggested
    }

    private func findings(for telemetry: RelaySupervisorTelemetry) -> Set<RelaySupervisorFinding> {
        var result = Set<RelaySupervisorFinding>()
        if telemetry.retriesInWindow >= configuration.warningRetries { result.insert(.retryLoop) }
        if telemetry.outputBytesPerMinute >= configuration.warningOutputBytesPerMinute { result.insert(.runawayOutput) }
        if telemetry.hasActiveRequest && telemetry.secondsSinceProgress >= configuration.stalledSeconds { result.insert(.stalled) }
        if let tokens = telemetry.contextTokens, let limit = telemetry.contextLimit, limit > 0,
           Double(tokens) / Double(limit) >= configuration.warningTokenFraction { result.insert(.tokenPressure) }
        if telemetry.restartsInWindow >= configuration.warningRestarts { result.insert(.restartStorm) }
        if !telemetry.isReachable { result.insert(.unreachable) }
        return result
    }

    private func requestedStage(
        for telemetry: RelaySupervisorTelemetry,
        findings: Set<RelaySupervisorFinding>
    ) -> RelaySupervisorStage {
        var severe = telemetry.retriesInWindow >= configuration.severeRetries ||
            telemetry.outputBytesPerMinute >= configuration.severeOutputBytesPerMinute ||
            telemetry.restartsInWindow >= configuration.severeRestarts
        if let tokens = telemetry.contextTokens, let limit = telemetry.contextLimit, limit > 0 {
            severe = severe || Double(tokens) / Double(limit) >= configuration.severeTokenFraction
        }
        if !telemetry.isReachable { return .warn }
        if severe && telemetry.hasDurableCheckpoint { return .gracefulInterrupt }
        if severe { return .requestCheckpoint }
        if findings.contains(.stalled) || findings.contains(.tokenPressure) { return .requestCheckpoint }
        return .warn
    }
}

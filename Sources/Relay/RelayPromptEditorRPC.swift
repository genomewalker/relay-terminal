import CryptoKit
import Foundation

struct RelayPromptEditorControlLease: Equatable, Sendable {
    let connectionID: UUID
    let clientID: UUID
    let hostID: UUID
    let paneID: UUID
}

enum RelayPromptEditorLeasePolicy {
    static func admits(attached: Bool, detached: Bool, writerAvailable: Bool,
        controlGranted: Bool, observer: Bool, acknowledgedInput: Bool,
        pendingInput: Bool, overflowed: Bool) -> Bool {
        attached && !detached && writerAvailable && controlGranted && !observer &&
            acknowledgedInput && !pendingInput && !overflowed
    }
}

enum RelayPromptEditorRPC {
    static let maximumDraftBytes = 1 << 20

    enum Operation: String, Codable, Sendable { case arm, snapshot, commit, cancel, receipt }
    enum State: String, Codable, Sendable {
        case armed, captured, committed, cancelled, delivered, refused, unarmed, unavailable, busy, applied, failed
    }
    struct Request: Encodable, Sendable {
        let operation: Operation
        let id: String
        let owner: RelayPromptOwnerBinding
        var digest: String? = nil
        var text: Data? = nil

        var isValid: Bool {
            guard owner.provider == "claude", id.utf8.count == 32,
                  id.allSatisfy({ "0123456789abcdef".contains($0) }),
                  text.map({ $0.count <= maximumDraftBytes && String(data: $0, encoding: .utf8) != nil && !$0.contains(0) }) ?? true else { return false }
            let validDigest = digest.map { $0.utf8.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } } ?? false
            switch operation {
            case .commit: return text != nil && validDigest
            case .receipt: return text == nil && validDigest
            case .arm, .snapshot, .cancel: return text == nil && digest == nil
            }
        }
    }
    struct Response: Decodable, Equatable, Sendable {
        let owner: RelayPromptOwnerBinding?
        let state: State
        let id: String?
        let digest: String?
        let text: Data?
        let apply: Bool?
        let message: String?
        var unsupported: Bool? = nil

        func isExplicitlyUnsupported(for request: Request) -> Bool {
            request.operation == .arm && state == .unavailable && unsupported == true &&
                id == request.id && owner == request.owner
        }

        func isValid(for request: Request) -> Bool {
            guard unsupported != true || isExplicitlyUnsupported(for: request) else { return false }
            guard id == nil || id == request.id,
                  owner == nil || owner == request.owner,
                  (message?.utf8.count ?? 0) <= 8192,
                  (text?.count ?? 0) <= maximumDraftBytes else { return false }
            switch state {
            case .captured:
                guard request.operation == .snapshot, id == request.id,
                      let text, let digest,
                      String(data: text, encoding: .utf8) != nil, !text.contains(0) else { return false }
                return digest == RelayPromptEditorRPC.digest(text)
            case .applied:
                guard request.operation == .receipt, id == request.id,
                      let digest, digest.utf8.count == 64 else { return false }
                return digest.allSatisfy { "0123456789abcdef".contains($0) } && digest == request.digest
            case .armed: return request.operation == .arm && id == request.id
            case .committed: return request.operation == .commit && id == request.id
            case .cancelled: return id == request.id
            case .delivered, .failed: return request.operation == .receipt && id == request.id
            case .refused, .unarmed, .unavailable, .busy: return true
            }
        }
    }
    enum Failure: LocalizedError {
        case invalidRequest, changedConnection, invalidResponse
        var errorDescription: String? {
            switch self {
            case .invalidRequest: "The editor request is invalid."
            case .changedConnection: "The pane input connection changed."
            case .invalidResponse: "The prompt editor response could not be verified."
            }
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor static func send(_ request: Request, profile: ConnectionProfile,
        lease: RelayPromptEditorControlLease,
        currentLease: () -> RelayPromptEditorControlLease?) async throws -> Response {
        guard request.isValid, request.owner.isValid(for: lease.paneID),
              profile.id == lease.hostID, profile.backend == .relay else { throw Failure.invalidRequest }
        try Task.checkCancellation()
        guard currentLease() == lease else { throw Failure.changedConnection }
        let command = RelayHostExecution.daemonCommand(profile: profile,
            arguments: ["prompt-editor-rpc", lease.paneID.uuidString.lowercased(), lease.clientID.uuidString.lowercased()])
        // HostExecution preserves uncertain job handles. Never retry a write
        // after a transport exception, including an arm/commit/cancel request.
        let result = try await RelayHostExecution.capture(profile: profile, command: command,
            input: JSONEncoder().encode(request), timeout: 30, maximumBytes: 2 << 20)
        try Task.checkCancellation()
        guard currentLease() == lease else { throw Failure.changedConnection }
        guard result.exitCode == 0 else { throw Failure.invalidResponse }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: result.stdout)
        guard response.isValid(for: request) else { throw Failure.invalidResponse }
        return response
    }
}

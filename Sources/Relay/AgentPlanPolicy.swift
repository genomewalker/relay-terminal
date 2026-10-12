import Foundation

/// Provider mode is evidence, not permission. Adapters must supply structured
/// events; terminal text is never parsed into an execution grant.
enum RelayAgentMode: String, Codable, Sendable {
    case unknown, plan, execute
}

struct RelayAgentPlanState: Equatable, Sendable {
    let sessionID: String
    let connectionGeneration: UInt64
    private(set) var sequence: UInt64 = 0
    private(set) var mode: RelayAgentMode = .unknown
    private(set) var revision: String?

    init(sessionID: String, connectionGeneration: UInt64) {
        self.sessionID = sessionID
        self.connectionGeneration = connectionGeneration
    }

    /// Reject messages for another session, a previous connection, and replay.
    @discardableResult
    mutating func apply(sessionID: String, generation: UInt64, sequence: UInt64,
                        mode: RelayAgentMode, revision: String?) -> Bool {
        guard sessionID == self.sessionID, generation == connectionGeneration,
              sequence > self.sequence,
              revision.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { return false }
        self.sequence = sequence
        self.mode = mode
        self.revision = revision
        return true
    }

    func allowsExecution(grant: RelayAgentExecutionGrant?, paneID: UUID,
                         requestID: UUID, now: Date) -> Bool {
        guard mode == .execute, let revision, let grant else { return false }
        return grant.paneID == paneID && grant.sessionID == sessionID &&
            grant.connectionGeneration == connectionGeneration &&
            grant.planRevision == revision && grant.requestID == requestID &&
            grant.expiresAt > now
    }
}

/// Construct only following a trusted native approval action. The future
/// execution broker must consume grants once and retain request receipts.
struct RelayAgentExecutionGrant: Equatable, Sendable {
    let paneID: UUID
    let sessionID: String
    let connectionGeneration: UInt64
    let planRevision: String
    let requestID: UUID
    let expiresAt: Date
}

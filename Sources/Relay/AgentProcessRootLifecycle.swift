import Foundation

struct AgentProcessRootObservation: Codable, Sendable {
    let provider: String
    let source: String?
    let sequence: UInt64
    let occurredAt: Date
}

struct PersistedAgentProcessRoot: Codable, Sendable {
    let id: String
    let kind: AgentKind
    let observation: AgentProcessRootObservation
}

enum AgentProcessRootLifecycle {
    static func canRetire(_ observation: AgentProcessRootObservation?, sequence: UInt64,
        occurredAt: Date) -> Bool {
        guard let observation else { return true }
        if sequence != 0 && observation.sequence != 0 { return observation.sequence <= sequence }
        return observation.occurredAt <= occurredAt
    }

    static func legacyEndedRoots(rootID: String, provider: String, source: String?,
        sequence: UInt64, occurredAt: Date,
        observations: [String: AgentProcessRootObservation]) -> [String] {
        guard source == "process-tree" else { return [] }
        let parts = rootID.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == provider, parts[2] == "unavailable",
              let pid = Int(parts[1]), pid > 0 else { return [] }
        let prefix = "\(parts[0]):\(parts[1]):"
        return observations.compactMap { candidate, observation in
            guard candidate.hasPrefix(prefix), observation.source == "process-tree",
                  observation.provider == provider else { return nil }
            if sequence != 0 && observation.sequence != 0 {
                guard observation.sequence <= sequence else { return nil }
            } else {
                guard observation.occurredAt <= occurredAt else { return nil }
            }
            return candidate
        }
    }
}

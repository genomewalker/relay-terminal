import Foundation

struct RelaySavedConversationPlan: Decodable, Sendable {
    let paneID: String
    let provider: String
    let sessionID: String
    let directory: String
    let bindingSHA: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", provider, sessionID = "session_id", directory
        case bindingSHA = "binding_sha"
    }

    func command(profile: ConnectionProfile) throws -> String {
        guard UUID(uuidString: paneID) != nil, UUID(uuidString: sessionID) != nil,
              ["claude", "codex"].contains(provider), directory.hasPrefix("/"),
              !directory.contains("\0"), bindingSHA.count == 64,
              bindingSHA.allSatisfy({ $0.isHexDigit }) else {
            throw RemoteCatalogError.invalidResponse
        }
        return RelaySavedConversationRecovery.daemonCommand(profile: profile,
            arguments: ["resume-saved", paneID, sessionID, bindingSHA])
    }
}

enum RelaySavedConversationRecovery {
    static func daemonCommand(profile: ConnectionProfile, arguments: [String]) -> String {
        let suffix = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        // A dedicated helper can be installed without replacing a running
        // supervisor or modifying a provider's current executable.
        return "if [ -x \"$HOME/.local/share/relay/bin/relayd-recovery\" ]; then \"$HOME/.local/share/relay/bin/relayd-recovery\" " + suffix +
            "; else " + RelayHostExecution.daemonCommand(profile: profile, arguments: arguments) + "; fi"
    }
    static func plan(profile: ConnectionProfile, paneID: UUID) async throws -> RelaySavedConversationPlan {
        let captured = try await RelayHostExecution.capture(profile: profile,
            command: daemonCommand(profile: profile,
                arguments: ["resume-plan", paneID.uuidString.lowercased()]))
        guard captured.exitCode == 0 else {
            throw RemoteCatalogError.failed(String(data: captured.stderr, encoding: .utf8)
                ?? "No saved conversation is available for this pane")
        }
        let plan = try JSONDecoder().decode(RelaySavedConversationPlan.self, from: captured.stdout)
        guard UUID(uuidString: plan.paneID) == paneID else { throw RemoteCatalogError.invalidResponse }
        _ = try plan.command(profile: profile)
        return plan
    }
}

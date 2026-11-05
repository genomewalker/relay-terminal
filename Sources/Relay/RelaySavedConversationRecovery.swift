import Foundation

struct RelaySavedConversationPlan: Decodable, Sendable {
    let paneID: String
    let provider: String
    let sessionID: String
    let directory: String
    let bindingSHA: String
    /// Whether the host's recovery helper made this plan, so the same binary
    /// also starts it. Never decoded from the host.
    var useRecoveryHelper = false

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
            arguments: ["resume-saved", paneID, sessionID, bindingSHA], useHelper: useRecoveryHelper)
    }
}

enum RelaySavedConversationRecovery {
    static let helperPath = "$HOME/.local/share/relay/bin/relayd-recovery"

    /// A dedicated helper can be installed without replacing a running
    /// supervisor or modifying a provider's current executable. It is used
    /// only when the probe found it at least as new as the installed relayd:
    /// on dandy-07 (2026-10-30) a stale 0.5.3 helper refused every
    /// ~/.claude-team transcript that the installed 0.5.6 accepts.
    static func daemonCommand(profile: ConnectionProfile, arguments: [String], useHelper: Bool) -> String {
        let installed = RelayHostExecution.daemonCommand(profile: profile, arguments: arguments)
        guard useHelper else { return installed }
        let suffix = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        return "if [ -x \"\(helperPath)\" ]; then \"\(helperPath)\" " + suffix + "; else " + installed + "; fi"
    }

    /// Prints one `helper:` and one `installed:` line, each the first line of
    /// that binary's `version` output, or empty when it is absent or fails.
    static func versionProbeCommand(profile: ConnectionProfile) -> String {
        let installed = RelayHostExecution.daemonCommand(profile: profile, arguments: ["version"])
        return "if [ -x \"\(helperPath)\" ]; then h=$(\"\(helperPath)\" version 2>/dev/null | head -n 1); else h=; fi; " +
            "i=$(" + installed + " 2>/dev/null | head -n 1); printf 'helper:%s\\ninstalled:%s\\n' \"$h\" \"$i\""
    }

    /// `relayd X.Y.Z` with three decimal components of at most six digits;
    /// anything else, including a build named by `-ldflags`, is no version.
    static func version(_ line: Substring) -> [Int]? {
        guard line.hasPrefix("relayd "), line.utf8.count <= 64 else { return nil }
        let parts = line.dropFirst("relayd ".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard (1...6).contains(part.utf8.count), part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let value = Int(part) else { return nil }
            result.append(value)
        }
        return result
    }

    /// Whether the probe output allows the helper: both versions known and
    /// the helper's at least the installed one. Unknown means the installed relayd.
    static func helperIsCurrent(probe: String) -> Bool {
        var helper: [Int]?, installed: [Int]?, helperLines = 0, installedLines = 0
        for line in probe.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("helper:") {
                helperLines += 1; helper = version(line.dropFirst("helper:".count))
            } else if line.hasPrefix("installed:") {
                installedLines += 1; installed = version(line.dropFirst("installed:".count))
            }
        }
        guard helperLines == 1, installedLines == 1, let helper, let installed else { return false }
        return !helper.lexicographicallyPrecedes(installed)
    }

    typealias Capture = @Sendable (ConnectionProfile, String) async throws -> RelayHostExecution.Output

    static func plan(profile: ConnectionProfile, paneID: UUID,
        capture: Capture = { try await RelayHostExecution.capture(profile: $0, command: $1) }) async throws -> RelaySavedConversationPlan {
        let probe = try? await capture(profile, versionProbeCommand(profile: profile))
        let probeText = probe.flatMap { $0.exitCode == 0 ? String(data: $0.stdout, encoding: .utf8) : nil } ?? ""
        let useHelper = helperIsCurrent(probe: probeText)
        if !useHelper, probeText.contains("helper:relayd") {
            RelayDiagnostics.shared.record(category: "pane", name: "recovery-helper-skipped", details: [
                "pane_id": paneID.uuidString.lowercased(), "profile": profile.name,
                "probe": String(probeText.prefix(160)),
            ])
        }
        let captured = try await capture(profile, daemonCommand(profile: profile,
            arguments: ["resume-plan", paneID.uuidString.lowercased()], useHelper: useHelper))
        guard captured.exitCode == 0 else {
            throw RemoteCatalogError.failed(String(data: captured.stderr, encoding: .utf8)
                ?? "No saved conversation is available for this pane")
        }
        var plan = try JSONDecoder().decode(RelaySavedConversationPlan.self, from: captured.stdout)
        guard UUID(uuidString: plan.paneID) == paneID else { throw RemoteCatalogError.invalidResponse }
        plan.useRecoveryHelper = useHelper
        _ = try plan.command(profile: profile)
        return plan
    }
}

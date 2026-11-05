import Foundation
import Testing
@testable import Relay

@MainActor private final class Asked {
    var calls: [[String]] = []
}

@MainActor
@Suite("Account move onboarding")
struct RelayAgentAccountMoveOnboardingTests {
    let personal = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")

    func proof(provider: String = "claude", configDir: String? = "", pid: Int = 42) throws -> RelayAgentMaintenanceProbe {
        var fields = #""version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"\#(provider)","process_id":\#(pid),"process_start":99"#
        if let configDir { fields += #","config_dir":"\#(configDir)""# }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(("{" + fields + "}").utf8))
    }

    @Test("Only a clean relayd result naming a ready or updated target lets the move continue")
    func onboardingResultFailsClosed() {
        func refusal(_ code: Int?, _ stdout: String, _ stderr: String = "") -> String? {
            RelayAgentAccountMovePolicy.claudeOnboardingRefusal(exitCode: code, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), target: personal)
        }
        #expect(refusal(0, #"{"status":"ready","copied":0}"#) == nil)
        #expect(refusal(0, #"{"status":"updated","copied":3}"#) == nil)
        // relayd's own output (json.Encoder) ends with a newline.
        #expect(refusal(0, #"{"status":"ready","copied":0}"# + "\n") == nil)
        #expect(refusal(0, "") != nil)
        #expect(refusal(0, #"{"status":"refused"}"#) != nil)
        #expect(refusal(1, #"{"status":"ready"}"#, "relayd: the target account's .claude.json is not valid JSON")?
            .contains("personal account is not ready for this conversation: the target account's .claude.json is not valid JSON") == true)
        #expect(refusal(nil, "")?.contains("could not be reached") == true)
        #expect(refusal(1, "", "relayd: unknown command: claude-move-onboarding\n")?.contains("update Relay on that host") == true)
    }

    @Test("A Claude move checks the target with the agent's own account and folder before the exit")
    func claudeTargetIsPreparedBeforeExit() async throws {
        let mover = RelayAgentAccountMove()
        let asked = Asked()
        mover.prepareClaudeOnboarding = { _, source, target, pid in
            asked.calls.append([source, target.dir, String(pid)])
            return "not ready"
        }
        let profile = ConnectionProfile.sshConfigHost("owned-peer.invalid")
        let command = "CLAUDE_CONFIG_DIR=/home/u/.claude-personal relayd agent claude --resume s"
        #expect(await mover.prepareTarget(profile, proof: try proof(configDir: "~/.claude-max", pid: 4242), command: command, target: personal) == "not ready")
        #expect(asked.calls == [["~/.claude-max", "~/.claude-personal", "4242"]])
        mover.prepareClaudeOnboarding = { _, _, _, _ in nil }
        #expect(await mover.prepareTarget(profile, proof: try proof(), command: command, target: personal) == nil)
        // Without the agent's own account or process nothing is asked and the move is refused.
        let skipped = Asked()
        mover.prepareClaudeOnboarding = { _, _, _, _ in skipped.calls.append([]); return nil }
        #expect(await mover.prepareTarget(profile, proof: try proof(configDir: nil), command: command, target: personal) != nil)
        #expect(skipped.calls.isEmpty)
        // Codex moves are not checked for Claude onboarding.
        let codex = RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal")
        #expect(await mover.prepareTarget(profile, proof: try proof(provider: "codex"), command: "CODEX_HOME=/x relayd agent codex resume s",
                                          target: codex) == nil)
        #expect(skipped.calls.isEmpty)
    }
}

import Foundation
import Testing
@testable import Relay

@Suite("Forced account move: background commands, footer and notice")
struct RelayForcedAccountMoveTests {
    private let agent = 4242

    @Test("Only the shells the agent started are recorded, with the user's command unwrapped")
    func backgroundCommandsFromTheProcessTable() {
        let table = """
            1 0 /sbin/init
          4242 4100 claude --resume exact-session
          5001 4242 /bin/zsh -c -l source /home/u/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'while true; do kapk-monitor --once; sleep 60; done' \\< /dev/null && pwd -P >| /tmp/claude-1-cwd
          5002 4242 bash -lc 'pytest -q tests/test_model.py'
          5003 4242 node /home/u/.npm/mcp-server/index.js
          5004 4242 /bin/bash -c bash "$HOME/.config/relay/cc-status.sh"
          5005 5001 kapk-monitor --once
          5006 4100 bash -c 'not the agent child'
          5007 4242 -zsh -c eval 'echo it'\\''s fine' \\< /dev/null
        """
        let found = RelayForcedAccountMove.backgroundCommands(processTable: table, agentPID: agent)
        #expect(found == [
            .init(pid: 5001, command: "while true; do kapk-monitor --once; sleep 60; done"),
            .init(pid: 5002, command: "pytest -q tests/test_model.py"),
            .init(pid: 5007, command: "echo it's fine"),
        ])
    }

    @Test("A long command is cut, and the list is bounded")
    func bounds() {
        let long = String(repeating: "x", count: 500)
        #expect(RelayForcedAccountMove.readable("bash -c '\(long)'").count == RelayForcedAccountMove.maximumCommandLength)
        let table = (0..<40).map { "\(6000 + $0) \(agent) bash -c 'job \($0)'" }.joined(separator: "\n")
        #expect(RelayForcedAccountMove.backgroundCommands(processTable: table, agentPID: agent).count
            == RelayForcedAccountMove.maximumCommands)
    }

    @Test("Survivors are the recorded pids still listed")
    func survivors() {
        #expect(RelayForcedAccountMove.survivors(processList: " 5002\n 9999\n", pids: [5001, 5002]) == [5002])
        #expect(RelayForcedAccountMove.survivorCommand([5001, 5002]) == "ps -o pid= -p 5001,5002 || true")
    }

    @Test("The notice names the interrupted turn, the stopped and the surviving commands, on one line")
    func notice() throws {
        let commands: [RelayForcedMoveCommand] = [.init(pid: 1, command: "kapk-monitor"), .init(pid: 2, command: "make all")]
        let text = try #require(RelayForcedAccountMove.notice(account: "business", interrupted: true,
                                                              commands: commands, survivors: [2]))
        #expect(text.contains("business") && text.contains("interrupted"))
        #expect(text.contains("stopped by the restart: 1) `kapk-monitor`"))
        #expect(text.contains("`make all` (pid 2)"))
        #expect(!text.contains { $0.isNewline })
        let unknown = try #require(RelayForcedAccountMove.notice(account: "business", interrupted: false,
                                                                 commands: commands, survivors: nil))
        #expect(unknown.contains("could not check"))
        #expect(RelayForcedAccountMove.notice(account: "business", interrupted: false, commands: [], survivors: []) == nil)
    }

    @Test("Footer work rows hold the prompt unless the user forced the move")
    func forcedFooter() {
        for tail in [" · 2 shells", " · 1 background task", " · ← 1 agent · 2 shells"] {
            let screen = RelayAgentFleetFooterTests.screen(prompt: "❯ \n", tail: tail)
            #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude"), "\(tail)")
            #expect(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "claude",
                explainedAgents: RelayAgentMaintenancePrompt.allWorkExplained), "\(tail)")
        }
        // Typed text is never forced away.
        let typed = RelayAgentFleetFooterTests.screen(prompt: "❯ Send the proposal\n", tail: " · 2 shells")
        #expect(!RelayAgentMaintenancePrompt.isEmpty(typed, provider: "claude",
            explainedAgents: RelayAgentMaintenancePrompt.allWorkExplained))
    }

    @Test("A Codex background-terminal row is ignored only for a forced move")
    func forcedCodexFooter() {
        let model = "  gpt-6.1-terra high · Context 80% left · ~/project"
        let work = "  1 background terminal running · /ps to view"
        let hint = "  ← for agents · ? for shortcuts"
        let screen = ["  Worked for 2s", " ", "› \u{1b}[2mAsk Codex to do anything\u{1b}[22m", " ", model, work, hint]
            .joined(separator: "\r\n")
        #expect(!RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex"))
        #expect(RelayAgentMaintenancePrompt.isEmpty(screen, provider: "codex",
            explainedAgents: RelayAgentMaintenancePrompt.allWorkExplained))
    }

    @Test("Forced proofs use the turn's own evidence and ignore background work")
    func forcedPolicy() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var proof = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(#"{"version":1,"provider":"claude"}"#.utf8))
        proof.lifecycle = "quiet"; proof.backgroundWork = true; proof.subagentWork = true; proof.harnessStatus = "busy"
        #expect(!RelayAgentMaintenancePolicy.forcedIdle(proof))
        proof.harnessStatus = "idle"
        #expect(RelayAgentMaintenancePolicy.forcedIdle(proof))
        proof.forcedByUser = true
        #expect(RelayAgentMaintenancePolicy.explainedFooterAgents(proof, activeSubagents: 3)
            == RelayAgentMaintenancePrompt.allWorkExplained)
        // 07fa914c: an ended turn with background shells reports "shell".
        proof.harnessStatus = "shell"
        #expect(RelayAgentMaintenancePolicy.idleEvidence(proof, emptyPrompt: true, hasDraft: false))
        #expect(RelayAgentMaintenancePolicy.forcedNeedsInterrupt(proof))
        proof.lifecycle = "active"
        #expect(!RelayAgentMaintenancePolicy.idleEvidence(proof, emptyPrompt: true, hasDraft: false))
        proof.harnessStatus = "idle"
        #expect(!RelayAgentMaintenancePolicy.forcedNeedsInterrupt(proof))
    }

    // 07fa914c (dandy-07, 2026-11-15): the screen after a forced move's /exit.
    static func exitDialog(selected: Int = 1, title: String = "Background work is running") -> String {
        let choices = ["1. Exit and stop tasks", "2. Move to background and exit", "3. Stay"].enumerated().map {
            "     " + ($0.offset + 1 == selected ? "❯ " : "  ") + $0.element
        }
        return (["✻ Brewed for 11m 19s · done 2:13 PM · 2 shells still running", "",
                 String(repeating: "▔", count: 80), "   " + title, "   The following will stop when you exit:", "",
                 "   shell · O=/projects/caeg/scratch/kbd606/tmp/bin32013_chec…",
                 "   shell · cd /projects/caeg/scratch/kbd606/tmp/bin32013_che…", ""] + choices +
                ["", "   Enter to confirm · Esc to cancel"]).joined(separator: "\r\n")
    }

    @Test("Claude's exit dialog is recognised only with Exit and stop tasks selected")
    func exitStopTasksDialog() {
        #expect(RelayAgentMaintenancePrompt.isClaudeExitStopTasksDialog(Self.exitDialog()))
        #expect(!RelayAgentMaintenancePrompt.isClaudeExitStopTasksDialog(Self.exitDialog(selected: 2)))
        #expect(!RelayAgentMaintenancePrompt.isClaudeExitStopTasksDialog(Self.exitDialog(selected: 3)))
        #expect(!RelayAgentMaintenancePrompt.isClaudeExitStopTasksDialog(Self.exitDialog(title: "Delete these files?")))
        #expect(!RelayAgentMaintenancePrompt.isClaudeExitStopTasksDialog(
            RelayAgentFleetFooterTests.screen(prompt: "❯ \n", tail: " · 2 shells")))
    }
}

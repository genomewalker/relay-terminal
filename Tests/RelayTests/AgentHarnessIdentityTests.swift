import Foundation
import Testing
@testable import Relay

@MainActor @Suite struct AgentHarnessIdentityTests {
    private func identity(_ pane: PaneModel, provider: String, pid: Int = 77) -> AgentHarnessIdentity {
        AgentHarnessIdentity(paneID: pane.id, role: provider == "shell" ? "shell" : "harness",
            provider: provider, processes: provider == "shell" ? [] : [.init(provider: provider, pid: pid, processStart: "kernel:123")], reason: nil)
    }

    @Test func liveClaudeSurvivesChatEndAndOldSnapshot() throws {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.receivedHarnessIdentity(identity(pane, provider: "claude"))
        pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"SessionEnd","root_id":"old-chat"}}"#.utf8))
        pane.receivedAgentEvent(Data(#"{"agent":"relay","event":{"type":"RelayStateSnapshot","events":[]}}"#.utf8))
        #expect(pane.kind == .claude)
        #expect(pane.harnessLabel == "Claude")
    }

    @Test func confirmedShellIgnoresOldProviderEventsAndPrintedBanners() {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.receivedHarnessIdentity(identity(pane, provider: "shell"))
        pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"Notification"}}"#.utf8))
        pane.received("grep found Claude Code and OpenAI Codex in a document\n")
        #expect(pane.kind == .shell)
    }

    @Test func replacementProviderWinsOverLateExit() {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.receivedHarnessIdentity(identity(pane, provider: "claude"))
        pane.receivedHarnessIdentity(identity(pane, provider: "codex", pid: 88))
        pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"SessionEnd"}}"#.utf8))
        #expect(pane.kind == .codex)
    }

    @Test func otherHarnessHasItsOwnLabelAndNormalTerminalInput() {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.receivedHarnessIdentity(identity(pane, provider: "gemini"))
        #expect(pane.kind == .other)
        #expect(pane.harnessLabel == "Gemini")
        #expect(!TerminalPromptSelectionEdit.forcesLocalSelection(agentKind: pane.kind))
        #expect(!pane.kind.usesNativePromptEditing)
    }

    @Test func foreignAndUnavailableObservationsDoNotChangeThePane() {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        let foreign = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.receivedHarnessIdentity(identity(pane, provider: "claude"))
        pane.receivedHarnessIdentity(identity(foreign, provider: "codex"))
        pane.receivedHarnessIdentity(.init(paneID: pane.id, role: "unavailable", provider: nil, processes: [], reason: "Disconnected"))
        #expect(pane.kind == .claude)
    }

    @Test func relayInfrastructureIsNotCodex() {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.receivedAgentEvent(Data(#"{"agent":"relay","event":{"type":"Notification"}}"#.utf8))
        #expect(pane.kind == .shell)
        #expect(AgentKind.provider("opencode") == .other)
    }

    @Test func otherHarnessExitReturnsToShell() {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.receivedAgentEvent(Data(#"{"agent":"gemini","event":{"hook_event_name":"SessionStart","root_id":"gemini:77:123","source":"process-tree"}}"#.utf8))
        #expect(pane.kind == .other)
        #expect(pane.harnessLabel == "Gemini")
        pane.receivedAgentEvent(Data(#"{"agent":"gemini","event":{"hook_event_name":"SessionEnd","root_id":"gemini:77:unavailable","source":"process-tree"}}"#.utf8))
        #expect(pane.kind == .shell)
        #expect(pane.harnessLabel == "Shell")
    }
}

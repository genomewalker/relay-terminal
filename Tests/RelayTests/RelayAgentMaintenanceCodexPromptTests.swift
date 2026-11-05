import Foundation
import Testing
@testable import Relay

/// Codex 0.160–0.162 composer screens as Relay's viewport showed them on
/// dandy-07 (2026-10-18). The layout and text are the panes' own; the faint
/// SGR on the native placeholder is the style the screen export carries.
private enum CodexScreens {
    static let history = "  Worked for 17s • 2:48 PM\r\n\r\n"
    static let footer = "\r\n  GPT-Rosalind Research high · Context 53% left · /maps/projects/caeg/people/kbd606/pro…\r\n" +
        "  ? for shortcuts                                             ⚠ 3 warnings · f2 to view"
    static func composer(_ input: String) -> String { history + "› " + input + "\r\n" + footer }

    static let empty = composer("\u{1b}[2mAsk Codex to do anything\u{1b}[22m")
    static let followUp = composer("\u{1b}[2mAsk a follow-up question\u{1b}[22m")
    static let typed = composer("coordinate with claude, cancel any useless jobs")
    static let escPrimed = history + "› \u{1b}[2mAsk Codex to do anything\u{1b}[22m\r\n\r\n" +
        "  GPT-Rosalind Research high · Context 49% left · /maps/projects/fernandezguerra/apps/r…\r\n" +
        "  esc again to edit previous message"
    static let ctrlCPrimed = history + "› \u{1b}[2mAsk Codex to do anything\u{1b}[22m\r\n\r\n" +
        "  GPT-Rosalind Research high · Context 49% left · /maps/projects/fernandezguerra/apps/r…\r\n" +
        "  ctrl + c again to quit"
    static let working = "• Working (12s • esc to interrupt)\r\n\r\n" +
        "› \u{1b}[2mAsk Codex to do anything\u{1b}[22m\r\n" + footer
}

@Suite("Codex composer recognition")
struct RelayAgentMaintenanceCodexPromptTests {
    @Test func anEmptyComposerWithTheNativePlaceholderIsEmpty() {
        #expect(RelayAgentMaintenancePrompt.isEmpty(CodexScreens.empty, provider: "codex"))
        #expect(!RelayAgentMaintenancePrompt.hasTypedText(CodexScreens.empty, provider: "codex"))
    }

    @Test func theFollowUpPlaceholderIsEmpty() {
        #expect(RelayAgentMaintenancePrompt.isEmpty(CodexScreens.followUp, provider: "codex"))
        #expect(!RelayAgentMaintenancePrompt.hasTypedText(CodexScreens.followUp, provider: "codex"))
    }

    @Test func typedTextIsADraftNotEmpty() {
        #expect(!RelayAgentMaintenancePrompt.isEmpty(CodexScreens.typed, provider: "codex"))
        #expect(RelayAgentMaintenancePrompt.hasTypedText(CodexScreens.typed, provider: "codex"))
    }

    @Test func theEditPreviousMessageHintIsStillAnEmptyIdleComposer() {
        #expect(RelayAgentMaintenancePrompt.isEmpty(CodexScreens.escPrimed, provider: "codex"))
    }

    @Test func otherHintsStayUnrecognized() {
        #expect(!RelayAgentMaintenancePrompt.isEmpty(CodexScreens.ctrlCPrimed, provider: "codex"))
    }

    @Test func aRunningTurnIsNeverEmpty() {
        #expect(!RelayAgentMaintenancePrompt.isEmpty(CodexScreens.working, provider: "codex"))
        let working = CodexScreens.working.replacingOccurrences(of: "• Working (12s • esc to interrupt)",
                                                               with: "  Working (3s • esc to interrupt)")
        #expect(!RelayAgentMaintenancePrompt.isEmpty(working, provider: "codex"))
    }

    @Test func aRefusalNamesThePromptBlocker() throws {
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"quiet","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"resume_command":"/home/test/.local/bin/codex resume exact-session","move_command":"/home/test/.local/bin/codex resume exact-session"}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let proof = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        let pane = UUID(uuidString: "7d85fd72-64ec-46a4-8591-567bf64f7c93")!
        let target = RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal")
        let blocker = "the pane's terminal has not been opened since Relay started; select its tab once so its prompt can be read"
        let refused = RelayAgentAccountMovePolicy.refusal(proof, paneID: pane, target: target, emptyPrompt: false,
            hasDraft: false, pendingApprovals: 0, inputAge: 60, promptBlocker: blocker)
        #expect(refused == "Waiting for the original prompt to be confirmed empty: " + blocker)
        #expect(RelayAgentAccountMovePolicy.refusal(proof, paneID: pane, target: target, emptyPrompt: false,
            hasDraft: false, pendingApprovals: 0, inputAge: 60) == "Waiting for the original prompt to be confirmed empty")
        #expect(RelayAgentAccountMovePolicy.refusal(proof, paneID: pane, target: target, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60, promptBlocker: blocker) == nil)
        // Idle comes from the transcript: a completion still being written is not quiet.
        var settling = proof
        settling.lifecycle = "settling"
        #expect(RelayAgentAccountMovePolicy.refusal(settling, paneID: pane, target: target, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60) == "Waiting for the conversation transcript to stop changing")
        settling.lifecycle = "active"
        #expect(RelayAgentAccountMovePolicy.refusal(settling, paneID: pane, target: target, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60) == "Waiting for the current turn to finish")
    }
}

/// No path attaches an unopened pane headless: an explicit move shows it, as
/// selecting it would, and maintenance, Miko and health checks only read.
@MainActor @Suite("Unopened panes are never attached behind the user's back")
struct RelayAccountMoveRuntimeStartTests {
    @Test func anUnopenedPaneIsRefusedImmediatelyAndStaysUnattached() async {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.connectionState = .connected
        #expect(!pane.runtime.hasStarted)
        let refused = pane.runtime.accountMoveScreenRefusal()
        #expect(refused?.contains("Relay has no complete screen for") == true)
        #expect(refused?.contains(pane.displayName) == true)
        #expect(!pane.runtime.hasStarted)
        // The maintenance prompt proof and the pane-health facts only read.
        await pane.runtime.prepareAgentMaintenancePromptProof()
        _ = RelayPaneHealthFacts.read(pane, proof: nil)
        _ = pane.runtime.agentMaintenanceTerminalPromptIsEmpty
        _ = pane.runtime.agentMaintenanceTerminalPromptBlocker
        #expect(!pane.runtime.hasStarted)
        #expect(pane.runtime.agentMaintenanceTerminalPromptBlocker?.contains("has not been opened since Relay started") == true)
    }

    @Test func aDisconnectedPaneIsRefusedAsDisconnected() {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.connectionState = .disconnected("test")
        #expect(pane.runtime.accountMoveScreenRefusal() == "the pane is not connected")
        #expect(!pane.runtime.hasStarted)
    }
}

/// The retained shell's empty command line, proven from OSC 133 marks for a
/// hidden pane. The prompt is dandy-07's after Codex exits (2026-10-18).
@Suite("Retained shell input from OSC 133")
struct RelayShellInputTrackerTests {
    static let prompt = "\u{1b}]133;P;k=i\u{7}\u{1b}[38;2;124;213;241m[kbd606@dandycomp07fl /m/p/f/a/r/kaiku]" +
        "\u{1b}[38;2;186;160;248m [git: main]\u{1b}[0m $ \u{1b}]133;B\u{7}"
    static let codexExit = "Token usage: total=1,003,724\r\nTo continue this session, run:\r\n" +
        "  \u{1b}[36mcodex resume 01a127df-5e24-7e43-8f98-d36c27c163ee\u{1b}[39m\r\n\u{1b}[0m\u{1b}[r\u{1b}[?25h\u{1b}[H\u{1b}[2J"

    @Test func anUntouchedPromptAfterCodexExitsIsEmpty() {
        let tracker = TerminalShellInputTracker()
        #expect(!tracker.inputIsEmpty)
        tracker.observe(Data((Self.codexExit + Self.prompt).utf8))
        #expect(tracker.inputIsEmpty)
        // Mode changes after the mark are not input.
        tracker.observe(Data("\u{1b}[?2004h\u{1b}[?1004l\u{1b}=".utf8))
        #expect(tracker.inputIsEmpty)
    }

    @Test func echoedTypingOrEditingIsNotEmpty() {
        for echo in ["l", "ls -la", "\u{8}", "\r", "é"] {
            let tracker = TerminalShellInputTracker()
            tracker.observe(Data(Self.prompt.utf8))
            tracker.observe(Data(echo.utf8))
            #expect(!tracker.inputIsEmpty, "\(echo)")
        }
    }

    @Test func aRunningCommandOrUnknownStateIsNotEmpty() {
        let tracker = TerminalShellInputTracker()
        tracker.observe(Data(Self.prompt.utf8))
        tracker.observe(Data("\u{1b}]133;C\u{7}".utf8))
        #expect(!tracker.inputIsEmpty)
        tracker.observe(Data(Self.prompt.utf8))
        #expect(tracker.inputIsEmpty)
        tracker.forget()
        #expect(!tracker.inputIsEmpty)
        // A prompt redraw in progress (P without B yet) is not an empty line.
        tracker.observe(Data(Self.prompt.utf8))
        tracker.observe(Data("\u{1b}]133;P;k=i\u{7}[kbd606@dandycomp07fl ~] $ ".utf8))
        #expect(!tracker.inputIsEmpty)
    }

    @Test func aMarkSplitAcrossPacketsIsStillRead() {
        let tracker = TerminalShellInputTracker()
        let bytes = Array(Self.prompt.utf8)
        for chunk in stride(from: 0, to: bytes.count, by: 3) {
            tracker.observe(Data(bytes[chunk..<min(chunk + 3, bytes.count)]))
        }
        #expect(tracker.inputIsEmpty)
    }
}

@Suite("Relay Codex profile in the target account")
struct RelayCodexProfileMoveTests {
    let personal = RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal")
    @Test func onlyAMoveKeepingRelaysProfileNeedsIt() {
        let keep = "CODEX_HOME=/home/u/.codex-personal /home/u/.local/bin/relayd agent codex --profile relay-terminal resume s"
        #expect(RelayAgentAccountMovePolicy.needsRelayCodexProfile(moveCommand: keep, provider: "codex", target: personal))
        #expect(RelayAgentAccountMovePolicy.needsRelayCodexProfile(
            moveCommand: keep.replacingOccurrences(of: "--profile", with: "-p"), provider: "codex", target: personal))
        #expect(!RelayAgentAccountMovePolicy.needsRelayCodexProfile(
            moveCommand: keep.replacingOccurrences(of: "relay-terminal", with: "mine"), provider: "codex", target: personal))
        #expect(!RelayAgentAccountMovePolicy.needsRelayCodexProfile(
            moveCommand: "env -u CODEX_HOME /x/relayd agent codex resume s", provider: "codex", target: personal))
        let work = RelayAgentAccount(provider: "codex", label: "work", dir: "")
        #expect(!RelayAgentAccountMovePolicy.needsRelayCodexProfile(moveCommand: keep, provider: "codex", target: work))
        #expect(!RelayAgentAccountMovePolicy.needsRelayCodexProfile(moveCommand: keep, provider: "claude", target: personal))
    }
}

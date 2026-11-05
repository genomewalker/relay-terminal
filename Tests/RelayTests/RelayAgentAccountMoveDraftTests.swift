import Foundation
import Testing
@testable import Relay

/// A pane's agent as the move sees it: a screen that becomes readable once
/// the pane is shown, and a prompt the editor bridge reads and replaces.
@MainActor private final class MovedAgent {
    var prompt = Data()
    var readable = false
    /// Screen checks after the pane is shown before its screen is complete.
    var checksUntilReadable = 2
    var presented = 0
    var failRestore = false
    /// Claude's settings overlay covers the prompt until one Esc.
    var overlay = false
    var dismissed = 0
    /// Failures the next native reads throw before the move sends anything.
    var inspectFailures: [RelayAgentMaintenanceReader.InspectFailure] = []
    /// The selected pane whenever the move read or sent anything.
    var activeAtInput: [UUID?] = []
    var events: [String] = []
}

private func moveProbe(_ pane: UUID, provider: String = "claude", pid: Int = 42, start: Int = 99,
                       extra: String = "") throws -> RelayAgentMaintenanceProbe {
    let id = pane.uuidString.lowercased()
    let json = #"{"version":1,"pane_id":"\#(id)","provider":"\#(provider)","process_id":\#(pid),"process_start":\#(start),"session_id":"exact-session","bound":true,"lifecycle":"quiet","background_work":false,"subagent_work":false,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"\#(id)","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"\#(provider)","process_id":\#(pid),"process_start":\#(start),"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"config_dir":"~/.claude-max","resume_command":"relayd agent \#(provider) --resume exact-session","move_command":"CLAUDE_CONFIG_DIR=/home/u/.claude-personal relayd agent \#(provider) --resume exact-session""#
        + extra + "}"
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
}

@MainActor
@Suite("Account move shows unopened panes and keeps typed drafts")
struct RelayAgentAccountMoveDraftTests {
    let personal = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")

    /// A real workspace and pane; everything native is the fake agent.
    fileprivate func harness(_ agent: MovedAgent, provider: String = "claude")
        throws -> (mover: RelayAgentAccountMove, workspace: WorkspaceModel, pane: PaneModel, other: PaneModel) {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.newTab(profile: .sshConfigHost("move-draft.invalid"))
        let pane = try #require(workspace.activePane)
        pane.connectionState = .connected
        // The user is looking at another pane when the move starts.
        workspace.newTab(profile: .local)
        let other = try #require(workspace.activePane)
        let mover = RelayAgentAccountMove()
        // This fixture exercises the explicitly unmanaged legacy lane.
        mover.capacityRoute = { _ in false }
        mover.audit = RelayAgentAccountMoveAudit()
        mover.drafts = RelayAgentMaintenanceDraftStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-move-draft-tests-\(UUID().uuidString)/drafts"))
        mover.screenInterval = 0.01; mover.exitInterval = 0.01; mover.verifyInterval = 0.01
        mover.prepareClaudeOnboarding = { _, _, _, _ in nil }
        mover.prepareRelayCodexProfile = { _, _ in nil }
        mover.presentPane = { pane, workspace in
            agent.presented += 1; agent.events.append("present")
            workspace.revealPane(pane.id)
        }
        mover.screenRefusal = { _ in
            agent.events.append("screen")
            if agent.presented > 0, !agent.readable {
                agent.checksUntilReadable -= 1
                if agent.checksUntilReadable < 0 { agent.readable = true }
            }
            return agent.readable ? nil : "Relay has no complete screen yet"
        }
        mover.inspect = { pane, _, expect in
            agent.events.append(expect == nil ? "inspect" : "verify")
            agent.activeAtInput.append(workspace.activePaneID)
            if expect == nil, !agent.inspectFailures.isEmpty { throw agent.inspectFailures.removeFirst() }
            return expect == nil ? try moveProbe(pane.id, provider: provider)
                : try moveProbe(pane.id, provider: provider, pid: 77, start: 120, extra: #","account_matches":true"#)
        }
        mover.readPrompt = { _, _ in
            agent.overlay
                ? RelayAgentAccountMove.PromptState(empty: false, blocker: "the screen's prompt or footer was not recognised", overlay: true)
                : RelayAgentAccountMove.PromptState(empty: agent.prompt.isEmpty, typed: !agent.prompt.isEmpty,
                                                    blocker: agent.prompt.isEmpty ? nil : "the screen's prompt or footer was not recognised")
        }
        mover.dismissOverlay = { _, _, _ in
            agent.dismissed += 1; agent.events.append("esc")
            agent.overlay = false
            return true
        }
        mover.editDraft = { _, _, _, expected, replacement, beforeApply in
            let text = agent.prompt
            guard expected == nil || expected == text else { throw RelayPromptEditorRPC.Failure.changedConnection }
            try beforeApply(text)
            if let replacement {
                if agent.failRestore, !replacement.isEmpty { throw RelayAgentMaintenanceDraftRefusal("the agent is not idle") }
                agent.prompt = replacement
                agent.events.append("commit")
            } else {
                agent.events.append("read")
            }
            return text
        }
        // The runtime refuses an exit unless the terminal prompt is empty.
        mover.sendExit = { _, _, _, _ in
            agent.events.append("exit"); agent.activeAtInput.append(workspace.activePaneID)
            return agent.prompt.isEmpty
        }
        mover.resume = { _, _, _, _, willSend in try willSend(); agent.events.append("resume"); return true }
        return (mover, workspace, pane, other)
    }

    func draftFiles(_ mover: RelayAgentAccountMove) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: mover.drafts.directory.path)) ?? []
    }

    @Test("A pane not shown since launch is shown, read once its screen is complete, moved, and the earlier selection returns")
    func unopenedPaneIsShownThenMoved() async throws {
        let agent = MovedAgent()
        let (mover, workspace, pane, other) = try harness(agent)
        defer { workspace.shutdown() }
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "verified", "\(outcome.message)")
        #expect(agent.presented == 1)
        let present = try #require(agent.events.firstIndex(of: "present"))
        let inspect = try #require(agent.events.firstIndex(of: "inspect"))
        #expect(present < inspect)
        #expect(agent.events.filter { $0 == "screen" }.count >= 3)
        #expect(workspace.activePaneID == other.id)
        // The earlier selection and focus came back before any read or input.
        #expect(!agent.activeAtInput.isEmpty && agent.activeAtInput.allSatisfy { $0 == other.id })
        #expect(!mover.audit.memory.contains { $0.state.hasPrefix("draft") })
    }

    @Test("A screen that never becomes readable is refused after the bound, before any native read")
    func unreadableScreenIsRefusedAfterTheBound() async throws {
        let agent = MovedAgent()
        agent.checksUntilReadable = .max
        let (mover, workspace, pane, other) = try harness(agent)
        defer { workspace.shutdown() }
        mover.screenTimeout = 0.3
        let started = Date()
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "refused")
        #expect(outcome.message.contains("could not read its screen within"))
        #expect(!outcome.message.contains("Waiting for the original prompt"))
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(agent.presented == 1)
        #expect(!agent.events.contains("inspect") && !agent.events.contains("exit"))
        #expect(workspace.activePaneID == other.id)
    }

    @Test("When the earlier selection cannot be given back, nothing is read or sent to the shown pane")
    func unrestorableSelectionIsRefused() async throws {
        let agent = MovedAgent()
        let (mover, workspace, pane, other) = try harness(agent)
        defer { workspace.shutdown() }
        // The pane the user was on closes while the move shows its own.
        mover.presentPane = { pane, workspace in
            agent.presented += 1
            workspace.revealPane(other.id)
            workspace.closeActivePane()
            workspace.revealPane(pane.id)
        }
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "refused")
        #expect(outcome.message.contains("could not give the keyboard back"), "\(outcome.message)")
        #expect(workspace.panes[other.id] == nil)
        #expect(!agent.events.contains("inspect") && !agent.events.contains("exit"))
    }

    @Test("A disconnected pane is refused at once and is not shown")
    func disconnectedPaneIsNotShown() async throws {
        let agent = MovedAgent()
        let (mover, workspace, pane, _) = try harness(agent)
        defer { workspace.shutdown() }
        pane.connectionState = .disconnected("test")
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "refused" && outcome.message.contains("not connected"))
        #expect(agent.presented == 0 && agent.events.isEmpty)
    }

    @Test("A typed Claude draft is saved before it is cleared, the exit sees an empty prompt, and the draft is put back after verification")
    func typedDraftIsSavedClearedAndRestored() async throws {
        let agent = MovedAgent()
        agent.readable = true
        let draft = Data("half-written question\n  with a second line 🧬".utf8)
        agent.prompt = draft
        let (mover, workspace, pane, _) = try harness(agent)
        defer { workspace.shutdown() }
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "verified", "\(outcome.message)")
        #expect(outcome.message.contains("Your unsent prompt was put back"))
        #expect(agent.prompt == draft)
        #expect(agent.presented == 0)
        let exit = try #require(agent.events.firstIndex(of: "exit"))
        let verify = try #require(agent.events.firstIndex(of: "verify"))
        #expect(agent.events[..<exit].contains("commit"))
        #expect(agent.events[verify...].contains("commit"))
        let states = mover.audit.memory.map(\.state)
        let saved = try #require(states.firstIndex(of: "draft_saved"))
        let exitPending = try #require(states.firstIndex(of: "exit_pending"))
        #expect(saved < exitPending)
        #expect(states.contains("draft_restored") && !states.contains("draft_kept"))
        // A restored draft's backup is removed.
        #expect(draftFiles(mover).isEmpty)
    }

    @Test("A draft that cannot be put back is reported and kept on disk")
    func restoreFailureKeepsTheDraft() async throws {
        let agent = MovedAgent()
        agent.readable = true
        agent.failRestore = true
        let draft = Data("keep me".utf8)
        agent.prompt = draft
        let (mover, workspace, pane, _) = try harness(agent)
        defer { workspace.shutdown() }
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "verified", "\(outcome.message)")
        #expect(outcome.message.contains("could not be put back"))
        #expect(outcome.message.contains(mover.drafts.directory.path))
        #expect(agent.prompt.isEmpty)
        let files = draftFiles(mover)
        #expect(files.count == 1)
        let saved = try mover.drafts.load(String(try #require(files.first).dropLast(".json".count)))
        #expect(saved.text == draft && saved.paneID == pane.id && saved.sessionID == "exact-session")
        #expect(mover.audit.memory.contains { $0.state == "draft_restore_failed" })
    }

    @Test("A Codex draft is refused with the capture contract reason, and nothing is cleared or sent")
    func codexDraftIsRefused() async throws {
        let agent = MovedAgent()
        agent.readable = true
        agent.prompt = Data("codex draft".utf8)
        let (mover, workspace, pane, _) = try harness(agent, provider: "codex")
        defer { workspace.shutdown() }
        let codex = RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal")
        let outcome = await mover.move(pane, in: workspace, to: codex, origin: .user, inputGranted: true)
        #expect(outcome.state == "refused")
        #expect(outcome.message.contains("no exact draft capture contract for codex"))
        #expect(agent.prompt == Data("codex draft".utf8))
        #expect(!agent.events.contains("commit") && !agent.events.contains("read") && !agent.events.contains("exit"))
        #expect(draftFiles(mover).isEmpty)
    }

    @Test("An unreadable prompt without visible typed text is still held with its reason")
    func unrecognisedPromptIsHeld() async throws {
        let agent = MovedAgent()
        agent.readable = true
        let (mover, workspace, pane, _) = try harness(agent)
        defer { workspace.shutdown() }
        mover.readPrompt = { _, _ in
            RelayAgentAccountMove.PromptState(empty: false, typed: false, blocker: "the screen's prompt or footer was not recognised")
        }
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "refused")
        #expect(outcome.message == "Waiting for the original prompt to be confirmed empty: the screen's prompt or footer was not recognised")
        #expect(!agent.events.contains("commit") && !agent.events.contains("exit") && !agent.events.contains("esc"))
    }

    @Test("Claude's settings overlay is closed with one Esc, then the prompt is read and the move proceeds")
    func settingsOverlayIsDismissed() async throws {
        let agent = MovedAgent()
        agent.readable = true
        agent.overlay = true
        let (mover, workspace, pane, _) = try harness(agent)
        defer { workspace.shutdown() }
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "verified", "\(outcome.message)")
        #expect(agent.dismissed == 1)
        let esc = try #require(agent.events.firstIndex(of: "esc"))
        let exit = try #require(agent.events.firstIndex(of: "exit"))
        #expect(esc < exit)
        #expect(mover.audit.memory.contains { $0.state == "overlay_dismiss" })
    }

    @Test("Only the settings tab row with Esc to cancel and no prompt line is the overlay")
    func settingsOverlayShape() {
        let overlay = "  Settings  Status   Config   Usage   Stats\n\n  Version: 2.1.120\n  Session name: /rename to add a name\n" +
            "  Model: Fable 5.1\n\n  Esc to cancel\n"
        #expect(RelayAgentMaintenancePrompt.isClaudeSettingsOverlay(overlay))
        #expect(!RelayAgentMaintenancePrompt.isClaudeSettingsOverlay(overlay.replacingOccurrences(of: "  Esc to cancel\n", with: "")))
        #expect(!RelayAgentMaintenancePrompt.isClaudeSettingsOverlay(overlay.replacingOccurrences(of: "Usage   Stats", with: "Usage")))
        #expect(!RelayAgentMaintenancePrompt.isClaudeSettingsOverlay("  Settings is a word in a transcript\n❯ \n  Esc to cancel\n"))
        #expect(!RelayAgentMaintenancePrompt.isClaudeSettingsOverlay(nil))
    }

    @Test("Weekly-limit selector recognition does not accept a different dialog or trailing prompt")
    func weeklyLimitSelectorShape() {
        let menu = """
        Prior output
        What do you want to do?
        ❯ 1. Stop and wait for limit to reset
          2. Wait here, then continue automatically at Nov 5 at 1am
          3. Switch to usage credits
        Enter to confirm · Esc to cancel
        """
        #expect(RelayAgentMaintenancePrompt.isClaudeWeeklyLimitSelector(menu))
        #expect(!RelayAgentMaintenancePrompt.isClaudeSettingsOverlay(menu))
        #expect(!RelayAgentMaintenancePrompt.isClaudeWeeklyLimitSelector(menu.replacingOccurrences(of: "3. Switch to usage credits", with: "3. Continue")))
        #expect(!RelayAgentMaintenancePrompt.isClaudeWeeklyLimitSelector(menu + "\nAnother prompt"))
        #expect(!RelayAgentMaintenancePrompt.isClaudeWeeklyLimitSelector(nil))
    }

    @Test("A native read relayd stopped at its timeout, twice, refuses the move and says nothing was sent")
    func inspectTimeoutBeforeSendIsRefused() async throws {
        let agent = MovedAgent()
        agent.readable = true
        agent.inspectFailures = [.init(exitCode: -1, stderr: Data()), .init(exitCode: -1, stderr: Data())]
        let (mover, workspace, pane, _) = try harness(agent)
        defer { workspace.shutdown() }
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "refused")
        #expect(outcome.message.contains("nothing was sent"))
        #expect(outcome.message.contains("timed out"))
        #expect(agent.events.filter { $0 == "inspect" }.count == 2)
        #expect(!agent.events.contains("exit"))
    }

    @Test("One timed-out native read is read once more and the move proceeds")
    func oneInspectTimeoutIsReadAgain() async throws {
        let agent = MovedAgent()
        agent.readable = true
        agent.inspectFailures = [.init(exitCode: -1, stderr: Data())]
        let (mover, workspace, pane, _) = try harness(agent)
        defer { workspace.shutdown() }
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "verified", "\(outcome.message)")
        #expect(mover.audit.memory.contains { $0.state == "inspect_retry" })
    }

    @Test("A failed native read is refused at once with its status and a redacted first stderr line")
    func inspectFailureIsRefusedWithItsReason() async throws {
        let agent = MovedAgent()
        agent.readable = true
        agent.inspectFailures = [.init(exitCode: 1, stderr: Data(
            "\n  relayd: denied ANTHROPIC_API_KEY=sk-ant-secret-value token abcdefghijklmnopqrstuvwxyz0123\nsecond line\n".utf8))]
        let (mover, workspace, pane, _) = try harness(agent)
        defer { workspace.shutdown() }
        let outcome = await mover.move(pane, in: workspace, to: personal, origin: .user, inputGranted: true)
        #expect(outcome.state == "refused")
        #expect(outcome.message.contains("status 1: relayd: denied ANTHROPIC_API_KEY=… token …"), "\(outcome.message)")
        #expect(outcome.message.contains("nothing was sent"))
        #expect(!outcome.message.contains("sk-ant") && !outcome.message.contains("abcdefghij") && !outcome.message.contains("second line"))
        #expect(agent.events.filter { $0 == "inspect" }.count == 1)
    }

    @Test("The policy admits a typed draft only for Claude; delivery and other holds remain")
    func policyAdmitsOnlyClaudeDrafts() throws {
        let pane = UUID()
        func refusal(_ provider: String, typed: Bool, empty: Bool = false, inputAge: TimeInterval = 60) throws -> String? {
            let target = RelayAgentAccount(provider: provider, label: "personal", dir: "~/.\(provider)-personal")
            return RelayAgentAccountMovePolicy.refusal(try moveProbe(pane, provider: provider), paneID: pane, target: target,
                emptyPrompt: empty, hasDraft: false, typedDraft: typed, pendingApprovals: 0, inputAge: inputAge, promptBlocker: "unrecognised")
        }
        #expect(try refusal("claude", typed: true) == nil)
        #expect(try refusal("codex", typed: true)?.contains("draft capture contract") == true)
        #expect(try refusal("claude", typed: false)?.contains("unrecognised") == true)
        // Typing just now still holds the move.
        #expect(try refusal("claude", typed: true, inputAge: 1) == "Waiting until you finish typing")
    }
}

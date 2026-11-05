import Foundation
import Testing
@testable import Relay

/// The observed account label is display only: it comes from the host's own
/// registry, is re-derived when that registry arrives, and shows the
/// directory when no account was recorded at launch.
@Suite("Agent account observed label")
@MainActor
struct RelayAgentAccountLabelTests {
    let dandy = ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07")

    func status(_ provider: String, _ label: String, dir: String) throws -> RelayAgentAccountStatus {
        let json = #"{"provider":"\#(provider)","label":"\#(label)","dir":"\#(dir)","root":"/h/\#(provider)-\#(label)","# +
            #""default":\#(dir.isEmpty),"exists":true,"logged_in":"yes"}"#
        return try JSONDecoder().decode(RelayAgentAccountStatus.self, from: Data(json.utf8))
    }

    /// dandy-07: claude "" = personal, ~/.claude-team = business; codex "" = business, ~/.codex-personal = personal.
    func dandyRegistry() throws -> [RelayAgentAccountStatus] {
        [try status("claude", "personal", dir: ""), try status("claude", "business", dir: "~/.claude-team"),
         try status("codex", "business", dir: ""), try status("codex", "personal", dir: "~/.codex-personal")]
    }

    /// This Mac: claude "" = business, ~/.claude-max = personal.
    func macRegistry() throws -> [RelayAgentAccountStatus] {
        [try status("claude", "business", dir: ""), try status("claude", "personal", dir: "~/.claude-max")]
    }

    @Test("A probe on a host whose registry is not loaded yields no label, never the built-in 'work'")
    func unloadedRegistryHasNoLabel() {
        let directory = RelayAgentAccountDirectory()
        #expect(RelayAgentAccount.defaults.contains { $0.provider == "claude" && $0.dir == "" && $0.label == "work" })
        #expect(directory.label(for: dandy, provider: "claude", observedDirectory: "") == nil)
        #expect(directory.label(for: dandy, provider: "codex", observedDirectory: "") == nil)
        #expect(directory.label(for: .local, provider: "claude", observedDirectory: "") == nil)
        #expect(RelayAgentAccountDirectory.observedLabel(registry: nil, provider: "claude", observedDirectory: "") == nil)
        #expect(RelayAgentAccountDirectory.observedLabel(registry: [], provider: "claude", observedDirectory: "") == nil)
        // Launch choice still has its defaults: only the display label changed.
        #expect(directory.accounts(for: dandy) == RelayAgentAccount.defaults)
    }

    @Test("When the remote registry arrives every observed pane on that host is re-labelled")
    func registryArrivalRelabels() throws {
        let directory = RelayAgentAccountDirectory()
        let main = PaneModel(profile: dandy)
        let team = PaneModel(profile: dandy)
        let codex = PaneModel(profile: dandy)
        let elsewhere = PaneModel(profile: .local)
        // A stale pre-load guess, as a pane restored from its store has.
        main.observeAgentAccount(provider: "claude", directory: "", label: "work")
        team.observeAgentAccount(provider: "claude", directory: "~/.claude-team",
            label: directory.label(for: dandy, provider: "claude", observedDirectory: "~/.claude-team"))
        codex.observeAgentAccount(provider: "codex", directory: "", label: nil)
        elsewhere.observeAgentAccount(provider: "claude", directory: "", label: "work")
        #expect(team.agentAccount?.observedLabel == nil)
        for pane in [main, team, codex, elsewhere] { directory.trackObservedPane(pane) }

        directory.record(try dandyRegistry(), executables: nil, fromHost: "dandy-07", probeRequested: false)

        #expect(main.agentAccount?.observedLabel == "personal")
        #expect(team.agentAccount?.observedLabel == "business")
        #expect(codex.agentAccount?.observedLabel == "business")
        #expect(main.agentAccountDisplay == "personal · default (~/.claude)")
        #expect(main.agentAccountLabel == "personal")
        #expect(team.agentAccountDisplay == "business · ~/.claude-team")
        // Another host's pane waits for its own registry.
        #expect(elsewhere.agentAccount?.observedLabel == "work")
        #expect(directory.label(for: dandy, provider: "codex", observedDirectory: "~/.codex-personal") == "personal")
    }

    @Test("This Mac's mapping is unchanged once its registry is read")
    func macMapping() throws {
        let directory = RelayAgentAccountDirectory()
        directory.record(try macRegistry(), executables: nil, fromHost: "local", probeRequested: false)
        #expect(directory.label(for: .local, provider: "claude", observedDirectory: "") == "business")
        #expect(directory.label(for: .local, provider: "claude", observedDirectory: "~/.claude-max") == "personal")
        #expect(directory.label(for: .local, provider: "claude", observedDirectory: "~/.claude-other") == nil)
        #expect(directory.label(for: dandy, provider: "claude", observedDirectory: "") == nil)
    }

    @Test("Without a recorded account the display shows the directory; a recorded account shows its label")
    func displayShowsDirectory() {
        var state = RelayPaneAgentAccountState()
        #expect(state.displayLabel == nil)
        state.observedProvider = "claude"
        state.observedDirectory = ""
        #expect(state.displayLabel == "default (~/.claude)")
        state.observedLabel = "personal"
        #expect(state.displayLabel == "personal · default (~/.claude)")
        state.observedDirectory = "~/.claude-team"
        state.observedLabel = nil
        #expect(state.displayLabel == "~/.claude-team")
        state.observedProvider = "codex"
        state.observedDirectory = ""
        #expect(state.displayLabel == "default (~/.codex)")

        let recorded = RelayAgentAccount(provider: "claude", label: "business", dir: "~/.claude-team")
        var launched = RelayPaneAgentAccountState(recorded: recorded)
        launched.observedProvider = "claude"
        launched.observedDirectory = "~/.claude-team"
        launched.observedLabel = "business"
        #expect(launched.displayLabel == "business")
        #expect(launched.displayLabel == launched.label)
    }

    @Test("A recorded account keeps precedence when the registry relabels")
    func recordedKeepsPrecedence() throws {
        let directory = RelayAgentAccountDirectory()
        let pane = PaneModel(profile: dandy)
        let recorded = RelayAgentAccount(provider: "claude", label: "business", dir: "~/.claude-team")
        pane.recordAgentAccount(recorded)
        pane.observeAgentAccount(provider: "claude", directory: "~/.claude-team", label: "business", matches: true)
        directory.trackObservedPane(pane)
        directory.record(try dandyRegistry(), executables: nil, fromHost: "dandy-07", probeRequested: false)
        #expect(pane.agentAccount?.recorded == recorded)
        #expect(pane.agentAccountLabel == "business")
    }

    @Test("Move, resume and deferral sources stay the recorded account, never the observed or display label")
    func moveSourceIgnoresDisplay() throws {
        let directory = RelayAgentAccountDirectory()
        let pane = PaneModel(profile: dandy)
        pane.observeAgentAccount(provider: "claude", directory: "", label: nil)
        directory.trackObservedPane(pane)
        directory.record(try dandyRegistry(), executables: nil, fromHost: "dandy-07", probeRequested: false)
        #expect(pane.agentAccountDisplay == "personal · default (~/.claude)")
        // RelayAgentAccountMove.move's `from`, the reader's --expect-account
        // and the deferral's recordedAccount all read `recorded`.
        #expect(pane.agentAccount?.recorded == nil)
        #expect(pane.agentAccount?.mismatch == false)
        // Relabelling never records an account.
        #expect(pane.agentAccount?.label == "personal")
    }

    @Test("A restored pane drops its saved guess until the host registry is read")
    func restoredGuessWaitsForTheRegistry() throws {
        let saved = RelayPaneAgentAccountState(observedProvider: "claude", observedDirectory: "", observedLabel: "work")
        let directory = RelayAgentAccountDirectory()
        let cold = PaneModel(profile: dandy)
        cold.restoreAgentAccount(saved, accounts: directory)
        #expect(cold.agentAccountDisplay == "default (~/.claude)")
        #expect(cold.agentAccountLabel == nil)
        directory.record(try dandyRegistry(), executables: nil, fromHost: "dandy-07", probeRequested: false)
        #expect(cold.agentAccountDisplay == "personal · default (~/.claude)")
        // Restored after the registry is read: relabelled at once.
        let warm = PaneModel(profile: dandy)
        warm.restoreAgentAccount(saved, accounts: directory)
        #expect(warm.agentAccountDisplay == "personal · default (~/.claude)")
    }

    @Test("relay_list_panes exports the raw label as account and the directory text apart, never as a move target")
    func exportedAccountIsTheRawLabel() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let host = ConnectionProfile.sshConfigHost("account-export.invalid")
        workspace.newTab(profile: host)
        let pane = try #require(workspace.activePane)
        func exported() throws -> [String: Any] {
            let listed = try #require(workspace.sidePanelState().sessions.flatMap(\.tabs).flatMap(\.panes)
                .first { $0.id == pane.id.uuidString.lowercased() })
            return try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(listed)) as? [String: Any])
        }

        // Not recorded, registry not read: no label, the directory for display.
        pane.observeAgentAccount(provider: "claude", directory: "", label: nil)
        #expect(try exported()["account"] == nil)
        #expect(try exported()["accountDisplay"] as? String == "default (~/.claude)")
        // The registry arrives.
        let directory = RelayAgentAccountDirectory()
        directory.trackObservedPane(pane)
        directory.record(try dandyRegistry(), executables: nil, fromHost: RelayAgentAccountDirectory.hostKey(host), probeRequested: false)
        #expect(try exported()["account"] as? String == "personal")
        #expect(try exported()["accountDisplay"] as? String == "personal · default (~/.claude)")
        // Restored cold with a saved guess.
        pane.restoreAgentAccount(RelayPaneAgentAccountState(observedProvider: "claude", observedDirectory: "", observedLabel: "work"),
                                 accounts: RelayAgentAccountDirectory())
        #expect(try exported()["account"] == nil)
        #expect(try exported()["accountDisplay"] as? String == "default (~/.claude)")
        // Recorded at launch.
        pane.recordAgentAccount(RelayAgentAccount(provider: "claude", label: "business", dir: "~/.claude-team"))
        #expect(try exported()["account"] as? String == "business")
        #expect(try exported()["accountDisplay"] as? String == "business")

        // The display text is never an account label, so a move rejects it.
        #expect(RelayAgentAccount.validLabel("personal"))
        #expect(!RelayAgentAccount.validLabel("personal · default (~/.claude)"))
        #expect(!RelayAgentAccount.validLabel("default (~/.claude)"))
    }

    /// Counts a loader's reads and keeps the failure shown when it retried.
    @MainActor final class LoaderLog { var calls = 0; var failureBeforeRetry: String? }

    @Test("A remote host's account list loads by itself; a failed read is kept, logged and retried")
    func registryLoadsAndRetriesAFailedRead() async throws {
        let directory = RelayAgentAccountDirectory()
        directory.registryRetryDelays = [.milliseconds(20)]
        let registry = try dandyRegistry(), log = LoaderLog(), key = RelayAgentAccountDirectory.hostKey(dandy)
        let pane = PaneModel(profile: dandy)
        pane.observeAgentAccount(provider: "claude", directory: "", label: nil)
        // Without a loader (tests, before launch) nothing is read.
        directory.trackObservedPane(pane)
        #expect(directory.registryFailures.isEmpty)

        // Setting the loader reads the hosts of panes already tracked.
        directory.registryLoader = { [unowned directory] profile in
            log.calls += 1
            if log.calls == 1 { throw RelayAgentAccountDirectory.Failure.refused("host unreachable") }
            log.failureBeforeRetry = directory.registryFailures[key]
            directory.record(registry, executables: nil, fromHost: RelayAgentAccountDirectory.hostKey(profile), probeRequested: false)
        }
        for _ in 0..<200 where pane.agentAccountDisplay != "personal · default (~/.claude)" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pane.agentAccountDisplay == "personal · default (~/.claude)")
        #expect(log.calls == 2)
        #expect(log.failureBeforeRetry == "host unreachable")
        #expect(directory.registryFailures[key] == nil)

        // Once loaded, tracking another pane on the host reads nothing more.
        directory.trackObservedPane(PaneModel(profile: dandy))
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.calls == 2)
        // A pane on another remote host, tracked later, reads that host.
        let nodeB = PaneModel(profile: ConnectionProfile(name: "node-b", kind: .ssh, host: "node-b.invalid"))
        directory.trackObservedPane(nodeB)
        for _ in 0..<100 where log.calls < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.calls == 3)
        // This Mac is read through its launchers, not here.
        let local = PaneModel(profile: .local)
        directory.trackObservedPane(local)
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.calls == 3)
        withExtendedLifetime((pane, nodeB, local)) {}
    }

    @Test("Retrying a host's account list stops once no tracked pane is on that host")
    func registryRetriesStopWithTheHostsLastPane() async throws {
        let directory = RelayAgentAccountDirectory()
        directory.registryRetryDelays = [.milliseconds(20)]
        let log = LoaderLog(), key = RelayAgentAccountDirectory.hostKey(dandy)
        directory.registryLoader = { _ in
            log.calls += 1
            throw RelayAgentAccountDirectory.Failure.refused("host unreachable")
        }
        let first = PaneModel(profile: dandy), second = PaneModel(profile: dandy)
        directory.trackObservedPane(first)
        directory.trackObservedPane(second)
        for _ in 0..<200 where log.calls < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.calls >= 2)

        // Another pane is still on the host: retries go on.
        directory.untrackObservedPane(first)
        var calls = log.calls
        for _ in 0..<200 where log.calls == calls { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.calls > calls)

        // The host's last pane closes: no further read.
        directory.untrackObservedPane(second)
        #expect(!directory.tracksPane(onHost: key))
        calls = log.calls
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.calls == calls)
        #expect(directory.registryFailures[key] == "host unreachable")

        // A pane opened there later reads the host again.
        let later = PaneModel(profile: dandy)
        directory.trackObservedPane(later)
        for _ in 0..<200 where log.calls == calls { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.calls > calls)
        withExtendedLifetime((first, second, later)) {}
    }

    @Test("Closing a pane stops tracking it for its host's account list")
    func stoppingAPaneUntracksIt() {
        let profile = ConnectionProfile(name: "stop-check", kind: .ssh, host: "stop-check.invalid")
        let key = RelayAgentAccountDirectory.hostKey(profile)
        let pane = PaneModel(profile: profile)
        RelayAgentAccountDirectory.shared.trackObservedPane(pane)
        #expect(RelayAgentAccountDirectory.shared.tracksPane(onHost: key))
        pane.stopRuntime()
        #expect(!RelayAgentAccountDirectory.shared.tracksPane(onHost: key))
    }
}

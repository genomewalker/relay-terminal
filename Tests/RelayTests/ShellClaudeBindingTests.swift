import Foundation
import Testing
@testable import Relay

/// A shell where the user typed `claude` follows its kernel-verified harness.
@MainActor @Suite struct ShellClaudeBindingTests {
    private func harness(_ pane: PaneModel, provider: String, start: String = "kernel:123") -> AgentHarnessIdentity {
        AgentHarnessIdentity(paneID: pane.id, role: provider == "shell" ? "shell" : "harness", provider: provider,
            processes: provider == "shell" ? [] : [.init(provider: provider, pid: 4242, processStart: start)], reason: nil)
    }

    /// A shell that has finished a command, as before typing `claude`.
    private func usedShell() -> PaneModel {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.received("$ cd project\n")
        pane.recordCommandCompletion(exitCode: 0, durationNanos: 1)
        return pane
    }

    @Test func shellWithVerifiedClaudeBindingShowsClaudeAndIsAdmittedToAMove() {
        let pane = usedShell()
        pane.received("\u{1B}]0;Claude Code\u{07}\u{1B}[1mClaude Code\u{1B}[24Gv2.1.308\r\n")
        #expect(pane.kind == .shell)
        #expect(RelayAgentAccountMovePolicy.movableProvider(pane.kind) == nil)
        pane.receivedHarnessIdentity(harness(pane, provider: "claude"))
        #expect(pane.kind == .claude)
        #expect(RelayAgentAccountMovePolicy.movableProvider(pane.kind) == "claude")
        pane.receivedHarnessIdentity(harness(pane, provider: "codex"))
        #expect(RelayAgentAccountMovePolicy.movableProvider(pane.kind) == "codex")
    }

    @Test func unverifiedOrAbsentBindingLeavesTheShell() {
        let pane = usedShell()
        #expect(pane.kind == .shell)
        for start in ["123", "kernel:", "kernel:12a", "kernal:4567"] {
            pane.receivedHarnessIdentity(harness(pane, provider: "claude", start: start))
            #expect(pane.kind == .shell)
        }
        pane.receivedHarnessIdentity(.init(paneID: pane.id, role: "unavailable", provider: nil, processes: [], reason: "Pane process unavailable"))
        let foreign = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.receivedHarnessIdentity(harness(foreign, provider: "claude"))
        #expect(pane.kind == .shell)
        #expect(RelayAgentAccountMovePolicy.movableProvider(pane.kind) == nil)
        #expect(RelayAgentAccountMovePolicy.movableProvider(.other) == nil)
    }

    @Test func bindingThatTurnsToShellRevertsTheKind() {
        let pane = usedShell()
        pane.receivedHarnessIdentity(harness(pane, provider: "claude"))
        #expect(pane.kind == .claude)
        pane.receivedHarnessIdentity(harness(pane, provider: "shell"))
        #expect(pane.kind == .shell)
        #expect(RelayAgentAccountMovePolicy.movableProvider(pane.kind) == nil)
        pane.received("grep found Claude Code in a document\n")
        #expect(pane.kind == .shell)
    }

    /// Root cause: only panes restored at launch subscribed to the harness
    /// monitor, and a completed shell command turns banner detection off, so
    /// a pane opened later could never become Claude.
    @Test func panesOpenedAfterLaunchRequestHarnessIdentity() throws {
        let host = ControlledAgentHost()
        let workspace = WorkspaceModel(restoreSavedWorkspace: false, agentMonitor: host.monitor)
        defer { workspace.shutdown() }
        let initial = try #require(workspace.activePane)
        #expect(initial.agentMonitoringRequested && initial.isAgentMonitored)
        workspace.newTab(profile: .sshConfigHost("shell-claude.invalid"))
        let opened = try #require(workspace.activePane)
        #expect(opened.id != initial.id)
        #expect(opened.agentMonitoringRequested && opened.isAgentMonitored)
        opened.stopAgentMonitoring()
        #expect(!opened.agentMonitoringRequested && !opened.isAgentMonitored)
    }

    @Test func completedShellCommandStillIgnoresPrintedBanners() {
        let pane = usedShell()
        pane.received("Claude Code v2.1.308\n")
        #expect(pane.kind == .shell)
    }
}

/// A host's agent event observer is not a pane's terminal route: opening a
/// pane, and the observer attaching or re-attaching for it, must leave other
/// panes' exit codes and connection states alone. Root's P2 on 1631.
@MainActor @Suite struct AgentObserverAttachmentTests {
    private static let host = "observer-attach.invalid"

    private struct Fixture {
        let host: ControlledAgentHost
        let workspace: WorkspaceModel
        let exited: PaneModel
        let lost: PaneModel
        let transport: ControlledObserverTransport
    }

    /// Two panes on one host: one whose session ended with exit code 7, one
    /// whose terminal connection was lost. Both are observed.
    private func fixture() async throws -> Fixture {
        let host = ControlledAgentHost()
        let workspace = WorkspaceModel(restoreSavedWorkspace: false, agentMonitor: host.monitor)
        host.shells.formUnion(workspace.panes.keys)
        workspace.newTab(profile: .sshConfigHost(Self.host))
        let exited = try #require(workspace.activePane)
        workspace.newTab(profile: .sshConfigHost(Self.host))
        let lost = try #require(workspace.activePane)
        host.shells.formUnion([exited.id, lost.id])
        #expect(exited.isAgentMonitored && lost.isAgentMonitored)
        try await until("observer started") { host.transports(Self.host).count == 1 }
        let transport = try #require(host.transports(Self.host).first)
        #expect(Set(transport.startedSessions.keys) == [session(exited), session(lost)])
        transport.attach(session(exited))
        transport.attach(session(lost))
        try await until("initial attachments") {
            exited.agentObserverAttachments == 1 && lost.agentObserverAttachments == 1
        }
        exited.connected()
        exited.exited(exitCode: 7)
        lost.connected()
        lost.disconnected("transport lost")
        #expect(showsSessionEnded(exited))
        return Fixture(host: host, workspace: workspace, exited: exited, lost: lost, transport: transport)
    }

    private func session(_ pane: PaneModel) -> String { pane.id.uuidString.lowercased() }

    /// WorkspaceView's precedence for SessionEndedOverlay with Restart/Close.
    private func showsSessionEnded(_ pane: PaneModel) -> Bool {
        !(pane.connectionState == .connecting && !pane.hasTerminalSnapshot)
            && pane.connectionState.recoveryMessage == nil
            && !(pane.isRestoringTerminal && !pane.hasTerminalSnapshot)
            && pane.remoteExitCode != nil
    }

    private func expectUntouched(_ fixture: Fixture) {
        #expect(fixture.exited.remoteExitCode == 7)
        #expect(fixture.exited.connectionState == .connected)
        #expect(showsSessionEnded(fixture.exited))
        #expect(fixture.lost.connectionState == .disconnected("transport lost"))
        #expect(fixture.lost.remoteExitCode == nil)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func finish(_ fixture: Fixture) {
        fixture.workspace.panes.values.forEach { $0.stopAgentMonitoring() }
        fixture.workspace.shutdown()
    }

    @Test func newPaneJoinsTheRunningObserverAndReceivesItsHarness() async throws {
        let fixture = try await fixture()
        defer { finish(fixture) }
        fixture.workspace.newTab(profile: .sshConfigHost(Self.host))
        let opened = try #require(fixture.workspace.activePane)
        let openedState = opened.connectionState
        #expect(opened.isAgentMonitored)
        try await until("kernel-verified Claude identity") { opened.kind == .claude }
        // The running stream gained one session. Outlast the 120 ms restart
        // debounce: nothing restarted or stopped it.
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.host.transports(Self.host).count == 1)
        #expect(fixture.transport.stops == 0)
        #expect(fixture.transport.addedSessions == [session(opened)])
        fixture.transport.attach(session(opened))
        try await until("new pane attachment") { opened.agentObserverAttachments == 1 }
        // Only the attached session hears about it.
        #expect(fixture.exited.agentObserverAttachments == 1)
        #expect(fixture.lost.agentObserverAttachments == 1)
        #expect(opened.connectionState == openedState)
        expectUntouched(fixture)
    }

    @Test func observerReattachLeavesExitedAndDisconnectedPanesAlone() async throws {
        let fixture = try await fixture()
        defer { finish(fixture) }
        fixture.workspace.newTab(profile: .sshConfigHost(Self.host))
        let opened = try #require(fixture.workspace.activePane)
        let openedState = opened.connectionState
        try await until("kernel-verified Claude identity") { opened.kind == .claude }
        // A reconnecting observer re-attaches every session, and a legacy
        // observe-many stream attaches once for all of them.
        fixture.transport.attach(nil)
        for pane in [fixture.exited, fixture.lost, opened] { fixture.transport.attach(session(pane)) }
        try await until("re-attachments") {
            fixture.exited.agentObserverAttachments == 3 && fixture.lost.agentObserverAttachments == 3
                && opened.agentObserverAttachments == 2
        }
        expectUntouched(fixture)
        #expect(opened.kind == .claude)
        #expect(opened.connectionState == openedState)
    }
}

/// A host whose agent observer and harness helper the test drives.
@MainActor final class ControlledAgentHost {
    private var made: [ControlledObserverTransport] = []
    /// Panes the helper reports as plain shells; every other pane runs a
    /// kernel-verified Claude.
    var shells: Set<UUID> = []
    private(set) var queries: [[String]] = []

    lazy var monitor = RelayHostAgentMonitor(
        makeTransport: { [unowned self] in
            let transport = ControlledObserverTransport()
            self.made.append(transport)
            return transport
        },
        queryHarnesses: { [unowned self] _, panes in
            self.queries.append(panes)
            return (0, self.report(panes))
        }
    )

    func transports(_ host: String) -> [ControlledObserverTransport] {
        made.filter { $0.startedHost == host }
    }

    private func report(_ panes: [String]) -> Data {
        let identities: [[String: Any]] = panes.compactMap { session in
            guard let id = UUID(uuidString: session) else { return nil }
            if shells.contains(id) {
                return ["pane_id": session, "role": "shell", "provider": "shell", "processes": []]
            }
            return ["pane_id": session, "role": "harness", "provider": "claude",
                    "processes": [["provider": "claude", "pid": 4242, "process_start": "kernel:123"]]]
        }
        return (try? JSONSerialization.data(withJSONObject: ["version": 1, "panes": identities])) ?? Data()
    }
}

final class ControlledObserverTransport: RelayHostAgentObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var onAttached: (@Sendable (String?) -> Void)?
    private var sessions: [String: UInt64] = [:]
    private var added: [String] = []
    private var host: String?

    var startedHost: String? { lock.withLock { host } }
    var startedSessions: [String: UInt64] { lock.withLock { sessions } }
    var addedSessions: [String] { lock.withLock { added } }

    func start(profile: ConnectionProfile, sessions: [String: UInt64],
               onEvent: @escaping @Sendable (String, Data) -> Void,
               onAttached: @escaping @Sendable (String?) -> Void) {
        lock.withLock {
            host = profile.host
            self.sessions = sessions
            self.onAttached = onAttached
        }
    }

    func addSession(_ sessionID: String, cursor: UInt64) -> Bool {
        lock.withLock { added.append(sessionID) }
        return true
    }

    private var stopCount = 0
    var stops: Int { lock.withLock { stopCount } }

    func stop() { lock.withLock { stopCount += 1 } }

    /// The observer reports `attached` for one session, or nil for all.
    func attach(_ sessionID: String?) {
        let onAttached = lock.withLock { self.onAttached }
        onAttached?(sessionID)
    }
}

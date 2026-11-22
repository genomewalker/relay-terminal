import Foundation
import Testing
@testable import Relay

private let gap = RelayBackgroundAttachPolicy.gapNanoseconds
private let ready = RelayBackgroundAttachNode(phase: .ready, generation: 1, heartbeatCurrent: true)

private func candidate(_ host: String = "dandy", id: UUID = UUID(), local: Bool = false, terminal: Bool = true,
                       existing: Bool = true, connecting: Bool = true,
                       viewport: RelayViewport? = RelayViewport(columns: 211, rows: 57)) -> RelayBackgroundAttachCandidate {
    .init(paneID: id, hostKey: host, isLocal: local, isTerminal: terminal, requiresExistingWorker: existing,
          connecting: connecting, savedViewport: viewport)
}

@Suite("RelayBackgroundAttachPolicy")
struct RelayBackgroundAttachPolicyTests {
    @Test("Only a restored Relay terminal with an existing worker and a saved grid is eligible")
    func eligibility() {
        #expect(RelayBackgroundAttachPolicy.eligible(candidate()))
        #expect(RelayBackgroundAttachPolicy.eligible(candidate(local: true)))
        #expect(!RelayBackgroundAttachPolicy.eligible(candidate(local: true, existing: false)))
        #expect(!RelayBackgroundAttachPolicy.eligible(candidate(local: true, viewport: nil)))
        #expect(!RelayBackgroundAttachPolicy.eligible(candidate(local: true, terminal: false)))
        #expect(!RelayBackgroundAttachPolicy.eligible(candidate(terminal: false)))
        // A Hello without require_existing_worker would start a new shell.
        #expect(!RelayBackgroundAttachPolicy.eligible(candidate(existing: false)))
        #expect(!RelayBackgroundAttachPolicy.eligible(candidate(connecting: false)))
        // Without a saved grid the worker would be resized to the default.
        #expect(!RelayBackgroundAttachPolicy.eligible(candidate(viewport: nil)))
    }

    @Test("One attach per host per pass, hosts independent, in candidate order")
    func onePerHost() {
        var policy = RelayBackgroundAttachPolicy()
        let a1 = candidate("a"), a2 = candidate("a"), b1 = candidate("b")
        let chosen = policy.next([a1, a2, b1], nodes: ["a": ready, "b": ready], settled: { _ in false }, now: 0)
        #expect(chosen == [a1, b1])
    }

    @Test("A host waits for its in-flight pane, then for the gap")
    func inFlightThenGap() {
        var policy = RelayBackgroundAttachPolicy()
        let first = candidate(), second = candidate()
        var settled: Set<UUID> = []
        #expect(policy.next([first, second], nodes: ["dandy": ready], settled: { settled.contains($0) }, now: 0) == [first])
        // Still connecting, well past the gap: the host stays held.
        #expect(policy.next([first, second], nodes: ["dandy": ready], settled: { settled.contains($0) }, now: 5 * gap).isEmpty)
        settled.insert(first.paneID)
        #expect(policy.next([first, second], nodes: ["dandy": ready], settled: { settled.contains($0) }, now: 5 * gap) == [second])
    }

    @Test("A settled pane still leaves the full gap before the next attach")
    func gapAfterSettle() {
        var policy = RelayBackgroundAttachPolicy()
        let first = candidate(), second = candidate()
        #expect(policy.next([first, second], nodes: ["dandy": ready], settled: { _ in true }, now: 0) == [first])
        #expect(policy.next([first, second], nodes: ["dandy": ready], settled: { _ in true }, now: gap - 1).isEmpty)
        #expect(policy.next([first, second], nodes: ["dandy": ready], settled: { _ in true }, now: gap) == [second])
    }

    @Test("An attach that never settles releases its host at the timeout")
    func timeout() {
        var policy = RelayBackgroundAttachPolicy()
        let first = candidate(), second = candidate()
        let limit = RelayBackgroundAttachPolicy.attachTimeoutNanoseconds
        _ = policy.next([first, second], nodes: ["dandy": ready], settled: { _ in false }, now: 0)
        #expect(policy.next([first, second], nodes: ["dandy": ready], settled: { _ in false }, now: limit - 1).isEmpty)
        #expect(policy.next([first, second], nodes: ["dandy": ready], settled: { _ in false }, now: limit) == [second])
    }

    @Test("A node that is not ready or has a stale heartbeat gets no attach; no node lets one open it")
    func nodeHealth() {
        let first = candidate(), second = candidate()
        for node in [RelayBackgroundAttachNode(phase: .connecting, generation: 1, heartbeatCurrent: true),
                     .init(phase: .reconnecting, generation: 1, heartbeatCurrent: true),
                     .init(phase: .ready, generation: 1, heartbeatCurrent: false)] {
            var policy = RelayBackgroundAttachPolicy()
            #expect(policy.next([first], nodes: ["dandy": node], settled: { _ in true }, now: 0).isEmpty)
        }
        var policy = RelayBackgroundAttachPolicy()
        #expect(policy.next([first, second], nodes: [:], settled: { _ in false }, now: 0) == [first])
        // The opening attach holds the host like any other.
        #expect(policy.next([first, second], nodes: [:], settled: { _ in false }, now: gap).isEmpty)
    }

    @Test("A stopped node is treated like no node: one attach restarts it, then the host waits")
    func stoppedNodeRestartsOnAttach() {
        var policy = RelayBackgroundAttachPolicy()
        let first = candidate(), second = candidate()
        let stopped = RelayBackgroundAttachNode(phase: .inactive, generation: 3, heartbeatCurrent: false)
        #expect(policy.next([first, second], nodes: ["dandy": stopped], settled: { _ in false }, now: 0) == [first])
        #expect(policy.next([second], nodes: ["dandy": stopped], settled: { _ in false }, now: gap).isEmpty)
        // The restart it causes is a new generation and settles like any other.
        let restarted = RelayBackgroundAttachNode(phase: .ready, generation: 4, heartbeatCurrent: true)
        let settle = RelayBackgroundAttachPolicy.settleAfterRestartNanoseconds
        #expect(policy.next([second], nodes: ["dandy": restarted], settled: { _ in true }, now: 2 * gap).isEmpty)
        #expect(policy.next([second], nodes: ["dandy": restarted], settled: { _ in true }, now: 2 * gap + settle) == [second])
    }

    @Test("A node restart holds its host for the settle period")
    func restartSettles() {
        var policy = RelayBackgroundAttachPolicy()
        let first = candidate(), second = candidate(), third = candidate()
        let settle = RelayBackgroundAttachPolicy.settleAfterRestartNanoseconds
        #expect(policy.next([first, second, third], nodes: ["dandy": ready], settled: { _ in true }, now: 0) == [first])
        let restarted = RelayBackgroundAttachNode(phase: .ready, generation: 2, heartbeatCurrent: true)
        #expect(policy.next([second, third], nodes: ["dandy": restarted], settled: { _ in true }, now: gap).isEmpty)
        #expect(policy.next([second, third], nodes: ["dandy": restarted], settled: { _ in true }, now: gap + settle - 1).isEmpty)
        #expect(policy.next([second, third], nodes: ["dandy": restarted], settled: { _ in true }, now: gap + settle) == [second])
    }

    // dandy-07, 2026-11-22 12:52Z: the node reconnected in place within a
    // second; 68 hidden agent panes attached before it stayed "Reconnecting"
    // because each was already attempted and its route waited to be shown.
    @Test("A pane started before an in-place reconnect is woken after it, once per reconnect, after the settle")
    func wakesAPaneLeftWaitingByAReconnect() {
        var policy = RelayBackgroundAttachPolicy()
        let id = UUID()
        let started = candidate(id: id)
        let settle = RelayBackgroundAttachPolicy.settleAfterRestartNanoseconds
        #expect(policy.next([started], nodes: ["dandy": ready], settled: { _ in true }, now: 0) == [started])
        var waiting = candidate(id: id, connecting: false, viewport: nil)
        waiting.waitingAfterReconnect = true
        #expect(RelayBackgroundAttachPolicy.eligible(waiting))
        #expect(policy.pending(waiting), "already attempted, but a waiting pane is still pending")
        let reconnected = RelayBackgroundAttachNode(phase: .ready, generation: 2, heartbeatCurrent: true)
        #expect(policy.next([waiting], nodes: ["dandy": reconnected], settled: { _ in true }, now: gap).isEmpty)
        #expect(policy.next([waiting], nodes: ["dandy": reconnected], settled: { _ in true }, now: gap + settle) == [waiting])
        // Woken: it no longer reports waiting, so it is not chosen again.
        #expect(policy.next([candidate(id: id, connecting: false)], nodes: ["dandy": reconnected],
            settled: { _ in true }, now: 3 * gap + settle).isEmpty)
    }

    @Test("Waiting panes on one host are woken one at a time, at the longer wake gap")
    func wakesOneAtATimePerHost() {
        var policy = RelayBackgroundAttachPolicy()
        let wakeGap = RelayBackgroundAttachPolicy.wakeGapNanoseconds
        var first = candidate(connecting: false), second = candidate(connecting: false)
        first.waitingAfterReconnect = true
        second.waitingAfterReconnect = true
        #expect(policy.next([first, second], nodes: ["dandy": ready], settled: { _ in false }, now: 0) == [first])
        #expect(policy.next([second], nodes: ["dandy": ready], settled: { _ in false }, now: wakeGap).isEmpty,
            "the woken pane holds its host until connected")
        #expect(policy.next([second], nodes: ["dandy": ready], settled: { _ in true }, now: wakeGap - 1).isEmpty,
            "settled, but within the wake gap")
        #expect(policy.next([second], nodes: ["dandy": ready], settled: { _ in true }, now: wakeGap) == [second])
    }

    // 57c1 review: the 12:52Z drop followed a wave of multi-MB replays. If
    // wakes drop the node again, every pane waits again; waking them again
    // would loop. A host whose node reconnects within the drop window of a
    // wake holds its wakes for that generation; a later reconnect clears it.
    @Test("A reconnect soon after a wake holds that host's wakes until a later reconnect")
    func reconnectAfterWakeHoldsWakes() {
        var policy = RelayBackgroundAttachPolicy()
        let settle = RelayBackgroundAttachPolicy.settleAfterRestartNanoseconds
        let window = RelayBackgroundAttachPolicy.wakeDropWindowNanoseconds
        func waiting() -> RelayBackgroundAttachCandidate {
            var c = candidate(connecting: false); c.waitingAfterReconnect = true; return c
        }
        func node(_ generation: Int) -> RelayBackgroundAttachNode { .init(phase: .ready, generation: generation, heartbeatCurrent: true) }
        let a = waiting(), b = waiting(), fresh = candidate()
        #expect(policy.next([a], nodes: ["dandy": node(2)], settled: { _ in true }, now: 0) == [a])
        // The node drops 30 s after the wake.
        let drop: UInt64 = 30_000_000_000
        #expect(policy.next([a, b], nodes: ["dandy": node(3)], settled: { _ in true }, now: drop).isEmpty)
        #expect(policy.next([a, b], nodes: ["dandy": node(3)], settled: { _ in true }, now: drop + settle + window).isEmpty,
            "no wake in the generation the wakes may have caused")
        #expect(!policy.pending(a) && !policy.pending(b), "held panes do not keep the scheduler running")
        #expect(policy.next([a, fresh], nodes: ["dandy": node(3)], settled: { _ in true }, now: drop + settle + window) == [fresh],
            "a never-started pane still attaches")
        // A later reconnect, long after the last wake, wakes again.
        let later = drop + settle + 2 * window
        #expect(policy.next([a, b], nodes: ["dandy": node(4)], settled: { _ in true }, now: later).isEmpty)
        #expect(policy.next([a, b], nodes: ["dandy": node(4)], settled: { _ in true }, now: later + settle) == [a])
    }

    @Test("A pane is attempted once")
    func attemptedOnce() {
        var policy = RelayBackgroundAttachPolicy()
        let only = candidate()
        #expect(policy.next([only], nodes: ["dandy": ready], settled: { _ in true }, now: 0) == [only])
        #expect(policy.next([only], nodes: ["dandy": ready], settled: { _ in true }, now: 10 * gap).isEmpty)
        #expect(policy.isIdle)
    }
}

@MainActor @Suite("RelayBackgroundAttachScheduler")
struct RelayBackgroundAttachSchedulerTests {
    private func pane(_ host: String, existing: Bool = true) -> PaneModel {
        PaneModel(profile: .sshConfigHost(host), requiresExistingWorker: existing)
    }

    @Test("Starts each eligible pane at its saved grid, staggered, and stops when none is left")
    func startsAtSavedGrid() {
        let scheduler = RelayBackgroundAttachScheduler()
        let saved = pane("dandy.invalid"), other = pane("dandy.invalid"), unsaved = pane("dandy.invalid"),
            fresh = pane("dandy.invalid", existing: false)
        let grids: [UUID: RelayViewport] = [saved.id: .init(columns: 211, rows: 57), other.id: .init(columns: 90, rows: 30),
                                            fresh.id: .init(columns: 80, rows: 24)]
        var now: UInt64 = 0
        var started: [(UUID, RelayViewport)] = []
        scheduler.panes = { [saved, other, unsaved, fresh] }
        scheduler.nodes = { [] }
        scheduler.uptime = { now }
        scheduler.savedViewport = { grids[$0] }
        scheduler.start = { pane, viewport in started.append((pane.id, viewport)); pane.connectionState = .connected }
        #expect(scheduler.step())
        #expect(started.count == 1)
        now = RelayBackgroundAttachPolicy.gapNanoseconds
        #expect(scheduler.step())
        now *= 2
        #expect(!scheduler.step())
        #expect(Set(started.map(\.0)) == [saved.id, other.id])
        for (id, viewport) in started { #expect(grids[id] == viewport) }
    }

    private func node(_ pane: PaneModel, _ phase: NetworkTransportSnapshot.Phase, generation: Int = 2,
                      confirmed: UInt64?) -> NetworkTransportSnapshot {
        .init(id: pane.profile.connectionKey, host: pane.profile.host, account: "", port: 22, phase: phase,
              generation: generation, attachedSubscriptions: 0, lastConfirmedUptime: confirmed)
    }

    // dandy-07, 2026-10-30 08:14Z: the panes attached so far moved to
    // dedicated connections, the pooled node's last subscription closed and
    // it stopped. The panes after that point never attached.
    @Test("Panes keep attaching after the host's node stops")
    func attachesAfterTheNodeStops() {
        let scheduler = RelayBackgroundAttachScheduler()
        let panes = (0..<5).map { _ in pane("dandy.invalid") }
        var now: UInt64 = 0
        var started: [UUID] = []
        var phase = NetworkTransportSnapshot.Phase.ready
        scheduler.panes = { panes }
        scheduler.nodes = { [self] in [node(panes[0], phase, confirmed: phase == .ready ? now : nil)] }
        scheduler.uptime = { now }
        scheduler.savedViewport = { _ in .init(columns: 112, rows: 34) }
        scheduler.start = { pane, _ in started.append(pane.id); pane.connectionState = .connected }
        scheduler.record = { _, _ in }
        #expect(scheduler.step())
        now += RelayBackgroundAttachPolicy.gapNanoseconds
        #expect(scheduler.step())
        #expect(started.count == 2)
        phase = .inactive
        for _ in 0..<40 where started.count < panes.count {
            now += RelayBackgroundAttachPolicy.gapNanoseconds
            scheduler.step()
        }
        #expect(Set(started) == Set(panes.map(\.id)))
        #expect(!scheduler.step())
    }

    @Test("A started hidden pane left waiting by a node reconnect is woken, not restarted, and holds its host until connected")
    func wakesStartedPanesAfterAReconnect() {
        let scheduler = RelayBackgroundAttachScheduler()
        let panes = (0..<3).map { _ in pane("dandy.invalid") }
        var now: UInt64 = 0
        var generation = 1
        var waiting: Set<UUID> = []
        var started: [UUID] = [], woken: [UUID] = []
        scheduler.panes = { panes }
        scheduler.nodes = { [self] in [node(panes[0], .ready, generation: generation, confirmed: now)] }
        scheduler.uptime = { now }
        scheduler.savedViewport = { _ in .init(columns: 112, rows: 34) }
        scheduler.start = { pane, _ in started.append(pane.id); pane.connectionState = .connected }
        scheduler.waiting = { waiting.contains($0.id) }
        scheduler.wake = { pane in woken.append(pane.id); waiting.remove(pane.id) }
        scheduler.record = { _, _ in }
        for _ in 0..<10 where started.count < panes.count {
            scheduler.step()
            now += RelayBackgroundAttachPolicy.gapNanoseconds
        }
        #expect(Set(started) == Set(panes.map(\.id)))
        #expect(!scheduler.step())
        // The node reconnects in place: every hidden pane's route now waits.
        generation = 2
        for pane in panes { pane.connectionState = .reconnecting("Connection interrupted."); waiting.insert(pane.id) }
        #expect(scheduler.step(), "waiting panes keep the scheduler running")
        #expect(woken.isEmpty, "the host settles after its node restarted")
        now += RelayBackgroundAttachPolicy.settleAfterRestartNanoseconds
        scheduler.step()
        #expect(woken.count == 1)
        now += 2 * RelayBackgroundAttachPolicy.gapNanoseconds
        scheduler.step()
        #expect(woken.count == 1, "a woken pane holds its host until it is connected")
        for pane in panes where woken.contains(pane.id) { pane.connectionState = .connected }
        for _ in 0..<10 where woken.count < panes.count {
            now += RelayBackgroundAttachPolicy.wakeGapNanoseconds
            scheduler.step()
            for pane in panes where woken.contains(pane.id) { pane.connectionState = .connected }
        }
        #expect(Set(woken) == Set(panes.map(\.id)))
        #expect(started.count == panes.count, "no pane is started a second time")
        #expect(!scheduler.step())
    }

    @Test("A host held with waiting panes is recorded after 30 s, then at most once a minute")
    func recordsAHeldHost() {
        let scheduler = RelayBackgroundAttachScheduler()
        let waiting = [pane("dandy.invalid"), pane("dandy.invalid")]
        var now: UInt64 = 0
        var records: [(String, [String: String])] = []
        var phase = NetworkTransportSnapshot.Phase.connecting
        scheduler.panes = { waiting }
        scheduler.nodes = { [self] in [node(waiting[0], phase, confirmed: phase == .ready ? now : nil)] }
        scheduler.uptime = { now }
        scheduler.savedViewport = { _ in .init(columns: 112, rows: 34) }
        scheduler.start = { pane, _ in pane.connectionState = .connected }
        scheduler.record = { records.append(($0, $1)) }
        let second: UInt64 = 1_000_000_000
        for t in stride(from: UInt64(0), through: 29, by: 1) { now = t * second; scheduler.step() }
        #expect(records.isEmpty)
        now = 30 * second
        scheduler.step()
        #expect(records.count == 1)
        #expect(records.first?.0 == "background-attach-waiting")
        #expect(records.first?.1 == ["host": waiting[0].profile.connectionKey, "waiting": "2", "held_seconds": "30",
                                     "node_phase": "connecting", "heartbeat_current": "false"])
        for t in stride(from: UInt64(31), through: 89, by: 1) { now = t * second; scheduler.step() }
        #expect(records.count == 1)
        now = 90 * second
        scheduler.step()
        #expect(records.count == 2)
        // An attach releases the hold. The next hold is timed from scratch and
        // still respects the once-a-minute limit (last record at 90 s).
        phase = .ready
        now = 91 * second
        scheduler.step()
        #expect(records.count == 2)
        phase = .connecting
        for t in stride(from: UInt64(92), through: 149, by: 1) { now = t * second; scheduler.step() }
        #expect(records.count == 2)
        now = 150 * second
        scheduler.step()
        #expect(records.count == 3)
        #expect(records.last?.1["waiting"] == "1")
        #expect(records.last?.1["held_seconds"] == "58")
    }

    @Test("Panes in a workspace's shown tab are left to their own layout")
    func shownTabExcluded() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.newTab(profile: .sshConfigHost("dandy.invalid"))
        let hiddenIDs = Set(workspace.tabs.dropLast().flatMap(\.allPaneIDs))
        let shownIDs = Set(workspace.selectedTab?.allPaneIDs ?? [])
        #expect(!shownIDs.isEmpty && !hiddenIDs.isEmpty)
        #expect(Set(RelayBackgroundAttachScheduler.hiddenPanes(workspace).map(\.id)) == hiddenIDs)
    }
}

@Suite("RelayBackgroundAttachViewport")
struct RelayBackgroundAttachViewportTests {
    @Test("A seeded grid is the first Hello's grid; a seed after the transport is ignored")
    func seededHello() {
        let io = TerminalIOBridge()
        let saved = RelayViewport(columns: 211, rows: 57)
        io.seedInitialViewport(saved)
        let transport = RelayRemoteTransport(attachedFrameWriter: NullFrames(),
            profile: .init(name: "Background attach", host: "owned-peer.invalid"), paneID: UUID(),
            capabilities: [], controlGranted: true)
        io.installTransport(transport)
        defer { _ = io.removeTransport(); transport.detach() }
        let hello = transport.nextMultiplexedHello()
        #expect(hello?["cols"] as? UInt16 == 211)
        #expect(hello?["rows"] as? UInt16 == 57)
        io.seedInitialViewport(RelayViewport(columns: 80, rows: 24))
        #expect(io.currentViewport == saved)
    }

    @Test("The store reads a saved pane's grid from its log header")
    func storeSavedViewport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-bg-attach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalSnapshotStore(directory: directory)
        let paneID = UUID()
        #expect(store.savedViewport(paneID: paneID) == nil)
        store.saveSynchronously(Data("\u{1b}[H$ ".utf8), paneID: paneID, viewport: .init(columns: 211, rows: 57), remoteSequence: 3)
        #expect(store.savedViewport(paneID: paneID) == RelayViewport(columns: 211, rows: 57))
    }
}

private final class NullFrames: RelayFrameWriting, @unchecked Sendable {
    func write(type: RelayWireType, payload: Data) throws {}
    func writeAsync(type: RelayWireType, payload: Data) {}
}

/// Seeded fuzz target for the snapshot log header reader (a file another
/// Relay process wrote). Seeds are fixed; add found crashers to `regressions`.
@Suite("RelayBackgroundAttachHeaderFuzz")
struct RelayBackgroundAttachHeaderFuzzTests {
    static let seeds: [UInt64] = [1, 0x5eed_0030_1030, 0xdead_beef, 0x0973_ab2c_4c61]
    static let regressions: [Data] = [
        Data(), Data("RELAYSL1".utf8), Data("RELAYSL1".utf8) + Data([0, 0, 0, 0]),
        Data("RELAYSL1".utf8) + Data([0, 80, 0]), Data("RELAYSL2".utf8) + Data([0, 80, 0, 24]),
        Data("RELAYSL1".utf8) + Data([0xff, 0xff, 0xff, 0xff]),
    ]

    @Test("Round trip, truncation refused, junk after the header ignored, no zero grid")
    func header() {
        var cases = 0
        for seed in Self.seeds {
            var rng = SplitMix64(state: seed)
            for _ in 0..<2000 {
                let viewport = RelayViewport(columns: UInt16(truncatingIfNeeded: rng.next()), rows: UInt16(truncatingIfNeeded: rng.next()))
                let header = TerminalSnapshotLogCodec.header(viewport: viewport)
                #expect(TerminalSnapshotLogCodec.headerViewport(header) == viewport)
                let junk = Data((0..<rng.below(64)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
                #expect(TerminalSnapshotLogCodec.headerViewport(header + junk) == viewport)
                // A slice not starting at index 0 reads the same.
                let padded = (Data([7]) + header + junk).dropFirst()
                #expect(TerminalSnapshotLogCodec.headerViewport(padded) == viewport)
                #expect(TerminalSnapshotLogCodec.headerViewport(header.prefix(rng.below(header.count))) == nil)
                var bytes = Data((0..<rng.below(24)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
                if rng.below(2) == 0 { bytes = TerminalSnapshotLogCodec.magic + bytes }
                Self.check(bytes)
                cases += 1
            }
        }
        Self.regressions.forEach(Self.check)
        #expect(cases == Self.seeds.count * 2000)
    }

    /// A result exists only for the magic and a full header, and is exactly
    /// the two big-endian dimensions, both nonzero.
    static func check(_ bytes: Data) {
        let parsed = TerminalSnapshotLogCodec.headerViewport(bytes)
        let b = [UInt8](bytes)
        let valid = b.count >= 12 && Data(b.prefix(8)) == TerminalSnapshotLogCodec.magic
        guard valid else { #expect(parsed == nil); return }
        let columns = UInt16(b[8]) << 8 | UInt16(b[9]), rows = UInt16(b[10]) << 8 | UInt16(b[11])
        #expect(parsed == (columns > 0 && rows > 0 ? RelayViewport(columns: columns, rows: rows) : nil))
    }
}

import Foundation
import Testing
@testable import Relay

@MainActor @Suite("RelayBackgroundAttachOrder")
struct RelayBackgroundAttachOrderTests {
    /// The order step() used before it compared raw UUID bytes.
    private func stringOrder(_ panes: [PaneModel]) -> [PaneModel] {
        panes.sorted { ($0.kind == .shell ? 1 : 0, $0.id.uuidString) < ($1.kind == .shell ? 1 : 0, $1.id.uuidString) }
    }

    private func agent(_ pane: PaneModel) -> PaneModel {
        pane.receivedHarnessIdentity(AgentHarnessIdentity(paneID: pane.id, role: "harness", provider: "claude",
            processes: [.init(provider: "claude", pid: 77, processStart: "kernel:1")], reason: nil))
        return pane
    }

    /// UUIDs that share long prefixes and differ in single nibbles, so every
    /// hex digit and hyphen position decides some comparison.
    private func nearUUIDs<G: RandomNumberGenerator>(_ count: Int, using rng: inout G) -> [UUID] {
        let base = UUID().uuid
        return (0..<count).map { _ in
            var bytes = withUnsafeBytes(of: base) { Array($0) }
            let index = Int.random(in: 0..<16, using: &rng)
            bytes[index] = UInt8.random(in: 0...255, using: &rng)
            if Bool.random(using: &rng) { bytes[Int.random(in: 0..<16, using: &rng)] = [0x00, 0x09, 0x0a, 0x90, 0xa0, 0xff].randomElement(using: &rng)! }
            return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        }
    }

    @Test("Byte order of UUIDs equals the order of their uuidString")
    func uuidOrderMatchesString() {
        var rng = SeededGenerator(seed: 0x5eed_0001)
        let ids = (0..<300).map { _ in UUID() } + nearUUIDs(300, using: &rng)
        for _ in 0..<20_000 {
            let a = ids.randomElement(using: &rng)!, b = ids.randomElement(using: &rng)!
            #expect(RelayBackgroundAttachScheduler.uuidPrecedes(a, b) == (a.uuidString < b.uuidString))
        }
        for a in ids { #expect(!RelayBackgroundAttachScheduler.uuidPrecedes(a, a)) }
    }

    @Test("Attach order equals the former string sort, agents first, with ties kept in input order")
    func orderMatchesStringSort() {
        var rng = SeededGenerator(seed: 0x5eed_0002)
        for round in 0..<25 {
            let ids = round.isMultiple(of: 2) ? (0..<40).map { _ in UUID() } : nearUUIDs(40, using: &rng)
            var panes = ids.map { id in PaneModel(id: id, profile: .sshConfigHost("order.invalid")) }
            for index in panes.indices where Bool.random(using: &rng) { panes[index] = agent(panes[index]) }
            // Ties: the same UUID in two panes, and the same pane twice.
            panes.append(PaneModel(id: panes[0].id, profile: .sshConfigHost("order.invalid")))
            panes.append(agent(PaneModel(id: panes[1].id, profile: .sshConfigHost("order.invalid"))))
            panes.append(panes[2])
            panes.shuffle(using: &rng)
            let expected = stringOrder(panes), actual = RelayBackgroundAttachScheduler.attachOrder(panes)
            #expect(actual.map(ObjectIdentifier.init) == expected.map(ObjectIdentifier.init), "round \(round)")
        }
    }

    @Test("Prints the cost of ordering 150 hidden panes, before and after")
    func measureOrdering() {
        let panes = (0..<150).map { index -> PaneModel in
            let pane = PaneModel(profile: .sshConfigHost("measure.invalid"))
            return index.isMultiple(of: 3) ? agent(pane) : pane
        }
        let ticks = 200
        func time(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<ticks { body() }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(ticks) / 1_000
        }
        var sink = 0
        let before = time { sink &+= stringOrder(panes).count }
        let after = time { sink &+= RelayBackgroundAttachScheduler.attachOrder(panes).count }
        let kindOnly = time { sink &+= panes.filter { $0.kind == .shell }.count }
        print("background-attach order, 150 panes, per tick: string sort \(String(format: "%.1f", before)) us, byte sort \(String(format: "%.1f", after)) us, of which reading each kind once \(String(format: "%.1f", kindOnly)) us (sink \(sink))")
    }
}

@Suite("RelayBackgroundAttachPrefetch")
struct RelayBackgroundAttachPrefetchTests {
    private func temporaryStore() -> (TerminalSnapshotStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-bg-prefetch-\(UUID().uuidString)")
        return (TerminalSnapshotStore(directory: directory), directory)
    }

    @Test("A prefetched restore yields the same bytes, cursor and trackers as reading the disk")
    func prefetchedMatchesDisk() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paneID = UUID(), viewport = RelayViewport(columns: 132, rows: 40)
        // A checkpoint followed by appended deltas, the order restore must keep.
        var stream = Data("\u{1b}[H\u{1b}[2J\u{1b}[?2004h$ one\r\n".utf8)
        store.saveSynchronously(stream, paneID: paneID, viewport: viewport, remoteSequence: 10)
        for step in 0..<6 {
            stream.append(Data("line \(step) \u{1b}[1mbold\u{1b}[0m\r\n".utf8))
            store.save(stream, paneID: paneID, viewport: viewport, remoteSequence: 11 + UInt64(step))
        }
        store.saveSynchronously(stream, paneID: paneID, viewport: viewport, remoteSequence: 20)

        let fromDisk = try #require(TerminalSnapshotStore(directory: directory).loadSnapshot(paneID: paneID, viewport: viewport))
        let reader = TerminalSnapshotStore(directory: directory)
        let prefetched = reader.prefetch(paneID: paneID)
        let fromPrefetch = try #require(reader.loadSnapshot(paneID: paneID, viewport: viewport, prefetched: prefetched))
        #expect(fromDisk.payload == stream)
        #expect(fromPrefetch.payload == fromDisk.payload)
        #expect(fromPrefetch.remoteSequence == 20 && fromDisk.remoteSequence == 20)
        #expect(fromPrefetch.trackerState == fromDisk.trackerState)
        // The cursor-only fallbacks read the same prefetched log.
        let other = RelayViewport(columns: 80, rows: 24)
        #expect(reader.loadSnapshot(paneID: paneID, viewport: other, prefetched: prefetched) == nil)
        #expect(reader.loadResumeCursor(paneID: paneID, prefetched: prefetched) == 20)
        #expect(reader.loadBracketedPasteState(paneID: paneID, prefetched: prefetched)
            == TerminalSnapshotStore(directory: directory).loadBracketedPasteState(paneID: paneID))
        // A prefetch for another pane is never used in place of this one's.
        #expect(reader.loadResumeCursor(paneID: UUID(), prefetched: prefetched) == nil)
    }

    @Test("A queued prefetch sees every save queued before it")
    func prefetchFollowsQueuedSaves() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paneID = UUID(), viewport = RelayViewport(columns: 100, rows: 30)
        var stream = Data()
        for step in 0..<40 {
            stream.append(Data("\(step): \(String(repeating: "x", count: step))\r\n".utf8))
            store.save(stream, paneID: paneID, viewport: viewport, remoteSequence: UInt64(step + 1))
        }
        let prefetched = await withCheckedContinuation { continuation in
            store.prefetch(paneID: paneID) { continuation.resume(returning: $0) }
        }
        let log = try #require(prefetched.log)
        #expect(log.payload == stream)
        #expect(log.remoteSequence == 40)
        #expect(prefetched.legacyRecord == nil)
    }

    @Test("The IO bridge restores a prefetched log without changing it")
    func bridgeRestoresPrefetched() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paneID = UUID(), viewport = RelayViewport(columns: 120, rows: 36)
        defer { TerminalSnapshotStore.shared.remove(paneID: paneID) }
        store.saveSynchronously(Data("\u{1b}[H\u{1b}[2J$ restored\r\n$ ".utf8), paneID: paneID, viewport: viewport, remoteSequence: 77)
        let io = TerminalIOBridge()
        io.seedInitialViewport(viewport)
        let restoration = try #require(io.restoreSnapshot(paneID: paneID, prefetched: store.prefetch(paneID: paneID)))
        #expect(restoration.remoteSequence == 77)
        #expect(restoration.rendered)
    }
}

@MainActor @Suite("RelayBackgroundAttachStaleRead")
struct RelayBackgroundAttachStaleReadTests {
    private func heldRuntime() -> (PaneModel, () -> [@MainActor (TerminalSnapshotStore.Prefetched) -> Void]) {
        let pane = PaneModel(profile: .sshConfigHost("stale.invalid"), requiresExistingWorker: true)
        var held: [@MainActor (TerminalSnapshotStore.Prefetched) -> Void] = []
        pane.runtime.backgroundSnapshotLoader = { _, completion in held.append(completion) }
        return (pane, { held })
    }

    private func empty(_ pane: PaneModel) -> TerminalSnapshotStore.Prefetched {
        .init(paneID: pane.id, log: nil, legacyRecord: nil)
    }

    @Test("A read overtaken by a stop is dropped")
    func stopDropsRead() {
        let (pane, held) = heldRuntime()
        pane.runtime.startInBackground(viewport: .init(columns: 90, rows: 30))
        #expect(held().count == 1)
        #expect(!pane.runtime.hasStarted)
        pane.runtime.stop()
        held()[0](empty(pane))
        #expect(!pane.runtime.hasStarted)
        #expect(pane.runtime.ioForTesting.currentViewport != RelayViewport(columns: 90, rows: 30))
    }

    @Test("A read overtaken by a newer background start is dropped")
    func reattachDropsRead() {
        let (pane, held) = heldRuntime()
        pane.runtime.startInBackground(viewport: .init(columns: 90, rows: 30))
        pane.runtime.startInBackground(viewport: .init(columns: 91, rows: 31))
        #expect(held().count == 2)
        held()[0](empty(pane))
        #expect(!pane.runtime.hasStarted)
        #expect(pane.runtime.ioForTesting.currentViewport != RelayViewport(columns: 90, rows: 30))
    }

    @Test("A read for a pane that has gone is dropped")
    func closedPaneDropsRead() {
        var completion: (@MainActor (TerminalSnapshotStore.Prefetched) -> Void)?
        weak var runtimeRef: TerminalRuntime?
        let paneID: UUID
        do {
            let pane = PaneModel(profile: .sshConfigHost("stale.invalid"), requiresExistingWorker: true)
            paneID = pane.id
            runtimeRef = pane.runtime
            pane.runtime.backgroundSnapshotLoader = { _, done in completion = done }
            pane.runtime.startInBackground(viewport: .init(columns: 90, rows: 30))
        }
        // Firing after the pane is released must neither crash nor start anything.
        completion?(.init(paneID: paneID, log: nil, legacyRecord: nil))
        #expect(runtimeRef?.hasStarted != true)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49eb_133b_a111
        return z ^ (z >> 31)
    }
}

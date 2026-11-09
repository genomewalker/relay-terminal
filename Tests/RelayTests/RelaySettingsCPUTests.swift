import AppKit
import Combine
import Foundation
@testable import GhosttyTerminal
import Testing
@testable import Relay

// Settings-window CPU fix (2026-11-02): a cached settings feed that runs only
// while its window shows, and an admission-checked active-screen cache.

// MARK: - Active-screen cache: exhaustive bounded check against a screen model

/// One terminal row. `faint` is the attribute plain text cannot see.
private struct ScreenModel {
    var generation: UInt64 = 1
    var mutations: UInt64 = 0
    var inFlight = false
    var columns: UInt16 = 80
    var text = "❯ a"
    var faint = true
    var attached = true
    var dumpFails = false

    func state() -> InMemoryTerminalScreenState? {
        guard attached else { return nil }
        return InMemoryTerminalScreenState(surfaceGeneration: generation, mutations: mutations,
                                           mutationInFlight: inFlight, columns: columns, rows: 24)
    }
    func rows() -> [String]? { attached ? [text] : nil }
    /// The serialized screen: grid width, attribute and text.
    func dump() -> String? { attached && !dumpFails ? "\(columns)|\(faint ? "2m" : "0m")|\(text)" : nil }

    /// The only correct result of a read with nothing concurrent.
    var quiescent: RelayActiveScreenCache.Observation {
        guard let state = state() else { return .noSurface }
        guard !inFlight, let rows = rows(), let screen = dump() else { return .unstable }
        return .screen(screen, .init(state: state, rows: rows))
    }

    /// A change made during a read. `output` is counted host output applied
    /// whole; `parseStart` is output still being parsed; `binding` changes
    /// text without the mutation count (e.g. clear_screen); `detach` removes
    /// the surface.
    enum Mutation: CaseIterable { case output, parseStart, binding, detach }
    /// Where in the read it lands: around the first sample's rows read, the
    /// dump, and the second sample's rows read.
    enum Point: CaseIterable { case beforeRows, beforeSecondState, beforeDump, afterDump, beforeAfterRows, beforeAfterSecondState }
    enum Op: Hashable {
        case parseAttrStart, parseTextStart, parseEnd, resize, swapSurfaceToggled, bindingToggle, detachToggle
        case read, readDumpFails, readWith(Mutation, Point)
    }

    static let quiescentOps: [Op] = [.parseAttrStart, .parseTextStart, .parseEnd, .resize, .swapSurfaceToggled,
                                     .bindingToggle, .detachToggle]
    /// The 12 operations of the first patch's check, under the new oracle.
    static let originalOps = quiescentOps + [.read, .readWith(.output, .beforeDump), .readWith(.binding, .beforeDump),
                                             .readWith(.output, .afterDump), .readWith(.binding, .afterDump)]
    /// Every mutation at every point, plus a failed dump.
    static let allOps = quiescentOps + [.read, .readDumpFails] +
        Mutation.allCases.flatMap { mutation in Point.allCases.map { Op.readWith(mutation, $0) } }

    mutating func parseEnd() { if inFlight { mutations += 1; inFlight = false } }
    mutating func toggleText(_ other: String) { text = text == "❯ a" ? other : "❯ a" }

    mutating func apply(_ mutation: Mutation) {
        switch mutation {
        case .output: faint.toggle(); inFlight = true; parseEnd()
        case .parseStart: inFlight = true; toggleText("❯ c")
        case .binding: toggleText("❯ b")
        case .detach: attached = false
        }
    }

    mutating func apply(_ op: Op) {
        switch op {
        case .parseAttrStart: inFlight = true; faint.toggle()
        case .parseTextStart: apply(.parseStart)
        case .parseEnd: parseEnd()
        case .resize: columns = columns == 80 ? 100 : 80
        // A replacement surface whose replay has not been counted yet.
        case .swapSurfaceToggled: generation += 1; faint.toggle()
        case .bindingToggle: apply(.binding)
        case .detachToggle: attached.toggle()
        case .read, .readDumpFails, .readWith: break
        }
    }
}

private struct CacheCheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Runs one read against the model through the real sampler, firing the
/// op's mutation at its point, and returns the result with whether the read
/// was a hit (no dump).
private func modelRead(_ op: ScreenModel.Op, _ model: inout ScreenModel, _ cache: inout RelayActiveScreenCache)
    -> (RelayActiveScreenCache.Observation, fired: Bool, hit: Bool) {
    var injection: (ScreenModel.Mutation, ScreenModel.Point)?
    if case .readWith(let mutation, let point) = op { injection = (mutation, point) }
    if op == .readDumpFails { model.dumpFails = true }
    var current = model
    var fired = false
    var stateReads = 0, rowReads = 0
    func fire(_ point: ScreenModel.Point) {
        guard let (mutation, at) = injection, at == point, !fired else { return }
        current.apply(mutation)
        fired = true
    }
    let dumps = cache.dumps
    let result = cache.read(sample: {
        RelayActiveScreenCache.sample(state: {
            stateReads += 1
            if stateReads == 2 { fire(.beforeSecondState) }
            if stateReads == 4 { fire(.beforeAfterSecondState) }
            return current.state()
        }, rows: {
            rowReads += 1
            fire(rowReads == 1 ? .beforeRows : .beforeAfterRows)
            return current.rows()
        })
    }, dump: {
        fire(.beforeDump)
        let screen = current.dump()
        fire(.afterDump)
        return screen
    })
    // A mutation whose point the read never reached happens after it.
    if let (mutation, _) = injection, !fired { current.apply(mutation) }
    current.dumpFails = false
    model = current
    return (result, fired, cache.dumps == dumps)
}

/// The exact result each read must give. Counted output, a parse in flight
/// and a detach change the screen state, so landing anywhere inside the read
/// makes it unstable. A binding action changes only text, which the sampler
/// sees through the rows: before the first rows read it is simply before the
/// read; between the first and the last rows read it must make the read
/// unstable; after the last rows read no reader can see it, and the read
/// returns the screen it observed (the send fence re-samples at the write).
private func expectedRead(_ op: ScreenModel.Op, pre: ScreenModel, post: ScreenModel, fired: Bool,
                          hit: Bool) -> RelayActiveScreenCache.Observation {
    switch op {
    case .readDumpFails:
        return hit || pre.quiescent.screen == nil ? pre.quiescent : .unstable
    case .readWith(.binding, let point) where fired:
        switch point {
        case .beforeRows: return post.quiescent
        case .beforeSecondState: return hit ? pre.quiescent : .unstable
        case .beforeDump, .afterDump, .beforeAfterRows: return .unstable
        case .beforeAfterSecondState: return pre.quiescent
        }
    case .readWith where fired:
        return .unstable
    default:
        return pre.quiescent
    }
}

private func exploreCache(_ model: ScreenModel, _ cache: RelayActiveScreenCache, ops: [ScreenModel.Op], depth: Int,
                          path: [ScreenModel.Op], states: inout Int) throws {
    states += 1
    guard depth > 0 else { return }
    for op in ops {
        var model = model
        var cache = cache
        let trace = path + [op]
        switch op {
        case .read, .readDumpFails, .readWith:
            let pre = model
            let (result, fired, hit) = modelRead(op, &model, &cache)
            let expected = expectedRead(op, pre: pre, post: model, fired: fired, hit: hit)
            guard result == expected else {
                throw CacheCheckFailure(description: "read \(result) != \(expected) after \(trace)")
            }
        default:
            model.apply(op)
        }
        try exploreCache(model, cache, ops: ops, depth: depth - 1, path: trace, states: &states)
    }
}

private func statesExplored(ops: Int, depth: Int) -> Int {
    (0...depth).reduce(0) { $0 + Int(pow(Double(ops), Double($1))) }
}

@Suite("Active-screen cache")
struct RelayActiveScreenCacheTests {
    /// Bound: every sequence of up to 6 operations over the first patch's 12.
    /// Property after each read: exactly the result `expectedRead` names; a
    /// screen is returned only when no detectable change landed inside the
    /// read, and then it is the fresh serialization with its key. Trusted:
    /// the model's claim that only host output, process exit, resize, surface
    /// swaps and text-changing binding actions change the serialized screen,
    /// and that every change but a binding action changes the screen state.
    @Test("Exhaustive bounded check: the first patch's operations under the exact oracle")
    func boundedModelCheck() throws {
        var states = 0
        try exploreCache(ScreenModel(), RelayActiveScreenCache(), ops: ScreenModel.originalOps, depth: 6, path: [],
                         states: &states)
        print("active-screen cache bounded check: depth 6, \(ScreenModel.originalOps.count) ops, \(states) states")
        #expect(states == statesExplored(ops: 12, depth: 6))
    }

    /// Bound: every sequence of up to 4 operations over 33: the quiescent
    /// operations, a plain read, a read whose dump fails, and each of four
    /// mutations at each of six points inside a read.
    @Test("Exhaustive bounded check: every mutation at every point inside a read")
    func boundedInterleavingCheck() throws {
        var states = 0
        try exploreCache(ScreenModel(), RelayActiveScreenCache(), ops: ScreenModel.allOps, depth: 4, path: [],
                         states: &states)
        print("active-screen cache interleaving check: depth 4, \(ScreenModel.allOps.count) ops, \(states) states")
        #expect(ScreenModel.allOps.count == 33)
        #expect(states == statesExplored(ops: 33, depth: 4))
    }

    @Test("An unchanged screen is dumped once and then answered from memory")
    func unchangedScreenHits() {
        var cache = RelayActiveScreenCache()
        let model = ScreenModel()
        var dumps = 0
        for _ in 0..<10 {
            let result = cache.read(sample: { RelayActiveScreenCache.sample(state: model.state, rows: model.rows) },
                                    dump: { dumps += 1; return model.dump() })
            #expect(result == model.quiescent)
        }
        #expect(dumps == 1)
        #expect(cache.dumps == 1)
    }

    @Test("No surface means no dump and no entry")
    func detachedReadsNothing() {
        var cache = RelayActiveScreenCache()
        var model = ScreenModel()
        _ = cache.read(sample: { RelayActiveScreenCache.sample(state: model.state, rows: model.rows) }, dump: model.dump)
        model.attached = false
        var dumped = false
        #expect(cache.read(sample: { RelayActiveScreenCache.sample(state: model.state, rows: model.rows) },
                           dump: { dumped = true; return "x" }) == .noSurface)
        #expect(!dumped)
        #expect(cache.entry == nil)
    }

    @Test("A failed dump with a surface attached is unstable, never a missing screen")
    func failedDumpIsUnstable() {
        var cache = RelayActiveScreenCache()
        let model = ScreenModel()
        #expect(cache.read(sample: { RelayActiveScreenCache.sample(state: model.state, rows: model.rows) },
                           dump: { nil }) == .unstable)
        #expect(cache.entry == nil)
    }
}

// MARK: - Native contract: the in-flight flag and mutation count

private final class BlockingWrite: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func waitEntered() { entered.wait() }
}

@Suite("In-memory screen state")
struct RelayInMemoryScreenStateTests {
    @Test("A mutation is in flight while the surface write runs and counted after it", .timeLimit(.minutes(1)))
    func inFlightCoversTheWrite() async throws {
        let gate = BlockingWrite()
        let access = InMemoryTerminalSurfaceAccess(write: { _, _ in
            gate.entered.signal()
            gate.release.wait()
        }, processExit: { _, _, _ in })
        // The fake write never dereferences the surface.
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 0x1000))
        let initial = try #require(access.screenState)
        #expect(initial.mutations == 0 && !initial.mutationInFlight)
        access.enqueueWrite(Data("x".utf8))
        await Task.detached { gate.waitEntered() }.value
        let during = try #require(access.screenState)
        #expect(during.mutationInFlight)
        #expect(during.mutations == 0)
        gate.release.signal()
        await Task.detached { access.waitForPendingOutput() }.value
        let after = try #require(access.screenState)
        #expect(!after.mutationInFlight)
        #expect(after.mutations == 1)
        #expect(after.surfaceGeneration == initial.surfaceGeneration)
        access.setSurface(nil)
        #expect(access.screenState == nil)
    }

    @Test("A process exit report counts as a screen mutation", .timeLimit(.minutes(1)))
    func processExitCounts() async throws {
        let access = InMemoryTerminalSurfaceAccess(write: { _, _ in }, processExit: { _, _, _ in })
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 0x1000))
        #expect(access.enqueueProcessExit(exitCode: 0, runtimeMilliseconds: 1))
        await Task.detached { access.waitForPendingOutput() }.value
        let state = try #require(access.screenState)
        #expect(state.mutations == 1 && !state.mutationInFlight)
        access.setSurface(nil)
    }
}

// MARK: - Real libghostty: an attribute-only change is never served stale

@MainActor
@Test("A faint prediction that becomes typed text with the same characters is re-read", .timeLimit(.minutes(5)))
func activeScreenCacheSeesAttributeOnlyChange() async throws {
    _ = NSApplication.shared
    let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    let controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("relay.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 440))
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), context: .window)
    view.pasteboard = pasteboard
    view.controller = controller
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.contentView = nil }
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.fitToSize()
    await Task.yield()
    view.fitToSize()
    let metrics = try #require(view.currentGridMetrics())
    var resizes = session.nativeResizeEvents().makeAsyncIterator()
    while let applied = await resizes.next(),
          applied.columns != metrics.columns || applied.rows != metrics.rows {}
    let predicted = "\u{1b}[2J\u{1b}[Howned transcript\r\n❯ \u{1b}[2mCheck this change\u{1b}[22m\r\n" +
        "────────────────\r\n⏵⏵ bypass permissions on · update installed\r\n"
    let typed = predicted.replacingOccurrences(of: "\u{1b}[2mCheck this change\u{1b}[22m", with: "Check this change")
    var cache = RelayActiveScreenCache()
    func read() -> String? {
        cache.read(sample: { session.activeScreenSample() }, dump: { session.readActiveScreenVT() }).screen
    }

    session.receive(predicted)
    await Task.detached { session.waitForPendingOutput() }.value
    let first = try #require(read())
    #expect(RelayAgentMaintenancePrompt.isEmpty(first, provider: "claude"))
    for _ in 0..<20 { #expect(read() == first) }
    #expect(cache.dumps == 1, "unchanged reads must stay in memory")

    let rowsBefore = session.readViewportRows()
    session.receive(typed)
    await Task.detached { session.waitForPendingOutput() }.value
    #expect(session.readViewportRows() == rowsBefore, "the change must be attribute-only")
    let second = try #require(read())
    #expect(!RelayAgentMaintenancePrompt.isEmpty(second, provider: "claude"))
    #expect(second == session.readActiveScreenVT())
    #expect(cache.dumps == 2)

    // A binding action changes the screen without host output; the
    // in-memory rows catch it.
    let mutations = session.screenState?.mutations
    #expect(view.performBindingAction("clear_screen"))
    await Task.detached { session.waitForPendingOutput() }.value
    #expect(session.screenState?.mutations == mutations, "clear_screen is not counted output")
    #expect(session.readViewportRows() != rowsBefore)
    let cleared = read()
    #expect(cleared == session.readActiveScreenVT())
    #expect(cleared != second)
}

// MARK: - Coordinator: the Settings summary matches the full snapshot

@MainActor @Test("Host summaries match snapshot counts without building pane facts")
func hostSummariesMatchSnapshot() throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePaneID.flatMap { workspace.panes[$0] })
    pane.connected()
    let coordinator = RelayPaneHealthCoordinator(url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json"))
    let now = Date()
    coordinator.heartbeat(workspace, now: now)
    func matches(_ at: Date) throws -> RelayPaneHealthCoordinator.HostSummary {
        let full = try #require(coordinator.snapshot(now: at).hosts.first)
        let summary = try #require(coordinator.hostSummaries(now: at).first)
        #expect(coordinator.hostSummaries(now: at).count == coordinator.snapshot(now: at).hosts.count)
        #expect(summary == .init(host: full.host, name: full.name, state: full.state, panes: full.panes,
            freshObservations: full.freshObservations, endedPanes: full.endedPanes))
        return summary
    }
    #expect(try matches(now).freshObservations == 0)
    coordinator.observe(pane, proof: RelayAgentMaintenanceProbe(version: 1, unavailable: "Owned unavailable proof"), now: now)
    #expect(try matches(now).freshObservations == 1)
    #expect(try matches(now.addingTimeInterval(301)).freshObservations == 0)
    pane.exited(exitCode: 0)
    #expect(try matches(now).endedPanes == 1)
}

// MARK: - Settings feed: exhaustive bounded check of window visibility

private func summary(_ value: Int) -> RelayPaneHealthCoordinator.HostSummary {
    .init(host: "local", name: "This Mac", state: "s\(value)", panes: value, freshObservations: 0, endedPanes: 0)
}

private enum WindowOp: CaseIterable {
    /// close: willClose, the hide (notified or not), then the next-turn finish.
    case orderFront, orderOut, close, closeHideSilently, miniaturize, deminiaturize, occlude, unocclude, detach, attach
    case bump, tick
    /// Window changes whose notification never arrives.
    case orderOutSilently, occludeSilently
    /// close() then orderFront in one main-queue turn, both unnotified,
    /// before RelayWindowVisibilityView's next-turn closeFinished.
    case closeAndReopenInOneTurn
    /// A stale "showing" report while the window is hidden.
    case staleShowReport
}

@MainActor private final class FeedHarness {
    var value = 0
    var callsWhileHidden = 0
    var specVisible = false
    let changes = PassthroughSubject<Void, Never>()
    let ticks = PassthroughSubject<Void, Never>()
    var feed: RelayPaneHealthSettingsFeed!
    var tracker = RelayWindowVisibilityTracker()
    var attached = true, isVisible = false, miniaturized = false, occlusionVisible = true, closingSpec = false
    var silentPending = false
    var closeViolation: String?

    init() {
        feed = RelayPaneHealthSettingsFeed(initial: [], source: { [unowned self] in
            if !self.specVisible { self.callsWhileHidden += 1 }
            return [summary(self.value)]
        }, changes: { [changes] in changes.eraseToAnyPublisher() }, ticks: { [ticks] in ticks.eraseToAnyPublisher() })
        feed.showingCheck = { [unowned self] in self.evaluate() }
    }

    /// What RelayWindowVisibilityView.evaluate does: read the window, report.
    @discardableResult func evaluate() -> Bool {
        let showing = tracker.showing(attached: attached, isVisible: isVisible, isMiniaturized: miniaturized,
                                      occlusionVisible: occlusionVisible)
        feed.setVisible(showing)
        return showing
    }

    private func send(_ subject: PassthroughSubject<Void, Never>) {
        specVisible = attached && isVisible && !miniaturized && occlusionVisible && !closingSpec
        subject.send()
    }

    func apply(_ op: WindowOp) {
        switch op {
        case .orderFront: isVisible = true
        case .orderOut: isVisible = false
        case .close, .closeHideSilently:
            tracker.willClose()
            closingSpec = true
            evaluate()
            if feed.visible || feed.isRefreshing { closeViolation = "armed during close" }
            isVisible = false
            if op == .close { evaluate() }
            tracker.closeFinished()
            closingSpec = false
        case .miniaturize: miniaturized = true
        case .deminiaturize: miniaturized = false
        case .occlude: occlusionVisible = false
        case .unocclude: occlusionVisible = true
        case .detach: attached = false; closingSpec = false
        case .attach: attached = true
        case .bump: value += 1; send(changes)
        case .tick: value += 1; send(ticks)
        case .orderOutSilently: isVisible = false
        case .staleShowReport:
            specVisible = attached && isVisible && !miniaturized && occlusionVisible && !closingSpec
            feed.setVisible(true)
        case .closeAndReopenInOneTurn:
            tracker.willClose()
            closingSpec = true
            evaluate()
            if feed.visible || feed.isRefreshing { closeViolation = "armed during close" }
            isVisible = true
            tracker.closeFinished()
            closingSpec = false
        case .occludeSilently: occlusionVisible = false
        }
        specVisible = attached && isVisible && !miniaturized && occlusionVisible && !closingSpec
        switch op {
        case .bump, .tick:
            silentPending = false
        case .staleShowReport:
            // Carries no information; a pending silent hide stays pending.
            break
        case .orderOutSilently, .occludeSilently:
            silentPending = true
        default:
            silentPending = false
            evaluate()
        }
    }

    /// Safety: no refresh while hidden; subscriptions live exactly while shown.
    /// Freshness: while shown, the rows equal the current source.
    func violation() -> String? {
        if let closeViolation { return closeViolation }
        // A missed notification may leave the feed armed until its next
        // change or tick; it must never refresh in that state.
        if !silentPending, feed.visible != specVisible { return "feed visible \(feed.visible), spec \(specVisible)" }
        if !silentPending, feed.isRefreshing != specVisible {
            return "subscriptions live \(feed.isRefreshing) while visible \(specVisible)"
        }
        if callsWhileHidden > 0 { return "refreshed while hidden" }
        if specVisible, feed.value != [summary(value)] { return "stale rows while visible" }
        return nil
    }
}

@MainActor
@Suite("Settings pane-health feed")
struct RelayPaneHealthSettingsFeedTests {
    /// Bound: every sequence of up to 5 operations over 16 window and data
    /// events (two hide the window without any notification, one closes and
    /// reopens it within one main-queue turn, one reports showing stale), replayed against the real tracker and feed (Combine subjects
    /// stand in for the coordinator revision and the timer).
    /// The harness drives real main-actor types, so the check runs on the
    /// main actor. It yields every 256 sequences: run synchronously, it held
    /// the main thread for 53 s in the parallel suite and starved every other
    /// main-actor test. Same sequences, same steps, same properties.
    @Test("Exhaustive bounded check: refresh only while the window shows")
    func boundedVisibilityCheck() async throws {
        let ops = WindowOp.allCases
        var sequences = 0, steps = 0
        func run(_ sequence: [WindowOp]) throws {
            let harness = FeedHarness()
            for (index, op) in sequence.enumerated() {
                harness.apply(op)
                steps += 1
                if let violation = harness.violation() {
                    throw CacheCheckFailure(description: "\(violation) after \(sequence.prefix(index + 1))")
                }
            }
            sequences += 1
        }
        // Every sequence of length 0...5, each exactly once: index i of
        // length n spells its ops in base ops.count.
        for length in 0...5 {
            let count = Int(pow(Double(ops.count), Double(length)))
            for index in 0..<count {
                var sequence: [WindowOp] = [], rest = index
                for _ in 0..<length {
                    sequence.append(ops[rest % ops.count])
                    rest /= ops.count
                }
                try run(sequence)
                if sequences % 256 == 0 { await Task.yield() }
            }
        }
        print("settings feed bounded check: depth 5, \(ops.count) ops, \(sequences) sequences, \(steps) steps")
        #expect(sequences == (0...5).reduce(0) { $0 + Int(pow(16.0, Double($1))) })
        #expect(steps == (0...5).reduce(0) { $0 + $1 * Int(pow(16.0, Double($1))) })
    }

    @Test("A Settings window reused after close shows again")
    func reopenAfterClose() {
        var tracker = RelayWindowVisibilityTracker()
        func show(_ visible: Bool, _ occluded: Bool = false) -> Bool {
            tracker.showing(attached: true, isVisible: visible, isMiniaturized: false, occlusionVisible: !occluded)
        }
        let opened = show(true)
        tracker.willClose()
        let closing = show(true)
        let closed = show(false, true)
        let reopened = show(true)
        #expect(opened && !closing && !closed && reopened)
    }
}

// MARK: - AppKit: orderOut and close stop the feed

@MainActor
@Test("orderOut and close stop the feed without refreshing a hidden window", .timeLimit(.minutes(1)))
func windowVisibilityReaderStopsOnOrderOutAndClose() async throws {
    _ = NSApplication.shared
    let changes = PassthroughSubject<Void, Never>()
    let ticks = PassthroughSubject<Void, Never>()
    var calls = 0
    let feed = RelayPaneHealthSettingsFeed(initial: [], source: { calls += 1; return [] },
        changes: { changes.eraseToAnyPublisher() }, ticks: { ticks.eraseToAnyPublisher() })
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let reader = RelayWindowVisibilityView(frame: .zero)
    // Trusted fake: a test process runs no event loop, so the window server
    // reports every window occluded (rawValue 8192, without .visible).
    reader.occlusionVisible = { _ in true }
    reader.drive(feed)
    window.contentView = NSView(frame: window.contentLayoutRect)
    window.contentView?.addSubview(reader)
    defer { window.contentView = nil }
    func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    #expect(!feed.visible, "a window that was never ordered in is hidden")

    // A test process runs no AppKit event loop, so occlusion and isVisible
    // notifications may not arrive; evaluate() stands in for didBecomeKey.
    window.orderFront(nil)
    await settle()
    #expect(reader.evaluate(), "visible \(window.isVisible) mini \(window.isMiniaturized) occlusion \(window.occlusionState.rawValue) attached \(reader.window != nil) closing \(reader.tracker.closing) last \(String(describing: reader.lastReported)) feedVisible \(feed.visible)")
    #expect(feed.isRefreshing)
    let shown = calls
    #expect(shown == 1)
    changes.send()
    #expect(calls == shown + 1)

    window.orderOut(nil)
    await settle()
    let hidden = calls
    changes.send(); ticks.send(); changes.send()
    #expect(calls == hidden, "no refresh after orderOut")
    #expect(!feed.isRefreshing, "orderOut stops the feed by its next change at the latest")

    window.orderFront(nil)
    await settle()
    #expect(reader.evaluate())
    #expect(feed.isRefreshing)
    window.close()
    #expect(!feed.visible, "willClose stops the feed at once")
    #expect(!feed.isRefreshing)
    let closed = calls
    changes.send(); ticks.send()
    #expect(calls == closed)
}

// MARK: - Coordinator: the Performance panel overview matches the full snapshot

@MainActor @Test("Host overviews match snapshot hosts and panes without building pane facts")
func hostOverviewsMatchSnapshot() throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePaneID.flatMap { workspace.panes[$0] })
    pane.connected()
    let coordinator = RelayPaneHealthCoordinator(url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json"))
    let now = Date()
    coordinator.heartbeat(workspace, now: now)
    func matches(_ at: Date) throws -> RelayPaneHealthCoordinator.HostOverview {
        let hosts = coordinator.snapshot(now: at).hosts
        let overviews = coordinator.hostOverviews(now: at)
        #expect(overviews.count == hosts.count)
        let full = try #require(hosts.first)
        let overview = try #require(overviews.first)
        #expect(overview.summary == .init(host: full.host, name: full.name, state: full.state, panes: full.panes,
            freshObservations: full.freshObservations, endedPanes: full.endedPanes))
        #expect(overview.controller == full.controller)
        #expect(overview.checkRunning == coordinator.checkIsRunning(host: full.host))
        #expect(overview.livePanes == full.livePanes.map {
            .init(paneID: $0.paneID, name: $0.name, observationState: $0.observationState, worker: $0.worker, context: $0.context)
        })
        return overview
    }
    #expect(try matches(now).livePanes.first?.observationState == "not_checked")
    var proof = RelayAgentMaintenanceProbe(version: 1, unavailable: "Owned unavailable proof")
    proof.worker = RelayPaneWorkerObservation(workerPid: 10, workerStart: 11, upgradeMode: "restart_required",
        updateState: "update_required", runningSha256: nil, installedSha256: nil, unavailable: nil)
    proof.context = RelayPaneContextObservation(supported: true, enabled: false, state: "human_takeover",
        generation: 1, lifecycle: nil, refreshCapability: nil, unavailable: nil)
    coordinator.observe(pane, proof: proof, now: now)
    let fresh = try matches(now)
    #expect(fresh.livePanes.first?.worker == proof.worker)
    #expect(fresh.livePanes.first?.context == proof.context)
    let stale = try matches(now.addingTimeInterval(301))
    #expect(stale.livePanes.first?.observationState == "stale")
    #expect(stale.livePanes.first?.worker == nil && stale.livePanes.first?.context == nil)
    pane.exited(exitCode: 0)
    #expect(try matches(now).livePanes.first?.observationState == "exited")
}

@MainActor @Test("A host with a pending daemon check shows its check running in the overview")
func hostOverviewShowsRunningCheck() throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePaneID.flatMap { workspace.panes[$0] })
    pane.connected()
    let key = pane.profile.connectionKey
    // A journal persisted while a daemon check was pending. heartbeat() does
    // not sync controllers under tests, so nothing reaches relayd.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("journal.json")
    let journal: [String: Any] = [
        "hosts": [key: ["name": "This Mac", "state": "Checking", "modelOperations": [String](),
                        "observedPaneCount": 0, "checkedBatches": [String: Any](),
                        "daemonCheckOperationID": "owned-check-operation"]],
        "tools": [String: Any](),
    ]
    try JSONSerialization.data(withJSONObject: journal).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let coordinator = RelayPaneHealthCoordinator(url: url)
    coordinator.heartbeat(workspace)
    #expect(coordinator.checkIsRunning(host: key), "the seeded journal must load")
    let overview = try #require(coordinator.hostOverviews().first)
    #expect(overview.summary.host == key)
    #expect(overview.checkRunning)
    #expect(overview.summary.state == "Checking")
}

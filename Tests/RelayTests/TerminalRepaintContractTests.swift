import AppKit
import Foundation
@testable import GhosttyTerminal
import Testing
@testable import Relay

// The repaint contract (docs/TERMINAL-REPAINT-CONTRACT.md): output repaints
// the rows it damaged; size, scale, scroll, replay, visibility and attach
// repaint the whole viewport; a settle heals a stale row after output.

@Suite("Terminal repaint policy")
struct TerminalRepaintPolicyTests {
    @Test("A full rebuild runs only when the pane can draw and no IME composition is open")
    func actionMatrix() {
        let p = TerminalRepaintPolicy.self
        #expect(p.action(canRender: true, composing: false, now: 10, lastApplied: nil) == .apply)
        #expect(p.action(canRender: false, composing: false, now: 10, lastApplied: nil) == .owe)
        #expect(p.action(canRender: true, composing: true, now: 10, lastApplied: nil) == .owe)
        #expect(p.action(canRender: true, composing: false, now: 10, lastApplied: 10 - p.coalesceInterval / 2) == .coalesce)
        #expect(p.action(canRender: true, composing: false, now: 10, lastApplied: 10 - 2 * p.coalesceInterval) == .apply)
    }

    @Test("Only size and scale changes get a trailing repaint")
    func trailing() {
        let trailing = TerminalRepaintReason.allCases.filter(TerminalRepaintPolicy.needsTrailingRepaint)
        #expect(Set(trailing) == [.size, .scale])
    }

    @Test("Damage inside the echo window never schedules a settle; later damage does")
    func echo() {
        let p = TerminalRepaintPolicy.self
        #expect(!p.isEcho(now: 5, lastApplied: nil))
        #expect(p.isEcho(now: 5, lastApplied: 5))
        #expect(p.isEcho(now: 5 + p.echoWindow * 0.9, lastApplied: 5))
        #expect(!p.isEcho(now: 5 + p.echoWindow, lastApplied: 5))
        #expect(!p.isEcho(now: 4, lastApplied: 5), "a clock earlier than the rebuild is not its echo")
    }

    @Test("Continuous damage is healed at least every maximumIntervalUnderDamage")
    func overdue() {
        let p = TerminalRepaintPolicy.self
        let max = p.maximumIntervalUnderDamage
        #expect(!p.settleIsOverdue(now: 100, lastApplied: nil, damageSince: 100))
        #expect(p.settleIsOverdue(now: 100 + max, lastApplied: nil, damageSince: 100))
        // A recent rebuild resets the interval.
        #expect(!p.settleIsOverdue(now: 100 + max, lastApplied: 100 + max - 0.5, damageSince: 100))
        // An old rebuild does not shorten it below the damage stretch.
        #expect(!p.settleIsOverdue(now: 100 + max - 0.1, lastApplied: 10, damageSince: 100))
    }
}

@MainActor
private final class RepaintTerminal {
    let view: AppTerminalView
    let window: NSWindow
    let session: InMemoryTerminalSession
    let controller: TerminalController
    private(set) var applied: [TerminalRepaintReason] = []
    let writes = WriteCounter()

    final class WriteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        func add(_ n: Int) { lock.lock(); bytes += n; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    init() async throws {
        _ = NSApplication.shared
        let counter = writes
        session = InMemoryTerminalSession(write: { counter.add($0.count) }, resize: { _ in })
        controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
        view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), context: .window)
        view.controller = controller
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.fitToSize()
        let deadline = ContinuousClock.now + .seconds(5)
        while session.currentSurface == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.currentSurface != nil)
    }

    func observe() {
        view.core.fullRebuildOverride = { [weak self] in self?.applied.append($0) }
    }

    func clear() { applied.removeAll() }

    /// Waits until attach-time rebuilds, their settles and echoes have passed,
    /// so a test starts from a quiet pane.
    func waitQuiet() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let last = view.core.repaintStatistics.lastAppliedUptime ?? 0
            let age = ProcessInfo.processInfo.systemUptime - last
            if age > TerminalRepaintPolicy.echoWindow + 0.05, !view.core.testHooks_settleScheduled,
               view.core.testHooks_fullRepaintOwed == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        applied.removeAll()
    }

    func tearDown() {
        view.core.fullRebuildOverride = nil
        view.core.freeSurface()
    }
}

@MainActor @Suite("Terminal repaint contract on a real surface", .serialized)
struct TerminalRepaintContractTests {
    @Test("The full-rebuild lever sends nothing to the session and keeps the screen and selection", .timeLimit(.minutes(1)))
    func leverHasNoSideEffects() async throws {
        let t = try await RepaintTerminal()
        t.session.receive(Data("repaint-fixture line one\r\nline two\r\n".utf8))
        t.view.synchronizeAndRedraw()
        try await Task.sleep(for: .milliseconds(100))
        let before = try #require(t.view.readViewportText())
        #expect(before.contains("repaint-fixture line one"))
        #expect(t.view.surface?.performBindingAction("select_all") == true)
        #expect(t.view.surface?.hasSelection() == true)
        let written = t.writes.count
        let surface = try #require(t.view.surface)
        for _ in 0..<5 { surface.markFullyDirty() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(t.writes.count == written, "an empty preedit must never reach the program as input")
        #expect(t.view.readViewportText() == before)
        #expect(t.view.surface?.hasSelection() == true, "with no composition open the selection survives")
        t.tearDown()
    }

    @Test("A hidden pane owes the rebuild and gets it when shown, after occlusion is lifted")
    func hiddenPaneOwesAndRedeems() async throws {
        let t = try await RepaintTerminal()
        t.observe()
        try await t.waitQuiet()
        t.view.setSurfaceVisible(false)
        t.view.core.requestFullRepaint(.scroll)
        #expect(t.applied.isEmpty)
        #expect(t.view.core.testHooks_fullRepaintOwed == .scroll)
        t.view.setSurfaceVisible(true)
        #expect(t.applied == [.visibility])
        #expect(t.view.core.testHooks_fullRepaintOwed == nil)
        t.tearDown()
    }

    @Test("An open IME composition defers the rebuild to the first frame after it closes")
    func compositionDefers() async throws {
        let t = try await RepaintTerminal()
        t.observe()
        var composing = true
        try await t.waitQuiet()
        t.view.core.isComposing = { composing }
        t.view.core.requestFullRepaint(.size)
        #expect(t.applied.isEmpty)
        #expect(t.view.core.repaintStatistics.skippedWhileComposing >= 1)
        // Owed, under the first reason that was owed (a settle may already be).
        #expect(t.view.core.testHooks_fullRepaintOwed != nil)
        composing = false
        // The next frame redeems it: the burst's display-link frames, or a
        // same-state activation, which renders one frame immediately.
        try await Task.sleep(for: .milliseconds(100))
        if t.applied.isEmpty { t.view.core.setApplicationActive(true) }
        #expect(!t.applied.isEmpty, "the owed rebuild runs once the composition closes")
        #expect(t.view.core.testHooks_fullRepaintOwed == nil)
        t.tearDown()
    }

    @Test("Requests within one frame share a rebuild and the rest is redeemed by the next frame")
    func coalescing() async throws {
        let t = try await RepaintTerminal()
        t.observe()
        try await t.waitQuiet()
        t.view.core.requestFullRepaint(.scroll)
        t.view.core.requestFullRepaint(.scroll)
        #expect(t.applied == [.scroll])
        #expect(t.view.core.testHooks_fullRepaintOwed == .scroll)
        try await Task.sleep(for: .milliseconds(100))
        if t.applied.count == 1 { t.view.core.setApplicationActive(true) }
        #expect(t.applied == [.scroll, .scroll])
        t.tearDown()
    }

    @Test("Damage schedules one settle after quiet, and the settle's echo does not schedule another")
    func settleDoesNotFeedItself() async throws {
        let t = try await RepaintTerminal()
        t.observe()
        try await t.waitQuiet()
        t.view.core.testHooks_noteDamage()
        #expect(t.view.core.testHooks_settleScheduled)
        try await Task.sleep(for: .seconds(TerminalRepaintPolicy.settleDelay + 0.25))
        #expect(t.applied.contains(.settle))
        let settles = t.applied.filter { $0 == .settle }.count
        #expect(settles == 1)
        t.view.core.testHooks_noteDamage()   // the settle's own render request
        #expect(!t.view.core.testHooks_settleScheduled)
        try await Task.sleep(for: .seconds(TerminalRepaintPolicy.settleDelay + 0.25))
        #expect(t.applied.filter { $0 == .settle }.count == 1, "no settle loop on an idle pane")
        t.tearDown()
    }

    @Test("Size and scroll transitions on the view request a full repaint; a size change repaints again after the throttle")
    func viewTransitions() async throws {
        let t = try await RepaintTerminal()
        t.observe()
        try await t.waitQuiet()
        t.view.setFrameSize(NSSize(width: 640, height: 400))
        #expect(t.applied.first == .size)
        // The trailing repaint lands after the throttle; under load the main
        // actor may run it late, so wait for it rather than for a fixed time.
        let deadline = ContinuousClock.now + .seconds(3)
        while t.applied.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(t.applied.count >= 2, "the size change is repainted again after the throttle")
        #expect(t.applied.allSatisfy { $0 == .size || $0 == .settle })
        let sizeRequests = t.view.core.repaintStatistics.requested[.size] ?? 0
        t.view.setFrameSize(NSSize(width: 640, height: 400))   // unchanged: no full repaint
        #expect((t.view.core.repaintStatistics.requested[.size] ?? 0) == sizeRequests)
        _ = t.view.scrollToRow(0)
        #expect((t.view.core.repaintStatistics.requested[.scroll] ?? 0) >= 1)
        t.tearDown()
    }
}

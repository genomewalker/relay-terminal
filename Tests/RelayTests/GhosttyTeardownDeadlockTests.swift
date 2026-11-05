import AppKit
import Foundation
@testable import GhosttyTerminal
import Testing
@testable import Relay

// MARK: - Repro: a real surface torn down or replaced during a blocked title write

/// Kills the process with a clear message if the main thread has not passed a
/// checkpoint in time. A deadlocked main thread cannot report a test failure,
/// so without this a regression would hang the whole suite.
private final class DeadlockWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false

    init(_ label: String, seconds: Double) {
        Thread.detachNewThread { [self] in
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                lock.lock(); let done = passed; lock.unlock()
                if done { return }
            }
            FileHandle.standardError.write(Data("DEADLOCK: \(label) did not return within \(seconds) s; the main thread is blocked\n".utf8))
            _exit(86)
        }
    }

    func pass() { lock.lock(); passed = true; lock.unlock() }
}

@MainActor
private final class OffscreenTerminal {
    let view: AppTerminalView
    let window: NSWindow

    /// A real Ghostty surface on `session`. Surfaces are built only for a view
    /// in a window; this borderless window is never ordered on screen.
    init(session: InMemoryTerminalSession, controller: TerminalController) {
        view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), context: .window)
        view.controller = controller
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.fitToSize()
    }
}

@MainActor @Suite("Ghostty teardown during a blocked title write", .serialized)
struct GhosttyTeardownDeadlockReproTests {
    static let titles = (0..<4096).map { "\u{001B}]2;teardown-fixture-\($0)\u{0007}" }.joined()

    /// Holds the main thread (no run loop, so no app tick drains the mailbox)
    /// until a write on the session has stayed inside Ghostty for 500 ms: the
    /// title mailbox is full and the drain is blocked on it.
    static func holdMainUntilDrainIsBlocked(_ session: InMemoryTerminalSession) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        var activeSince: Date?
        while Date() < deadline {
            if session.activeSurfaceOperationCountForTesting > 0 {
                activeSince = activeSince ?? Date()
                if Date().timeIntervalSince(activeSince!) >= 0.5 { return true }
            } else {
                activeSince = nil
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    static func waitForSurface(_ session: InMemoryTerminalSession) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while session.currentSurface == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.currentSurface != nil, "the offscreen view built a surface")
    }

    /// Lets the main thread tick the app until the retired surface is freed.
    static func waitForRelease(_ session: InMemoryTerminalSession, _ controller: TerminalController,
                               bridges expected: Int) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline,
              session.activeSurfaceOperationCountForTesting > 0
                || session.pendingSurfaceRetirementCountForTesting > 0
                || controller.retainedBridgeCount != expected {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits until `bridge`'s surface is freed: no operation, no retirement
    /// pending, and the controller no longer retains that exact bridge.
    static func waitForRelease(_ session: InMemoryTerminalSession, _ controller: TerminalController,
                               dropping bridge: TerminalCallbackBridge) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline,
              session.activeSurfaceOperationCountForTesting > 0
                || session.pendingSurfaceRetirementCountForTesting > 0
                || controller.retainedBridges.contains(where: { $0 === bridge }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The controller retains exactly the bridges of the surfaces still alive.
    /// (A view still in its window rebuilds a surface, with a new bridge, after
    /// a teardown; only the retired generation's bridge may be dropped.)
    static func retainsExactlyLiveBridges(_ controller: TerminalController, _ cores: [TerminalSurfaceCoordinator]) -> Bool {
        let retained = Set(controller.retainedBridges.map(ObjectIdentifier.init))
        let live = Set(cores.filter { $0.surface != nil }.map { ObjectIdentifier($0.bridgeForTesting) })
        return retained == live && controller.retainedBridges.count == live.count
    }

    @Test("Teardown while the drain is blocked on the title mailbox returns at once and frees the surface after the write",
          .timeLimit(.minutes(2)))
    func teardownDuringBlockedTitleWrite() async throws {
        _ = NSApplication.shared
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
        let terminal: OffscreenTerminal? = OffscreenTerminal(session: session, controller: controller)
        try await Self.waitForSurface(session)
        let bridges = controller.retainedBridgeCount
        #expect(bridges >= 1)
        let bridgeA = try #require(terminal?.view.core.bridgeForTesting)

        // From here to the teardown the main thread never returns to its run loop.
        session.receive(Data((Self.titles + "\r\nAFTER_TITLES").utf8))
        try #require(Self.holdMainUntilDrainIsBlocked(session), "precondition: the title write is blocked on the mailbox")
        let watchdog = DeadlockWatchdog("teardown of a view whose surface has a blocked write", seconds: 20)
        let started = Date()
        // The same teardown the view's deallocation runs (TerminalSurfaceCoordinator
        // .tearDownSurface, as in the sampled hang), called directly so it happens
        // now, in this main-thread turn, rather than at a later autorelease pop.
        terminal?.view.core.freeSurface()
        watchdog.pass()
        let teardown = Date().timeIntervalSince(started)
        #expect(teardown < 1, "teardown did not wait for the blocked write (\(teardown) s)")
        #expect(session.currentSurface == nil)
        #expect(session.pendingSurfaceRetirementCountForTesting == 1, "the free is deferred while the write runs")
        #expect(controller.retainedBridges.contains { $0 === bridgeA }, "the retired surface's own bridge outlives the surface")
        #expect(bridgeA.rawSurface != nil, "until it is freed, the retired surface's callbacks route to it")

        await Self.waitForRelease(session, controller, dropping: bridgeA)
        #expect(session.activeSurfaceOperationCountForTesting == 0)
        #expect(session.pendingSurfaceRetirementCountForTesting == 0, "the surface was freed once its write returned")
        #expect(!controller.retainedBridges.contains { $0 === bridgeA }, "the retired surface's bridge was dropped after the free")
        #expect(bridgeA.rawSurface == nil)
        #expect(Self.retainsExactlyLiveBridges(controller, [terminal!.view.core]),
                "no other bridge was dropped: any surface the view rebuilt keeps its own")
        withExtendedLifetime(terminal) {}
    }

    @Test("Replacing the surface while the drain is blocked does not wait; the old surface is freed after its write",
          .timeLimit(.minutes(2)))
    func replaceDuringBlockedTitleWrite() async throws {
        _ = NSApplication.shared
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
        let first: OffscreenTerminal? = OffscreenTerminal(session: session, controller: controller)
        try await Self.waitForSurface(session)
        let old = session.currentSurface
        let bridges = controller.retainedBridgeCount
        let bridgeA = try #require(first?.view.core.bridgeForTesting)

        session.receive(Data(Self.titles.utf8))
        try #require(Self.holdMainUntilDrainIsBlocked(session), "precondition: the title write is blocked on the mailbox")
        let watchdog = DeadlockWatchdog("setSurface for a second view while the first surface has a blocked write", seconds: 20)
        let started = Date()
        let second = OffscreenTerminal(session: session, controller: controller)
        watchdog.pass()
        #expect(Date().timeIntervalSince(started) < 1, "setSurface did not wait for the blocked write")
        #expect(session.currentSurface != nil && session.currentSurface != old, "the second view owns the session")

        // The first view goes away while its write may still be blocked.
        let teardownWatchdog = DeadlockWatchdog("teardown of the replaced view", seconds: 20)
        first?.view.core.freeSurface()
        teardownWatchdog.pass()
        await Self.waitForRelease(session, controller, dropping: bridgeA)
        #expect(session.activeSurfaceOperationCountForTesting == 0)
        #expect(session.pendingSurfaceRetirementCountForTesting == 0, "the replaced surface was freed after its write")
        #expect(!controller.retainedBridges.contains { $0 === bridgeA }, "the replaced surface's bridge was dropped after its free")
        #expect(controller.retainedBridges.contains { $0 === second.view.core.bridgeForTesting }, "the second view keeps its bridge")
        #expect(Self.retainsExactlyLiveBridges(controller, [first!.view.core, second.view.core]),
                "exactly the live surfaces' bridges are retained (was: a count of \(bridges))")

        // Output after the replacement reaches the new surface.
        session.receive(Data("\r\nAFTER_REPLACE".utf8))
        let deadline = ContinuousClock.now + .seconds(3)
        while !(session.readViewportText() ?? "").contains("AFTER_REPLACE"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect((session.readViewportText() ?? "").contains("AFTER_REPLACE"))
        withExtendedLifetime(second) {}
        withExtendedLifetime(first) {}
    }
}

// MARK: - Same-view rebuild while the old surface's write is blocked (root review 2c160d6b)

/// Root's negative probe (GhosttyRootSameViewRebuildTests, from
/// work/ghostty-teardown-root-review-20261102), kept verbatim apart from the
/// suite's placement, with the callback-identity checks root asked for.
@MainActor @Suite("Root review: same-view rebuild keeps the replacement bridge", .serialized)
struct GhosttyRootSameViewRebuildTests {
    @Test("A deferred retirement must not remove the replacement surface's bridge", .timeLimit(.minutes(2)))
    func sameViewRebuildKeepsBridge() async throws {
        _ = NSApplication.shared
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
        let terminal = OffscreenTerminal(session: session, controller: controller)
        try await GhosttyTeardownDeadlockReproTests.waitForSurface(session)
        let original = session.currentSurface
        let bridges = controller.retainedBridgeCount
        try #require(bridges == 1)
        session.receive(Data(GhosttyTeardownDeadlockReproTests.titles.utf8))
        try #require(GhosttyTeardownDeadlockReproTests.holdMainUntilDrainIsBlocked(session))
        let watchdog = DeadlockWatchdog("same-view rebuild", seconds: 20)
        terminal.view.core.rebuildIfReady()
        watchdog.pass()
        try #require(session.currentSurface != nil && session.currentSurface != original)
        await GhosttyTeardownDeadlockReproTests.waitForRelease(session, controller, bridges: bridges)
        #expect(session.activeSurfaceOperationCountForTesting == 0)
        #expect(session.pendingSurfaceRetirementCountForTesting == 0)
        print("ROOT SAME-VIEW BRIDGES expected=\(bridges) actual=\(controller.retainedBridgeCount)")
        #expect(controller.retainedBridgeCount == bridges,
                "retiring A must preserve the controller's bridge ownership for replacement B")
        terminal.view.core.freeSurface()
        withExtendedLifetime(terminal) {}
    }

    @Test("Same-view rebuild: each generation has its own bridge; A's bridge names only A until A is freed; B accepts output",
          .timeLimit(.minutes(2)))
    func sameViewRebuildCallbackIdentity() async throws {
        _ = NSApplication.shared
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
        let terminal = OffscreenTerminal(session: session, controller: controller)
        try await GhosttyTeardownDeadlockReproTests.waitForSurface(session)
        let core = terminal.view.core
        let surfaceA = try #require(session.currentSurface)
        let bridgeA = core.bridgeForTesting
        #expect(bridgeA.rawSurface == surfaceA)
        session.receive(Data(GhosttyTeardownDeadlockReproTests.titles.utf8))
        try #require(GhosttyTeardownDeadlockReproTests.holdMainUntilDrainIsBlocked(session))
        let watchdog = DeadlockWatchdog("same-view rebuild (identity)", seconds: 20)
        core.rebuildIfReady()
        watchdog.pass()
        let surfaceB = try #require(session.currentSurface)
        try #require(surfaceB != surfaceA)
        let bridgeB = core.bridgeForTesting
        // While A's write is still blocked: two generations, two bridges.
        #expect(bridgeB !== bridgeA, "the replacement surface has its own bridge")
        #expect(bridgeB.rawSurface == surfaceB, "B's callbacks route to B")
        #expect(bridgeA.rawSurface == surfaceA, "A's late callbacks still route to A, which is not yet freed")
        #expect(bridgeA.delegate == nil && bridgeA.onRenderRequest == nil, "the retired generation no longer reaches the view")
        #expect(session.pendingSurfaceRetirementCountForTesting == 1)
        #expect(controller.retainedBridgeCount == 2, "both bridges retained while A is alive")

        await GhosttyTeardownDeadlockReproTests.waitForRelease(session, controller, bridges: 1)
        #expect(session.pendingSurfaceRetirementCountForTesting == 0)
        #expect(bridgeA.rawSurface == nil, "A's bridge is cleared when A is freed")
        #expect(bridgeB.rawSurface == surfaceB, "B's bridge is untouched by A's release")
        #expect(controller.retainedBridgeCount == 1, "exactly B's bridge stays retained")

        session.receive(Data("\r\nAFTER_REBUILD".utf8))
        let deadline = ContinuousClock.now + .seconds(3)
        while !(session.readViewportText() ?? "").contains("AFTER_REBUILD"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect((session.readViewportText() ?? "").contains("AFTER_REBUILD"), "B accepts output after A is freed")
        core.freeSurface()
        withExtendedLifetime(terminal) {}
    }
}

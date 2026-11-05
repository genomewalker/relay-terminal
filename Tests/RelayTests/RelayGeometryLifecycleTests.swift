#if canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import Relay

// F4: before the workspace window has been tagged, visibility is unknown, not
// false. Only an explicit hide or an explicitly occluded workspace suspends.
@Test("Unknown workspace visibility never suspends presentation")
func unknownWorkspaceVisibilityAllowsUpdates() {
    #expect(RelayPresentationVisibilityPolicy.allowsUpdates(
        applicationHidden: false, hasVisibleWorkspace: nil
    ))
    #expect(!RelayPresentationVisibilityPolicy.allowsUpdates(
        applicationHidden: true, hasVisibleWorkspace: nil
    ))
    #expect(!RelayPresentationVisibilityPolicy.allowsUpdates(
        applicationHidden: false, hasVisibleWorkspace: false
    ))
    #expect(RelayPresentationVisibilityPolicy.allowsUpdates(
        applicationHidden: false, hasVisibleWorkspace: true
    ))
}

@MainActor
private func makeRelayPane() -> PaneModel {
    PaneModel(profile: ConnectionProfile(
        name: "relay-test", kind: .ssh, host: "example.invalid", backend: .relay
    ))
}

@MainActor
@Test("Cover changes update a durable terminal surface without replacing its pane")
func terminalSurfaceTracksNetworkCover() {
    let pane = makeRelayPane()
    let visible = TerminalSurface(pane: pane)
    let covered = TerminalSurface(pane: pane, covered: true)
    #expect(visible != covered)
    #expect(visible == TerminalSurface(pane: pane))
    #expect(covered == TerminalSurface(pane: pane, covered: true))
}

@MainActor
private func waitUntil(
    _ timeout: Duration = .milliseconds(500),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// F3: a transaction begun with no following frame change or re-host (zoom of
// a pane whose frame is already final, a caller racing a layout that never
// happens) must not keep the ordered PTY stream buffered indefinitely.
@MainActor
@Test("A geometry transaction with no geometry change ends without a commit")
func geometryTransactionWithoutFrameChangeIsAbandoned() async {
    _ = NSApplication.shared
    let pane = makeRelayPane()
    let runtime = pane.runtime
    _ = runtime.view // headless: never attached to a window, never resized

    runtime.beginExplicitGeometryTransition()
    #expect(runtime.isGeometryTransitionPending)
    #expect(runtime.isBufferingViewportTransition)

    await waitUntil { !runtime.isGeometryTransitionPending && !runtime.isBufferingViewportTransition }
    #expect(!runtime.isGeometryTransitionPending)
    #expect(!runtime.isBufferingViewportTransition)
}

// The bound must not fire for a transaction that a real frame change will
// settle. This is the zoom lifecycle: the model begins the transaction, then
// SwiftUI moves the view's frame, and the view's own settle callback commits.
// The runtime is deliberately not started (no transport), so the view-level
// begin path is inert and only the model-begun transaction is under test.
@MainActor
@Test("A geometry transaction followed by a frame change settles through resize", .timeLimit(.minutes(5)))
func geometryTransactionWithFrameChangeSettles() async throws {
    _ = NSApplication.shared
    let pane = makeRelayPane()
    let runtime = pane.runtime
    let view = runtime.view
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    defer { window.contentView = nil }

    runtime.beginExplicitGeometryTransition() // WorkspaceModel.toggleActivePaneZoom
    view.setFrameSize(NSSize(width: 800, height: 500)) // SwiftUI layout
    #expect(runtime.isGeometryTransitionPending)
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(5))
    // The one-shot bound saw a moved frame and left the transaction open.
    #expect(runtime.isGeometryTransitionPending)

    // MainActor geometry and the ordered I/O queue commit independently.
    // Wait for both completion signals. The settle is a chain of MainActor
    // hops and timers, so a wall-clock deadline here also counts time spent
    // queued behind other MainActor tests; the time limit bounds a hang, and
    // the throwing sleep is what lets that limit end the wait.
    while runtime.isGeometryTransitionPending || runtime.isBufferingViewportTransition {
        await Task.yield()
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!runtime.isGeometryTransitionPending)
    #expect(!runtime.isBufferingViewportTransition)
}
#endif

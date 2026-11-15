import AppKit
import Foundation
import Testing
@testable import Relay

private final class RearmFrameWriter: RelayFrameWriting, @unchecked Sendable {
    func write(type: RelayWireType, payload: Data) throws {}
    func writeAsync(type: RelayWireType, payload: Data) {}
}

/// After a preserving restart, a restored agent pane owes one authoritative
/// repaint. Its request is refused while rendering is off (the window still
/// restoring). Resuming presentation must ask again; otherwise the cached
/// frame stays until the user resizes the pane.
@MainActor @Suite("A restored pane asks for its owed repaint when rendering resumes")
struct RelayAttachRepaintRearmTests {
    private static let profile = ConnectionProfile(
        name: "rearm", kind: .ssh, host: "rearm.invalid", backend: .relay)

    @Test func renderingResumingRequestsTheOwedAttachRepaint() async throws {
        _ = NSApplication.shared
        let pane = PaneModel(profile: Self.profile)
        let runtime = pane.runtime
        let transport = RelayRemoteTransport(attachedFrameWriter: RearmFrameWriter(), profile: Self.profile,
            paneID: pane.id, capabilities: ["input_ack_v1", "viewport_commit_v1", "viewport_commit_v2"],
            controlGranted: true)
        runtime.ioForTesting.seedInitialViewport(.init(columns: 100, rows: 30))
        runtime.startForTesting(transport: transport)
        pane.connected()
        let view = runtime.view
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil; TerminalSnapshotStore.shared.remove(paneID: pane.id) }
        let lease = UUID()
        runtime.setPresented(true, lease: lease, generation: runtime.beginPresentationAttachment(lease: lease))

        NotificationCenter.default.post(name: .relayApplicationActivityChanged, object: false)
        for _ in 0..<10 { await Task.yield() }
        var requests = 0
        runtime.initialRepaintRequestedForTesting = { requests += 1 }
        NotificationCenter.default.post(name: .relayApplicationActivityChanged, object: true)
        // The viewport reclaim samples geometry for about half a second.
        for _ in 0..<60 where requests == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(requests > 0)
    }
}

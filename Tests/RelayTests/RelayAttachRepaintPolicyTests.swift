import Foundation
import Testing
@testable import Relay

private final class RepaintFrames: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RelayWireFrame] = []
    func write(type: RelayWireType, payload: Data) throws { writeAsync(type: type, payload: payload) }
    func writeAsync(type: RelayWireType, payload: Data) {
        lock.lock(); recorded.append(.init(type: type, payload: payload)); lock.unlock()
    }
}

// After a GUI relaunch the first attach of a retained Codex pane is denied the
// input lease (the previous process still holds its grace period). The worker
// skips its pre-attach repaint for such a client, and the read-only replay
// advances the cursor past 0, so the lease-granted retry used to attach with
// no repaint at all: a blank pane until a manual reconnect.
struct RelayAttachRepaintPolicyTests {
    private func attached(controlGranted: Bool, repaint: String = "attach_repaint_v2") -> RelayWireFrame {
        .init(type: .status, payload: Data(
            "{\"state\":\"attached\",\"capabilities\":[\"input_lease_v1\",\"input_ack_v1\",\"event_cursor_v1\",\"attach_repaint_v1\",\"\(repaint)\"],\"control_granted\":\(controlGranted)}".utf8))
    }

    private func output(_ sequence: UInt8) -> RelayWireFrame {
        .init(type: .output, payload: Data([0, 0, 0, 0, 0, 0, 0, sequence]) + Data("replay".utf8))
    }

    @Test func policyOwesRepaintOnlyForLeaseDeniedTerminalAttach() {
        let v2 = ["input_lease_v1", "attach_repaint_v1", "attach_repaint_v2"]
        #expect(RelayAttachRepaintPolicy.owesRepaintAfterAttach(capabilities: v2,
            controlGranted: false, observeAgentsOnly: false))
        #expect(RelayAttachRepaintPolicy.owesRepaintAfterAttach(capabilities: v2,
            controlGranted: nil, observeAgentsOnly: false))
        // Retained v1 workers pulse a temporary row count; never request it.
        #expect(!RelayAttachRepaintPolicy.owesRepaintAfterAttach(capabilities: ["input_lease_v1", "attach_repaint_v1"],
            controlGranted: false, observeAgentsOnly: false))
        #expect(!RelayAttachRepaintPolicy.owesRepaintAfterAttach(capabilities: v2,
            controlGranted: true, observeAgentsOnly: false))
        #expect(!RelayAttachRepaintPolicy.owesRepaintAfterAttach(capabilities: [],
            controlGranted: nil, observeAgentsOnly: false))
        #expect(!RelayAttachRepaintPolicy.owesRepaintAfterAttach(capabilities: v2,
            controlGranted: false, observeAgentsOnly: true))
    }

    @Test func onlyALeaseHoldingOrLegacyRouteAcceptsTheInitialWidthRepaint() {
        #expect(RelayAttachRepaintPolicy.routeAcceptsResize(attached: true, leaseCapable: true, controlGranted: true))
        #expect(RelayAttachRepaintPolicy.routeAcceptsResize(attached: true, leaseCapable: false, controlGranted: false))
        #expect(!RelayAttachRepaintPolicy.routeAcceptsResize(attached: true, leaseCapable: true, controlGranted: false))
        #expect(!RelayAttachRepaintPolicy.routeAcceptsResize(attached: false, leaseCapable: false, controlGranted: true))
    }

    @Test func leaseDeniedDedicatedAttachCarriesRepaintToLeaseGrantedAttach() throws {
        let writer = RepaintFrames()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: .init(name: "Lease-denied repaint", host: "owned-peer.invalid"), paneID: UUID(),
            capabilities: ["input_lease_v1"], controlGranted: true)
        defer { transport.detach() }
        #expect(!transport.nextAttachRequestsRepaint)

        let denied = Process()
        #expect(transport.installDedicatedProcess(denied, writer: writer))
        try transport.receiveAttachedDedicatedFrame(attached(controlGranted: false), sourceProcess: denied)
        try transport.receiveAttachedDedicatedFrame(output(7), sourceProcess: denied)
        // The replay moved the cursor, so the worker's cold-attach repaint
        // (last_seq == 0) cannot apply; the next Hello must ask for it.
        #expect(transport.nextAttachRequestsRepaint)
        // The client width repaint must wait: this route's resizes are dropped.
        #expect(!transport.acceptsViewportRepaint)

        let granted = Process()
        #expect(transport.installDedicatedProcess(granted, writer: writer))
        try transport.receiveAttachedDedicatedFrame(attached(controlGranted: true), sourceProcess: granted)
        // Paid once by the lease holder's attach; not repeated afterwards.
        #expect(!transport.nextAttachRequestsRepaint)
        #expect(transport.acceptsViewportRepaint)
    }

    @Test func leaseDeniedSharedAttachSendsRepaintPulseInNextHello() {
        let writer = RepaintFrames()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: .init(name: "Shared lease-denied repaint", host: "owned-peer.invalid"), paneID: UUID(),
            capabilities: ["input_lease_v1"], controlGranted: false)
        defer { transport.detach() }
        #expect(transport.nextMultiplexedHello()?["repaint_pulse"] == nil)

        transport.receiveMultiplexedFrame(attached(controlGranted: false))
        transport.receiveMultiplexedFrame(output(7))
        let retry = transport.nextMultiplexedHello()
        #expect(retry?["last_seq"] as? UInt64 == 7)
        #expect(retry?["repaint_pulse"] as? Bool == true)
        // A denied route cannot spend the client's width repaint attempt.
        #expect(!transport.acceptsViewportRepaint)

        transport.receiveMultiplexedFrame(attached(controlGranted: true))
        #expect(transport.nextMultiplexedHello()?["repaint_pulse"] == nil)
        #expect(transport.acceptsViewportRepaint)
    }

    @Test func leaseDeniedV1WorkerKeepsRepaintForClientActualGridPath() {
        let writer = RepaintFrames()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: .init(name: "Retained v1 repaint", host: "owned-peer.invalid"), paneID: UUID(),
            capabilities: ["input_lease_v1"], controlGranted: false)
        defer { transport.detach() }
        transport.receiveMultiplexedFrame(attached(controlGranted: false, repaint: "attach_repaint_v1"))
        transport.receiveMultiplexedFrame(output(3))
        // No row-pulse request to a v1 worker ...
        #expect(transport.nextMultiplexedHello()?["repaint_pulse"] == nil)
        #expect(!transport.nextAttachRequestsRepaint)
        // ... and the client width repaint stays deferred until control.
        #expect(!transport.acceptsViewportRepaint)
        transport.receiveMultiplexedFrame(attached(controlGranted: true, repaint: "attach_repaint_v1"))
        #expect(transport.acceptsViewportRepaint)
    }
}

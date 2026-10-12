import Foundation
import Testing
@testable import Relay

private final class FrameReadyWriter: RelayFrameWriting, @unchecked Sendable {
    func write(type: RelayWireType, payload: Data) throws {}
    func writeAsync(type: RelayWireType, payload: Data) {}
}
private final class FrameReadyTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    func append(_ task: Task<Void, Never>) { lock.lock(); tasks.append(task); lock.unlock() }
    var snapshot: [Task<Void, Never>] { lock.lock(); defer { lock.unlock() }; return tasks }
}
@MainActor private final class FrameReadyUI { var notifications = 0 }

struct RelayFrameReadySourceTests {
    @MainActor @Test(arguments: [false, true])
    func oldReadinessCannotReleaseSuccessorCover(sameObject: Bool) async {
        let writer = FrameReadyWriter(), io = TerminalIOBridge()
        let tasks = FrameReadyTasks(), state = FrameReadyUI()
        let profile = ConnectionProfile(name: "Owned frame readiness", host: "owned-peer.invalid")
        let original = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile,
            paneID: UUID(), capabilities: [], controlGranted: true)
        let current = sameObject ? original : RelayRemoteTransport(attachedFrameWriter: writer,
            profile: profile, paneID: UUID(), capabilities: [], controlGranted: true)
        defer { _ = io.removeTransport(); original.detach(); if current !== original { current.detach() } }
        io.onViewportFrameReady = { producer, source, epoch in
            tasks.append(Task { @MainActor [weak io, weak source, weak state] in
                guard let io, let state, io.isCurrentOutputProducer(producer) else { return }
                if let epoch {
                    guard let source, io.isCurrentTransport(source, deliveryEpoch: epoch) else { return }
                }
                state.notifications += 1
            })
        }
        io.installTransport(original)
        #expect(original.installDedicatedProcess(Process(), writer: writer))
        io.beginViewportTransition()
        io.armViewportFrameBarrier(rows: 40)
        let frame = Data(("\u{001B}[?2026h\u{001B}[2J\u{001B}[H" +
            String(repeating: "frame", count: 120) + "\u{001B}[?2026l").utf8)
        #expect(io.receive(frame, sourceTransport: original))
        if !sameObject { io.installTransport(current) }
        #expect(current.installDedicatedProcess(Process(), writer: writer))
        io.armViewportFrameBarrier(rows: 40)
        #expect(io.receive(frame, sourceTransport: current))
        #expect(tasks.snapshot.count == 2)
        for task in tasks.snapshot { await task.value }
        #expect(state.notifications == 1)
    }
}

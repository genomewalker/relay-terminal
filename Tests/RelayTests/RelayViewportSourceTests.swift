import Foundation
import Testing
@testable import Relay

private final class ViewportSourceWriter: RelayFrameWriting, @unchecked Sendable {
    func write(type: RelayWireType, payload: Data) throws {}
    func writeAsync(type: RelayWireType, payload: Data) {}
}

private final class ViewportSourceTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Task<Void, Never>] = []
    func append(_ task: Task<Void, Never>) { lock.lock(); values.append(task); lock.unlock() }
    var snapshot: [Task<Void, Never>] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor private final class ViewportSourceUI {
    var applied: [UInt64] = []
}

struct RelayViewportSourceTests {
    @Test func pendingRepaintAcknowledgementDoesNotCrossProducerEpoch() throws {
        let writer = ViewportSourceWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: ConnectionProfile(name: "Owned pending viewport", host: "owned-peer.invalid"),
            paneID: UUID(), capabilities: [], controlGranted: true)
        defer { transport.detach() }
        let tasks = ViewportSourceTasks()
        transport.setViewportCommitHandler { _, _ in
            tasks.append(Task {})
        }
        let original = Process(), successor = Process()
        try attach(transport, process: original, writer: writer)
        let generation = try #require(transport.sendResize(columns: 80, rows: 24, forceRepaint: true))
        var generationBytes = generation.bigEndian
        var repaintBytes = UInt64(1).bigEndian
        let acknowledgement = withUnsafeBytes(of: &generationBytes) { Data($0) }
            + withUnsafeBytes(of: &repaintBytes) { Data($0) }
        try transport.receiveAttachedDedicatedFrame(.init(type: .viewportAck,
            payload: acknowledgement), sourceProcess: original)
        #expect(tasks.snapshot.isEmpty)
        try attach(transport, process: successor, writer: writer)
        let output = withUnsafeBytes(of: &repaintBytes) { Data($0) } + Data("successor".utf8)
        try transport.receiveAttachedDedicatedFrame(.init(type: .output,
            payload: output), sourceProcess: successor)
        #expect(tasks.snapshot.isEmpty)
    }

    private func attach(_ transport: RelayRemoteTransport, process: Process,
        writer: ViewportSourceWriter) throws {
        #expect(transport.installDedicatedProcess(process, writer: writer))
        try transport.receiveAttachedDedicatedFrame(.init(type: .status,
            payload: Data("{\"state\":\"attached\",\"capabilities\":[\"viewport_commit_v2\",\"viewport_attach_v1\"]}".utf8)), sourceProcess: process)
    }

    private func commit(_ transport: RelayRemoteTransport, process: Process) throws -> UInt64 {
        let generation = try #require(transport.sendResize(columns: 80, rows: 24, forceRepaint: true))
        var bigEndian = generation.bigEndian
        let payload = withUnsafeBytes(of: &bigEndian) { Data($0) } + Data(repeating: 0, count: 8)
        try transport.receiveAttachedDedicatedFrame(.init(type: .viewportAck, payload: payload), sourceProcess: process)
        return generation
    }

    @MainActor @Test(arguments: [false, true])
    func queuedCompletionCannotCommitSuccessorPresentation(sameObject: Bool) async throws {
        let writer = ViewportSourceWriter(), tasks = ViewportSourceTasks()
        let io = TerminalIOBridge(), state = ViewportSourceUI()
        let profile = ConnectionProfile(name: "Owned viewport source", host: "owned-peer.invalid")
        let old = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile,
            paneID: UUID(), capabilities: [], controlGranted: true)
        let successor = sameObject ? old : RelayRemoteTransport(attachedFrameWriter: writer,
            profile: profile, paneID: UUID(), capabilities: [], controlGranted: true)
        defer { _ = io.removeTransport(); old.detach(); if successor !== old { successor.detach() } }
        io.onViewportCommitted = { generation, source, epoch in
            tasks.append(Task { @MainActor [weak io, weak source, weak state] in
                guard let io, let source, let state,
                      io.isCurrentTransport(source, deliveryEpoch: epoch) else { return }
                state.applied.append(generation)
            })
        }
        let oldProcess = Process(), currentProcess = Process()
        io.installTransport(old)
        try attach(old, process: oldProcess, writer: writer)
        let oldGeneration = try commit(old, process: oldProcess)
        io.installTransport(successor)
        try attach(successor, process: currentProcess, writer: writer)
        let currentGeneration = try commit(successor, process: currentProcess)
        if !sameObject { #expect(oldGeneration == currentGeneration) }
        for task in tasks.snapshot { await task.value }
        #expect(state.applied == [currentGeneration])
    }
}

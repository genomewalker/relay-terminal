import Foundation
import Testing
@testable import Relay

private final class EpochFrameWriter: RelayFrameWriting, @unchecked Sendable {
    func write(type: RelayWireType, payload: Data) throws {}
    func writeAsync(type: RelayWireType, payload: Data) {}
}

private final class EpochTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    func append(_ task: Task<Void, Never>) { lock.lock(); tasks.append(task); lock.unlock() }
    var snapshot: [Task<Void, Never>] { lock.lock(); defer { lock.unlock() }; return tasks }
}

@MainActor private final class EpochUIState {
    weak var transport: RelayRemoteTransport?
    let io = TerminalIOBridge()
    var applied: [String] = []
}

struct RelayDeferredDeliveryEpochTests {
    @MainActor @Test func deferredFramesRejectRetiredEpochWithinSameTransport() async throws {
        let state = EpochUIState(), tasks = EpochTasks()
        let enqueue: @Sendable (String, UUID) -> Void = { value, epoch in
            tasks.append(Task { @MainActor [weak state] in
                guard let state, let transport = state.transport,
                      state.io.isCurrentTransport(transport, deliveryEpoch: epoch) else { return }
                state.applied.append(value)
            })
        }
        let writer = EpochFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: .init(name: "Owned deferred epoch", host: "owned-peer.invalid"), paneID: UUID(),
            capabilities: [], controlGranted: true,
            onOutput: { data, _, epoch in enqueue("output:" + String(decoding: data, as: UTF8.self), epoch) },
            onStatus: { status, epoch in enqueue("status:" + status.state, epoch) },
            onAgentEvent: { data, epoch in enqueue("agent:" + String(decoding: data, as: UTF8.self), epoch) })
        state.transport = transport
        state.io.installTransport(transport)
        defer { _ = state.io.removeTransport(); transport.detach() }
        let old = Process(), current = Process()
        #expect(transport.installDedicatedProcess(old, writer: writer))
        let oldEpoch = transport.deliveryEpochSnapshot()
        try transport.receiveAttachedDedicatedFrame(.init(type: .output,
            payload: Data([0, 0, 0, 0, 0, 0, 0, 1]) + Data("old".utf8)), sourceProcess: old)
        try transport.receiveAttachedDedicatedFrame(.init(type: .status,
            payload: Data("{\"state\":\"caught_up\"}".utf8)), sourceProcess: old)
        try transport.receiveAttachedDedicatedFrame(.init(type: .agentEvent,
            payload: Data("old".utf8)), sourceProcess: old)
        #expect(transport.installDedicatedProcess(current, writer: writer))
        #expect(state.io.isCurrentTransport(transport))
        #expect(!state.io.isCurrentTransport(transport, deliveryEpoch: oldEpoch))
        try transport.receiveAttachedDedicatedFrame(.init(type: .output,
            payload: Data([0, 0, 0, 0, 0, 0, 0, 2]) + Data("current".utf8)), sourceProcess: current)
        try transport.receiveAttachedDedicatedFrame(.init(type: .status,
            payload: Data("{\"state\":\"caught_up\"}".utf8)), sourceProcess: current)
        try transport.receiveAttachedDedicatedFrame(.init(type: .agentEvent,
            payload: Data("current".utf8)), sourceProcess: current)
        for task in tasks.snapshot { await task.value }
        #expect(state.applied == ["output:current", "status:caught_up", "agent:current"])
    }
}

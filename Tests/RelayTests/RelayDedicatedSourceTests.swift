import Foundation
import Testing
@testable import Relay

private final class DedicatedFrames: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RelayWireFrame] = []
    func write(type: RelayWireType, payload: Data) throws { writeAsync(type: type, payload: payload) }
    func writeAsync(type: RelayWireType, payload: Data) {
        lock.lock(); recorded.append(.init(type: type, payload: payload)); lock.unlock()
    }
    var frames: [RelayWireFrame] { lock.lock(); defer { lock.unlock() }; return recorded }
}

struct RelayDedicatedSourceTests {
    private func output(_ sequence: UInt8, _ text: String) -> RelayWireFrame {
        .init(type: .output, payload: Data([0, 0, 0, 0, 0, 0, 0, sequence]) + Data(text.utf8))
    }

    @Test func retiredFramesCannotResetSuccessorOrReplyThroughItsWriter() throws {
        let oldWriter = DedicatedFrames(), newWriter = DedicatedFrames(), observed = DedicatedFrames()
        let transport = RelayRemoteTransport(attachedFrameWriter: oldWriter,
            profile: .init(name: "Owned dedicated source", host: "owned-peer.invalid"), paneID: UUID(),
            capabilities: [], controlGranted: true,
            onOutput: { data, _, _ in observed.writeAsync(type: .output, payload: data) },
            onStatus: { status, _ in observed.writeAsync(type: .status, payload: Data(status.state.utf8)) },
            onAgentEvent: { data, _ in observed.writeAsync(type: .agentEvent, payload: data) })
        let old = Process(), current = Process()
        defer { transport.detach() }
        #expect(transport.installDedicatedProcess(old, writer: oldWriter))
        #expect(transport.installDedicatedProcess(current, writer: newWriter))
        try transport.receiveAttachedDedicatedFrame(output(2, "current-two"), sourceProcess: current)
        try transport.receiveAttachedDedicatedFrame(.init(type: .status,
            payload: Data("{\"state\":\"error\",\"output_reset\":true}".utf8)), sourceProcess: old)
        try transport.receiveAttachedDedicatedFrame(.init(type: .agentEvent, payload: Data("retired-event".utf8)), sourceProcess: old)
        try transport.receiveAttachedDedicatedFrame(output(99, "retired-output"), sourceProcess: old)
        try transport.receiveAttachedDedicatedFrame(.init(type: .ping, payload: Data()), sourceProcess: old)
        try transport.receiveAttachedDedicatedFrame(output(1, "obsolete-sequence"), sourceProcess: current)
        try transport.receiveAttachedDedicatedFrame(output(3, "current-three"), sourceProcess: current)
        try transport.receiveAttachedDedicatedFrame(.init(type: .ping, payload: Data()), sourceProcess: current)
        #expect(observed.frames.map(\.payload) == [Data("current-two".utf8), Data("current-three".utf8)])
        #expect(oldWriter.frames.filter { $0.type == .pong }.isEmpty)
        #expect(newWriter.frames.filter { $0.type == .pong }.count == 1)
    }

    @Test func replacementWaitsForAdmittedCallback() throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let replacing = DispatchSemaphore(value: 0), replaced = DispatchSemaphore(value: 0)
        let oldWriter = DedicatedFrames(), newWriter = DedicatedFrames(), observed = DedicatedFrames()
        let transport = RelayRemoteTransport(attachedFrameWriter: oldWriter,
            profile: .init(name: "Owned dedicated barrier", host: "owned-peer.invalid"), paneID: UUID(),
            capabilities: [], controlGranted: true, onOutput: { data, _, _ in
                if data == Data("admitted".utf8) { started.signal(); release.wait() }
                observed.writeAsync(type: .output, payload: data)
            })
        let old = Process(), current = Process()
        defer { transport.detach() }
        #expect(transport.installDedicatedProcess(old, writer: oldWriter))
        let frame = output(1, "admitted")
        DispatchQueue.global().async { try? transport.receiveAttachedDedicatedFrame(frame, sourceProcess: old) }
        #expect(started.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            replacing.signal()
            _ = transport.installDedicatedProcess(current, writer: newWriter)
            replaced.signal()
        }
        #expect(replacing.wait(timeout: .now() + 2) == .success)
        let premature = replaced.wait(timeout: .now() + 0.05)
        #expect(premature == .timedOut)
        release.signal()
        if premature == .timedOut { #expect(replaced.wait(timeout: .now() + 2) == .success) }
        try transport.receiveAttachedDedicatedFrame(output(99, "retired"), sourceProcess: old)
        try transport.receiveAttachedDedicatedFrame(output(2, "successor"), sourceProcess: current)
        #expect(observed.frames.map(\.payload) == [Data("admitted".utf8), Data("successor".utf8)])
    }

    @Test func callbackCanDetachItsOwnProducer() {
        let writer = DedicatedFrames()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: .init(name: "Owned dedicated reentrancy", host: "owned-peer.invalid"), paneID: UUID(),
            capabilities: [], controlGranted: true)
        let source = Process()
        #expect(transport.installDedicatedProcess(source, writer: writer))
        let stillCurrent = transport.performForDedicatedProcess(source) { _ in transport.detach() }
        #expect(!stillCurrent)
        #expect(!transport.installDedicatedProcess(Process(), writer: writer))
    }
}

import Foundation
import Testing
@testable import Relay

private final class OwnedNodeFrameWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RelayWireFrame] = []
    func write(type: RelayWireType, payload: Data) throws { append(type, payload) }
    func writeAsync(type: RelayWireType, payload: Data) { append(type, payload) }
    private func append(_ type: RelayWireType, _ payload: Data) {
        lock.lock(); recorded.append(.init(type: type, payload: payload)); lock.unlock()
    }
    var frames: [RelayWireFrame] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

@Suite(.serialized)
struct RelayNodeChannelOwnershipTests {
    private func add(_ connection: RelayNodeConnection, _ session: String) -> RelayNodeChannel {
        connection.add(sessionID: session, onReady: { _ in }, onFrame: { _ in }, onDisconnect: { _ in })
    }

    @Test func replacedChannelCannotWriteThroughSuccessorSessionID() throws {
        let writer = OwnedNodeFrameWriter()
        let connection = RelayNodeConnection(profile: .init(name: "Owned node fixture", host: "owned-node.invalid"),
            attachedFrameWriter: writer)
        let original = add(connection, "owned-pane")
        let successor = add(connection, "owned-pane")
        defer { original.close(); successor.close() }
        #expect(throws: RelayNodeTransportError.self) {
            try original.write(type: .input, payload: Data("stale sync".utf8))
        }
        original.writeAsync(type: .input, payload: Data("stale async".utf8))
        #expect(writer.frames.isEmpty)
        try successor.write(type: .input, payload: Data("current".utf8))
        #expect(writer.frames.count == 1)
        let current = try #require(writer.frames.first.flatMap { RelayWireFrame.parseHostEvent($0) })
        #expect(current.sessionID == "owned-pane")
        #expect(current.inner.payload == Data("current".utf8))
        original.close()
        successor.writeAsync(type: .input, payload: Data("still current".utf8))
        #expect(writer.frames.count == 2)
        #expect(writer.frames.last.flatMap { RelayWireFrame.parseHostEvent($0) }?.inner.payload == Data("still current".utf8))
    }

    @Test func paneReadyIsDeliveredAfterFragmentNegotiation() throws {
        let writer = OwnedNodeFrameWriter()
        let connection = RelayNodeConnection(profile: .init(name: "Owned node negotiation", host: "owned-node.invalid"),
            attachedFrameWriter: writer, attachedGeneration: 2, protocolReady: false)
        let ready = DispatchSemaphore(value: 0)
        let observations = OwnedNodeFrameWriter()
        let channel = connection.add(sessionID: "owned-pane", onReady: { _ in
            for frame in writer.frames { observations.writeAsync(type: frame.type, payload: frame.payload) }
            ready.signal()
        }, onFrame: { _ in }, onDisconnect: { _ in })
        defer { channel.close() }
        let status = RelayWireFrame(type: .status,
            payload: Data("{\"state\":\"ready\",\"capabilities\":[\"node_mux_v1\",\"wire_fragments_v1\"]}".utf8))
        connection.receiveAttachedFrame(status, generation: 1)
        #expect(writer.frames.isEmpty)
        connection.receiveAttachedFrame(status, generation: 2)
        #expect(ready.wait(timeout: .now() + 2) == .success)
        channel.close()
        #expect(observations.frames.map(\.type) == [.capabilities])
        #expect(observations.frames.first?.payload == RelayNodeCapabilities.payload)
    }

    @Test func retiredReaderCannotRouteIntoCurrentSubscription() throws {
        let writer = OwnedNodeFrameWriter()
        let connection = RelayNodeConnection(profile: .init(name: "Owned node generation", host: "owned-node.invalid"),
            attachedFrameWriter: writer, attachedGeneration: 2)
        let output = OwnedNodeFrameWriter()
        let received = DispatchSemaphore(value: 0)
        let channel = connection.add(sessionID: "owned-pane", onReady: { _ in }, onFrame: { frame in
            output.writeAsync(type: frame.type, payload: frame.payload)
            received.signal()
        }, onDisconnect: { _ in })
        defer { channel.close() }
        let stale = try #require(RelayWireFrame.hostEvent(sessionID: "owned-pane",
            inner: .init(type: .output, payload: Data("retired".utf8))))
        let current = try #require(RelayWireFrame.hostEvent(sessionID: "owned-pane",
            inner: .init(type: .output, payload: Data("current".utf8))))
        connection.receiveAttachedFrame(stale, generation: 1)
        connection.receiveAttachedFrame(current, generation: 2)
        #expect(received.wait(timeout: .now() + 2) == .success)
        channel.close() // drains any admitted callback before examining frames
        #expect(output.frames.map(\.payload) == [Data("current".utf8)])
    }

    @Test func closedChannelWritesNothingWhileAnotherPaneRemainsAttached() throws {
        let writer = OwnedNodeFrameWriter()
        let connection = RelayNodeConnection(profile: .init(name: "Owned node fixture", host: "owned-node.invalid"),
            attachedFrameWriter: writer)
        let retired = add(connection, "retired-pane")
        let active = add(connection, "active-pane")
        defer { active.close() }
        retired.close()
        let before = writer.frames.count
        retired.writeAsync(type: .input, payload: Data("closed".utf8))
        #expect(throws: RelayNodeTransportError.self) { try retired.write(type: .input, payload: Data("closed".utf8)) }
        #expect(writer.frames.count == before)
        active.writeAsync(type: .input, payload: Data("active".utf8))
        #expect(writer.frames.count == before + 1)
        #expect(writer.frames.last.flatMap { RelayWireFrame.parseHostEvent($0) }?.sessionID == "active-pane")
    }
}

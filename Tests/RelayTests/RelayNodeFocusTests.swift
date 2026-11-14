import Foundation
import Testing
@testable import Relay

private final class FocusFrameRecorder: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RelayWireFrame] = []
    func write(type: RelayWireType, payload: Data) throws { append(type, payload) }
    func writeAsync(type: RelayWireType, payload: Data) { append(type, payload) }
    private func append(_ type: RelayWireType, _ payload: Data) {
        lock.lock(); recorded.append(.init(type: type, payload: payload)); lock.unlock()
    }
    func frames(of type: RelayWireType) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.type == type }.map(\.payload)
    }
    /// The routes of each Focus frame sent, in order.
    var focusSends: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.type == .focus }.map { frame in
            ((try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: [String]])?["routes"] ?? ["<invalid>"]
        }
    }
}

@Suite(.serialized)
struct RelayNodeFocusTests {
    private func readyStatus(_ capabilities: [String]) -> RelayWireFrame {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return RelayWireFrame(type: .status, payload: Data("{\"state\":\"ready\",\"capabilities\":[\(list)]}".utf8))
    }

    private func node(_ writer: FocusFrameRecorder) -> RelayNodeConnection {
        RelayNodeConnection(profile: .init(name: "Focus node fixture", host: "focus-node.invalid"),
            attachedFrameWriter: writer, attachedGeneration: 1, protocolReady: false)
    }

    private func add(_ connection: RelayNodeConnection, _ session: String) -> RelayNodeChannel {
        connection.add(sessionID: session, onReady: { _ in }, onFrame: { _ in }, onDisconnect: { _ in })
    }

    @Test func payloadIsSortedAndBounded() throws {
        let decode = { (data: Data) in ((try? JSONSerialization.jsonObject(with: data)) as? [String: [String]])?["routes"] }
        #expect(decode(RelayNodeFocus.payload(routes: ["b", "a"])) == ["a", "b"])
        #expect(decode(RelayNodeFocus.payload(routes: [])) == [])
        #expect(decode(RelayNodeFocus.payload(routes: ["a", "b", "c", "d", "e"])) == [])
    }

    @Test func focusIsSentOnReadyAndFollowsTheFocusedPane() throws {
        let writer = FocusFrameRecorder()
        let connection = node(writer)
        let a = add(connection, "focus-pane-a")
        let b = add(connection, "focus-pane-b")
        defer { a.close(); b.close() }
        a.setFocused(true)
        #expect(writer.focusSends.isEmpty) // not ready yet
        connection.receiveAttachedFrame(readyStatus(["node_mux_v1", "node_focus_v1"]), generation: 1)
        #expect(writer.focusSends == [["focus-pane-a"]])
        b.setFocused(true)
        a.setFocused(false)
        #expect(writer.focusSends.last == ["focus-pane-b"])
        let count = writer.focusSends.count
        b.setFocused(true) // unchanged: nothing sent
        #expect(writer.focusSends.count == count)
        b.close()
        #expect(writer.focusSends.last == []) // a closed pane leaves the focus set
    }

    @Test func olderNodeGetsNoFocusFrames() throws {
        let writer = FocusFrameRecorder()
        let connection = node(writer)
        let a = add(connection, "focus-pane-a")
        defer { a.close() }
        connection.receiveAttachedFrame(readyStatus(["node_mux_v1"]), generation: 1)
        a.setFocused(true)
        #expect(writer.focusSends.isEmpty)
    }

    @Test func appAdvertisesPingEchoAndAnswersNodePings() throws {
        let caps = try #require((try? JSONSerialization.jsonObject(with: RelayNodeCapabilities.payload)) as? [String: Bool])
        #expect(caps == ["wire_fragments": true, "node_ping_echo": true])
        let writer = FocusFrameRecorder()
        let connection = node(writer)
        let a = add(connection, "focus-pane-a")
        defer { a.close() }
        connection.receiveAttachedFrame(readyStatus(["node_mux_v1"]), generation: 1)
        let probe = Data([0, 0, 0, 0, 0, 0, 0, 7])
        connection.receiveAttachedFrame(RelayWireFrame(type: .ping, payload: probe), generation: 1)
        #expect(writer.frames(of: .pong) == [probe])
        connection.receiveAttachedFrame(RelayWireFrame(type: .ping, payload: probe), generation: 0) // retired reader
        #expect(writer.frames(of: .pong) == [probe])
    }
}

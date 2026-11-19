import Foundation
import Testing
@testable import Relay

/// 2026-11-14: after a restart the app held 86 per-pane `relayd attach` SSH
/// connections to dandy-07 instead of its one node. Every first shared-route
/// retry moved a pane to its own SSH for good, including a closed route
/// ("fell behind a fast terminal redraw") and an error answer ("saved pane
/// worker is missing"), neither of which means the node stopped answering.
private final class FallbackFrames: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RelayWireFrame] = []
    func write(type: RelayWireType, payload: Data) throws { writeAsync(type: type, payload: payload) }
    func writeAsync(type: RelayWireType, payload: Data) {
        lock.lock(); recorded.append(.init(type: type, payload: payload)); lock.unlock()
    }
    var frames: [RelayWireFrame] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    var hellos: Int { frames.filter { RelayWireFrame.parseHostEvent($0)?.inner.type == .hello }.count }
    var messages: [String] { frames.map { String(decoding: $0.payload, as: UTF8.self) } }
}

private final class FallbackNodes: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [(node: RelayNodeConnection, writer: FallbackFrames)] = []
    func pool() -> RelayNodeTransportPool {
        RelayNodeTransportPool(makeNode: { [self] profile, onIdle in
            let writer = FallbackFrames()
            let node = RelayNodeConnection(profile: profile, attachedFrameWriter: writer, onIdle: onIdle)
            lock.lock(); made.append((node, writer)); lock.unlock()
            return node
        })
    }
    var first: (node: RelayNodeConnection, writer: FallbackFrames)? {
        lock.lock(); defer { lock.unlock() }
        return made.first
    }
}

@Suite struct RelayPaneFallbackTests {
    private let profile = ConnectionProfile(name: "Fallback fixture", host: "fallback-node.invalid")

    /// A node in use carries other panes; a neighbour keeps this one from
    /// going idle (and stopping) when the pane under test closes its route.
    private func neighbour(_ pool: RelayNodeTransportPool) -> RelayNodeChannel {
        pool.attach(profile: profile, sessionID: "neighbour", onReady: { _ in }, onFrame: { _ in },
            onDisconnect: { _ in })
    }

    private func start(_ pool: RelayNodeTransportPool, session: String, statuses: FallbackFrames) -> RelayRemoteTransport {
        let transport = RelayRemoteTransport()
        transport.nodePool = pool
        transport.handshakeTimeoutMilliseconds = 500
        transport.start(profile: profile, sessionID: session, parentSessionID: nil,
            workspaceSessionID: nil, tabID: nil, paneTitle: session, contentKind: "terminal",
            onOutput: { _, _, _ in },
            onStatus: { status, _ in
                statuses.writeAsync(type: .status, payload: Data("\(status.state) \(status.message ?? "")".utf8))
            },
            onAgentEvent: { _, _ in }, onArtifact: { _, _ in }, onDisconnect: { _, _ in })
        return transport
    }

    private func send(_ node: RelayNodeConnection, session: String, _ json: String) throws {
        let frame = try #require(RelayWireFrame.hostEvent(sessionID: session,
            inner: .init(type: .status, payload: Data(json.utf8))))
        node.receiveAttachedFrame(frame, generation: 0)
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }

    @Test("A closed route reopens on the shared node, not on a dedicated SSH")
    func closedRouteStaysShared() throws {
        let nodes = FallbackNodes()
        let statuses = FallbackFrames()
        let pool = nodes.pool()
        let other = neighbour(pool)
        defer { other.close() }
        let transport = start(pool, session: "closed-route", statuses: statuses)
        defer { transport.detach() }
        let node = try #require(nodes.first)
        waitUntil { node.writer.hellos == 1 }
        try send(node.node, session: "closed-route", #"{"state":"attached","capabilities":[]}"#)
        try send(node.node, session: "closed-route", #"{"state":"route_closed"}"#)
        waitUntil { node.writer.hellos == 2 }
        #expect(node.writer.hellos == 2)
        try send(node.node, session: "closed-route", #"{"state":"attached","capabilities":[]}"#)
        #expect(transport.currentNodeChannel != nil)
        #expect(!statuses.messages.contains { $0.contains("dedicated") })
    }

    @Test("An answered error retries once on the shared node, then stops")
    func answeredErrorRetriesOnceShared() throws {
        let nodes = FallbackNodes()
        let statuses = FallbackFrames()
        let pool = nodes.pool()
        let other = neighbour(pool)
        defer { other.close() }
        let transport = start(pool, session: "missing-worker", statuses: statuses)
        defer { transport.detach() }
        let node = try #require(nodes.first)
        let missing = #"{"state":"error","message":"saved pane worker is missing; no replacement was started"}"#
        waitUntil { node.writer.hellos == 1 }
        try send(node.node, session: "missing-worker", missing)
        waitUntil { node.writer.hellos == 2 }
        #expect(node.writer.hellos == 2)
        try send(node.node, session: "missing-worker", missing)
        // Several watchdog periods: no third Hello and no dedicated route.
        Thread.sleep(forTimeInterval: 1.6)
        #expect(node.writer.hellos == 2)
        #expect(!statuses.messages.contains { $0.contains("dedicated") })
    }

    @Test("A transient error that then attaches keeps the pane on the shared node")
    func answeredErrorThenAttachStaysShared() throws {
        let nodes = FallbackNodes()
        let statuses = FallbackFrames()
        let pool = nodes.pool()
        let other = neighbour(pool)
        defer { other.close() }
        let transport = start(pool, session: "busy-worker", statuses: statuses)
        defer { transport.detach() }
        let node = try #require(nodes.first)
        waitUntil { node.writer.hellos == 1 }
        try send(node.node, session: "busy-worker",
            #"{"state":"error","message":"pane worker 1 is still alive but unavailable"}"#)
        waitUntil { node.writer.hellos == 2 }
        try send(node.node, session: "busy-worker", #"{"state":"attached","capabilities":[]}"#)
        // Attached again: a later closed route is retried as before.
        try send(node.node, session: "busy-worker", #"{"state":"route_closed"}"#)
        waitUntil { node.writer.hellos == 3 }
        #expect(node.writer.hellos == 3)
        try send(node.node, session: "busy-worker", #"{"state":"attached","capabilities":[]}"#)
        #expect(!statuses.messages.contains { $0.contains("dedicated") })
    }

    @Test("A single pane's closed route reopens on its node without stopping it")
    func singlePaneClosedRouteStaysShared() throws {
        let nodes = FallbackNodes()
        let statuses = FallbackFrames()
        let transport = start(nodes.pool(), session: "only-closed", statuses: statuses)
        defer { transport.detach() }
        let node = try #require(nodes.first)
        waitUntil { node.writer.hellos == 1 }
        try send(node.node, session: "only-closed", #"{"state":"attached","capabilities":[]}"#)
        try send(node.node, session: "only-closed", #"{"state":"route_closed"}"#)
        waitUntil { node.writer.hellos == 2 }
        #expect(node.writer.hellos == 2)
        try send(node.node, session: "only-closed", #"{"state":"attached","capabilities":[]}"#)
        #expect(transport.currentNodeChannel != nil)
        #expect(node.node.networkSnapshot().attachedSubscriptions == 1)
        #expect(!statuses.messages.contains { $0.contains("dedicated") })
    }

    @Test("A single pane's answered error retries once on its node without stopping it")
    func singlePaneAnsweredErrorRetriesOnceShared() throws {
        let nodes = FallbackNodes()
        let statuses = FallbackFrames()
        let transport = start(nodes.pool(), session: "only-missing", statuses: statuses)
        defer { transport.detach() }
        let node = try #require(nodes.first)
        let missing = #"{"state":"error","message":"saved pane worker is missing; no replacement was started"}"#
        waitUntil { node.writer.hellos == 1 }
        try send(node.node, session: "only-missing", missing)
        waitUntil { node.writer.hellos == 2 }
        #expect(node.writer.hellos == 2)
        try send(node.node, session: "only-missing", missing)
        Thread.sleep(forTimeInterval: 1.6)
        #expect(node.writer.hellos == 2)
        #expect(!statuses.messages.contains { $0.contains("dedicated") })
    }

    /// A dedicated route whose process emits one attached status and stays up.
    private func fakeDedicatedRoute() throws -> (URL, [String]) {
        let payload = Data(#"{"state":"attached","capabilities":[]}"#.utf8)
        var frame = Data([RelayWireType.status.rawValue])
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        frame.append(payload)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dedicated-\(UUID().uuidString).frames")
        try frame.write(to: file)
        return (URL(fileURLWithPath: "/bin/sh"), ["-c", "cat \"$0\"; exec sleep 30", file.path])
    }

    private func startStalling(_ pool: RelayNodeTransportPool, session: String, statuses: FallbackFrames) throws -> RelayRemoteTransport {
        let transport = RelayRemoteTransport()
        transport.nodePool = pool
        transport.handshakeTimeoutMilliseconds = 300
        transport.sharedReturnCheckMilliseconds = 300
        transport.dedicatedCommandOverride = try fakeDedicatedRoute()
        transport.start(profile: profile, sessionID: session, parentSessionID: nil,
            workspaceSessionID: nil, tabID: nil, paneTitle: session, contentKind: "terminal",
            onOutput: { _, _, _ in },
            onStatus: { status, _ in
                statuses.writeAsync(type: .status, payload: Data("\(status.state) \(status.message ?? "")".utf8))
            },
            onAgentEvent: { _, _ in }, onArtifact: { _, _ in }, onDisconnect: { _, _ in })
        return transport
    }

    /// 2026-11-19: after an app restart 8 dandy-07 panes stalled once on the
    /// busy shared node, moved to their own SSH, and stayed there for good.
    @Test("A pane on a dedicated SSH returns to the shared node once it is healthy")
    func dedicatedRouteReturnsToHealthySharedNode() throws {
        let nodes = FallbackNodes()
        let statuses = FallbackFrames()
        let pool = nodes.pool()
        let other = neighbour(pool)
        defer { other.close() }
        let transport = try startStalling(pool, session: "stalled", statuses: statuses)
        defer { transport.detach() }
        let node = try #require(nodes.first)
        waitUntil { node.writer.hellos == 1 }
        // No answer: the pane falls back to its own route and attaches there.
        waitUntil { statuses.messages.filter { $0.hasPrefix("attached") }.count == 1 }
        #expect(statuses.messages.contains { $0.contains("dedicated") })
        // The shared node is healthy again: traffic arrives for its other pane.
        let deadline = Date().addingTimeInterval(3)
        while node.writer.hellos < 2, Date() < deadline {
            try send(node.node, session: "neighbour", #"{"state":"clients","client_count":1}"#)
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(node.writer.hellos == 2, "the pane never rejoined the shared node")
        try send(node.node, session: "stalled", #"{"state":"attached","capabilities":[]}"#)
        waitUntil { transport.currentNodeChannel != nil }
        #expect(transport.currentNodeChannel != nil)
    }

    @Test("A pane stays on its dedicated SSH while the shared node is silent")
    func dedicatedRouteStaysWhileSharedNodeIsSilent() throws {
        let nodes = FallbackNodes()
        let statuses = FallbackFrames()
        let pool = nodes.pool()
        let other = neighbour(pool)
        defer { other.close() }
        let transport = try startStalling(pool, session: "silent", statuses: statuses)
        defer { transport.detach() }
        let node = try #require(nodes.first)
        waitUntil { statuses.messages.filter { $0.hasPrefix("attached") }.count == 1 }
        Thread.sleep(forTimeInterval: 1.2)
        #expect(node.writer.hellos == 1)
        #expect(transport.currentNodeChannel == nil)
    }
}

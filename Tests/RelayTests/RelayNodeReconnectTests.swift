import Foundation
import Testing
@testable import Relay

/// 2026-10-19: after a VPN drop, 26 dandy-07 panes stayed "Reconnecting" (and
/// some showed "Connected") with no SSH transport until Relay was restarted.
/// A pane could join a node the pool had just evicted; nothing but weak pane
/// channels referenced that node, so it was freed with its retry pending and
/// its panes never heard ready or disconnected again.
private final class RecordingFrameWriter: RelayFrameWriting, @unchecked Sendable {
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

/// Pool nodes are framed peers: no SSH process is ever started.
private final class PeerNodes: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [(node: RelayNodeConnection, writer: RecordingFrameWriter)] = []
    let protocolReady: Bool
    init(protocolReady: Bool = true) { self.protocolReady = protocolReady }

    func pool() -> RelayNodeTransportPool {
        RelayNodeTransportPool(makeNode: { [self] profile, onIdle in
            let writer = RecordingFrameWriter()
            let node = RelayNodeConnection(profile: profile, attachedFrameWriter: writer,
                protocolReady: protocolReady, onIdle: onIdle)
            lock.lock(); made.append((node, writer)); lock.unlock()
            return node
        })
    }

    var nodes: [(node: RelayNodeConnection, writer: RecordingFrameWriter)] {
        lock.lock(); defer { lock.unlock() }
        return made
    }
}

private final class SuccessorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RelayRemoteTransport?
    func set(_ transport: RelayRemoteTransport) { lock.lock(); value = transport; lock.unlock() }
    var transport: RelayRemoteTransport? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RelayNodeChannel?
    func set(_ channel: RelayNodeChannel) { lock.lock(); value = channel; lock.unlock() }
    var channel: RelayNodeChannel? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

@Suite(.serialized)
struct RelayNodeReconnectTests {
    private let profile = ConnectionProfile(name: "Reconnect fixture", host: "reconnect-node.invalid")

    private func attach(_ pool: RelayNodeTransportPool, _ session: String) -> RelayNodeChannel {
        pool.attach(profile: profile, sessionID: session, onReady: { _ in }, onFrame: { _ in }, onDisconnect: { _ in })
    }

    @Test("A pane joining a node as the pool evicts it lands on the pooled successor")
    func paneJoiningDuringEvictionUsesPooledNode() throws {
        let peers = PeerNodes()
        let pool = peers.pool()
        let leaving = attach(pool, "leaving-pane")
        let evicted = try #require(leaving.node)
        // The joining pane has looked up `evicted`; before it joins, the only
        // other pane closes, emptying the node and evicting it from the pool.
        let once = Once()
        pool.afterLookup = { node in if node === evicted, once.take() { leaving.close() } }
        let joining = attach(pool, "joining-pane")
        pool.afterLookup = nil
        defer { joining.close() }

        #expect(evicted.isRetired)
        let current = try #require(joining.node)
        #expect(current !== evicted, "the pane joined a node that had already left the pool")
        #expect(pool.incarnation(profile: profile) == current.incarnation)
        #expect(pool.cachedNodeCount == 1)
        try joining.write(type: .input, payload: Data("typed".utf8))
        let delivered = try #require(peers.nodes.last?.writer.frames.last.flatMap { RelayWireFrame.parseHostEvent($0) })
        #expect(delivered.sessionID == "joining-pane")
    }

    @Test("A host request racing the same eviction runs on the pooled successor")
    func requestDuringEvictionUsesPooledNode() async throws {
        let peers = PeerNodes()
        let pool = peers.pool()
        let leaving = attach(pool, "leaving-pane")
        let evicted = try #require(leaving.node)
        let once = Once()
        pool.afterLookup = { node in if node === evicted, once.take() { leaving.close() } }
        let payload = Data(#"{"request_id":"reconnect-race-1"}"#.utf8)
        // The fixture node advertises no host_rpc_v1, so an admitted request
        // completes at once as unsupported rather than waiting for a reply.
        await #expect(throws: RelayHostRPCError.unsupported) {
            _ = try await pool.request(profile: profile, payload: payload, timeoutSeconds: 2)
        }
        pool.afterLookup = nil
        #expect(evicted.isRetired)
        #expect(peers.nodes.count == 2)
    }

    @Test("An open channel keeps its node alive; closing it releases the node")
    func openChannelRetainsItsNode() throws {
        let writer = RecordingFrameWriter()
        weak var weakNode: RelayNodeConnection?
        var channel: RelayNodeChannel?
        do {
            let node = RelayNodeConnection(profile: profile, attachedFrameWriter: writer)
            weakNode = node
            channel = node.add(sessionID: "held-pane", onReady: { _ in }, onFrame: { _ in }, onDisconnect: { _ in })
        }
        #expect(weakNode != nil, "nothing but the pane referenced the node, and it was freed")
        try channel?.write(type: .input, payload: Data("still routed".utf8))
        #expect(writer.frames.count == 1)
        channel?.close()
        channel = nil
        #expect(weakNode == nil, "a closed channel must not keep its node")
    }

    @Test("A waiting pane left on a replaced node rejoins the pooled node")
    func waitingPaneRejoinsPooledNode() throws {
        // Nodes never become ready, so the pane stays unattached and waiting.
        let peers = PeerNodes(protocolReady: false)
        let pool = peers.pool()
        let transport = RelayRemoteTransport()
        transport.nodePool = pool
        transport.nodeRecoveryCheckMilliseconds = 50
        let statuses = RecordingFrameWriter()
        transport.start(profile: profile, sessionID: "waiting-pane", parentSessionID: nil,
            workspaceSessionID: nil, tabID: nil, paneTitle: "waiting", contentKind: "terminal",
            onOutput: { _, _, _ in },
            onStatus: { status, _ in statuses.writeAsync(type: .status, payload: Data((status.message ?? "").utf8)) },
            onAgentEvent: { _, _ in }, onArtifact: { _, _ in }, onDisconnect: { _, _ in })
        defer { transport.detach() }
        let original = try #require(peers.nodes.first?.node)
        #expect(original.networkSnapshot().attachedSubscriptions == 1)

        pool.abandonPooledNode(profile: profile)
        let deadline = Date().addingTimeInterval(3)
        while peers.nodes.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let replacement = try #require(peers.nodes.count == 2 ? peers.nodes[1].node : nil,
            "the waiting pane never left the abandoned node")
        #expect(replacement.networkSnapshot().attachedSubscriptions == 1)
        #expect(original.networkSnapshot().attachedSubscriptions == 0)
        #expect(pool.incarnation(profile: profile) == replacement.incarnation)
        #expect(statuses.frames.contains { String(decoding: $0.payload, as: UTF8.self).contains("rejoining") })
    }

    private static func startTransport(_ pool: RelayNodeTransportPool, _ session: String,
        profile: ConnectionProfile) -> RelayRemoteTransport {
        let transport = RelayRemoteTransport()
        transport.nodePool = pool
        transport.nodeRecoveryCheckMilliseconds = 50
        transport.start(profile: profile, sessionID: session, parentSessionID: nil,
            workspaceSessionID: nil, tabID: nil, paneTitle: session, contentKind: "terminal",
            onOutput: { _, _, _ in }, onStatus: { _, _ in }, onAgentEvent: { _, _ in },
            onArtifact: { _, _ in }, onDisconnect: { _, _ in })
        return transport
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }

    @Test("A pane detached while rejoining cannot displace its successor")
    func detachedRejoinLeavesSuccessorRegistered() throws {
        let peers = PeerNodes(protocolReady: false)
        let pool = peers.pool()
        let profile = profile
        let original = Self.startTransport(pool, "moving-pane", profile: profile)
        defer { original.detach() }
        pool.abandonPooledNode(profile: profile)
        // The old pane's recovery has looked up the new node; before it joins,
        // another pane joins that node (keeping it pooled, so no watchdog
        // would move a displaced pane), the old pane is detached and a
        // successor takes over the same session.
        let successor = SuccessorBox()
        let other = ChannelBox()
        let once = Once()
        pool.afterLookup = { _ in
            guard once.take() else { return }
            other.set(pool.attach(profile: profile, sessionID: "other-pane",
                onReady: { _ in }, onFrame: { _ in }, onDisconnect: { _ in }))
            original.detach()
            successor.set(Self.startTransport(pool, "moving-pane", profile: profile))
        }
        waitUntil { successor.transport?.currentNodeChannel != nil && peers.nodes.count == 2 }
        Thread.sleep(forTimeInterval: 0.3)
        pool.afterLookup = nil
        let replacement = try #require(successor.transport)
        defer { replacement.detach() }
        let otherChannel = try #require(other.channel)
        defer { otherChannel.close() }

        #expect(original.currentNodeChannel == nil)
        let channel = try #require(replacement.currentNodeChannel)
        let node = try #require(channel.node)
        #expect(node === peers.nodes.last?.node)
        #expect(node.isRegistered(channel), "the detached pane replaced its successor's route")
        #expect(node.isRegistered(otherChannel))
        #expect(node.networkSnapshot().attachedSubscriptions == 2)
        #expect(!pool.paneNeedsNewNode(channel, profile: profile))
    }

    @Test("A pane detached while rejoining never registers on the new node")
    func detachedRejoinRegistersNothing() throws {
        let peers = PeerNodes(protocolReady: false)
        let pool = peers.pool()
        let original = Self.startTransport(pool, "leaving-pane", profile: profile)
        pool.abandonPooledNode(profile: profile)
        let once = Once()
        pool.afterLookup = { _ in if once.take() { original.detach() } }
        waitUntil { peers.nodes.count == 2 }
        Thread.sleep(forTimeInterval: 0.3)
        pool.afterLookup = nil
        #expect(original.currentNodeChannel == nil)
        #expect(peers.nodes.last?.node.networkSnapshot().attachedSubscriptions == 0)
    }

    @Test("A waiting pane on the pooled node stays on it")
    func waitingPaneKeepsPooledNode() throws {
        let peers = PeerNodes(protocolReady: false)
        let pool = peers.pool()
        let transport = RelayRemoteTransport()
        transport.nodePool = pool
        transport.nodeRecoveryCheckMilliseconds = 50
        transport.start(profile: profile, sessionID: "patient-pane", parentSessionID: nil,
            workspaceSessionID: nil, tabID: nil, paneTitle: "patient", contentKind: "terminal",
            onOutput: { _, _, _ in }, onStatus: { _, _ in }, onAgentEvent: { _, _ in },
            onArtifact: { _, _ in }, onDisconnect: { _, _ in })
        defer { transport.detach() }
        Thread.sleep(forTimeInterval: 0.4)
        #expect(peers.nodes.count == 1)
        #expect(peers.nodes.first?.node.networkSnapshot().attachedSubscriptions == 1)
    }
}

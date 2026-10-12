import Foundation
import Testing
@testable import Relay

@Test func messagingIdentityReasonsAreSpecific() {
    #expect(NetworkParticipant.unresolvedStatus(isShell: true, connected: true, observed: true, fresh: true, matchCount: 0, sessionCount: 0) == .noAgent)
    #expect(NetworkParticipant.unresolvedStatus(isShell: false, connected: true, observed: false, fresh: false, matchCount: 0, sessionCount: 0) == .discovering)
    #expect(NetworkParticipant.unresolvedStatus(isShell: false, connected: true, observed: true, fresh: false, matchCount: 0, sessionCount: 0) == .stale)
    #expect(NetworkParticipant.unresolvedStatus(isShell: false, connected: true, observed: true, fresh: true, matchCount: 1, sessionCount: 2) == .duplicate)
    #expect(NetworkParticipant.unresolvedStatus(isShell: false, connected: true, observed: true, fresh: true, matchCount: 0, sessionCount: 0) == .unregistered)
    #expect(NetworkParticipant.unresolvedStatus(isShell: false, connected: false, observed: true, fresh: false, matchCount: 0, sessionCount: 0) == .offline)
    #expect(NetworkParticipant.unresolvedStatus(isShell: true, connected: true, observed: true, fresh: true, matchCount: 1, sessionCount: 1) == nil)
}

@Test("Local pane identity binds only the exact foreground process")
func localPeerPaneBinding() {
    let matching = DiscoveredPeer(name: "Claude Code", sessionId: "claude-session", pid: 412,
        procStart: "98765", paneID: "pane-a")
    let other = DiscoveredPeer(name: "Claude Code", sessionId: "other-session", pid: 413,
        procStart: "98766")
    let child = DiscoveredPeer(name: "child", sessionId: "child-session", pid: 412,
        procStart: "98765", parentSession: "claude-session")
    #expect(NetworkParticipant.localPeersForPane([matching, other, child], paneID: "PANE-A", foregroundPID: nil).map(\.sessionId) == ["claude-session"])
    #expect(NetworkParticipant.localPeersForPane([matching], paneID: "pane-b", foregroundPID: 412).isEmpty)
    let direct = DiscoveredPeer(name: "Claude Code", sessionId: "direct", pid: 412, procStart: "98765")
    #expect(NetworkParticipant.localPeersForPane([direct], paneID: "pane-a", foregroundPID: 412).map(\.sessionId) == ["direct"])
    #expect(NetworkParticipant.localPeersForPane([direct], paneID: "pane-a", foregroundPID: nil).isEmpty)
}

@Test("Network participants merge links by host and session, never display name")
func networkParticipantIdentity() throws {
    let data = Data(#"{"schema":1,"pid":123,"host":"test","localName":"same","localSession":"a","remoteName":"same","remoteSession":"a","state":"online","updatedAt":"2026-09-20T10:00:00Z","attempt":0,"rttMillis":1}"#.utf8)
    let link = try JSONDecoder().decode(PeerNetworkStatus.self, from: data)
    let peers = NetworkParticipant.collect(local: [DiscoveredPeer(name: "same", sessionId: "a", pid: 1), DiscoveredPeer(name: "unlinked", sessionId: "b", pid: 2)], links: [link])
    #expect(peers.count == 3)
    #expect(peers.filter { $0.name == "same" }.count == 2)
    #expect(peers.first { $0.id.local && $0.id.session == "a" }?.discovered == true)
    #expect(peers.first { !$0.id.local }?.discovered == false)
    #expect(peers.first { $0.name == "unlinked" }?.links.isEmpty == true)
}

@Test("Network map orders agents beneath their owning session within each peer")
func networkMapHierarchy() {
    let host = "remote-a"
    let first = NetworkParticipant.Identity(host: host, session: "session-a", local: false)
    let second = NetworkParticipant.Identity(host: host, session: "session-b", local: false)
    var agent = NetworkParticipant(id: .init(host: host, session: "agent-a", local: false), name: "Worker")
    agent.parentID = first
    let unrelated = NetworkParticipant(id: .init(host: "remote-b", session: "session-c", local: false), name: "Other")
    let ordered = NetworkParticipant.orderedForMap([
        agent, NetworkParticipant(id: second, name: "B"), unrelated,
        NetworkParticipant(id: first, name: "A")
    ], host: host)
    #expect(ordered.map(\.id) == [first, agent.id, second])
}

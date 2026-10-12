import Testing
import Foundation
@testable import Relay

@Test("Claude metadata is optional and bounded independently of peers")
func claudeDiscoveryMetadataValidation() throws {
    let json = #"{"peers":[],"truncated":false,"teams":[{"name":"team","leadSessionId":"lead","members":[{"agentId":"worker@team","name":"worker","agentType":"Explore"}]}]}"#
    let value = try PeerDiscovery.decodeValidated(Data(json.utf8))
    #expect(value.teams?.first?.members.first?.agentId == "worker@team")
    #expect(value.peers.isEmpty)
    let bad = json.replacingOccurrences(of: "worker@team", with: "worker\\u001b")
    #expect(throws: (any Error).self) { try PeerDiscovery.decodeValidated(Data(bad.utf8)) }
}

@Test("Reported links reject stale, missing and ambiguous endpoints")
func reportedPeerLinkFreshness() {
    let now = Date(timeIntervalSince1970: 100)
    let peers = [DiscoveredPeer(name: "a", sessionId: "a", pid: 1), DiscoveredPeer(name: "b", sessionId: "b", pid: 2)]
    let report = ReportedPeerLink(sourcePID: 1, sourceSession: "a", destinationPID: 2, destinationSession: "b", updatedMs: 100000)
    #expect(report.isCurrent(peers: peers, now: now))
    #expect(!report.isCurrent(peers: peers, now: now.addingTimeInterval(31)))
    #expect(!report.isCurrent(peers: peers, now: now.addingTimeInterval(-6)))
    #expect(!report.isCurrent(peers: Array(peers.prefix(1)), now: now))
    #expect(!report.isCurrent(peers: peers + [DiscoveredPeer(name: "resumed", sessionId: "b", pid: 3)], now: now))
}

@Test("Active discovery excludes expired and future observations")
func peerDiscoveryFreshness() {
    let now = Date(timeIntervalSince1970: 100)
    #expect(!PeerDiscovery.isFresh(nil, now: now))
    #expect(PeerDiscovery.isFresh(now, now: now))
    #expect(PeerDiscovery.isFresh(now.addingTimeInterval(-30), now: now))
    #expect(!PeerDiscovery.isFresh(now.addingTimeInterval(-31), now: now))
    #expect(!PeerDiscovery.isFresh(now.addingTimeInterval(6), now: now))
}

@Test("Remote registry discovery adds participants without inventing edges")
func remoteDiscoveryDoesNotInferLinks() {
    let discovery = PeerDiscovery(peers: [DiscoveredPeer(name: "same-name", sessionId: "s", pid: 1)], truncated: false)
    let peers = NetworkParticipant.collect(local: discovery.peers, links: [], remote: ["host-a": discovery, "host-b": discovery])
    #expect(peers.count == 3)
    #expect(peers.allSatisfy { $0.links.isEmpty })
    #expect(Set(peers.map(\.id)).count == 3)
}

@Test("Native group metadata stays distinct from transport links")
func nativeGroupDiscoveryMetadata() throws {
    let json = #"{"peers":[],"truncated":false,"links":[],"groups":[{"id":"cbed3fa0-1d8f-4ee8-b586-ba9ab6da5c6a","topology":"everyone","participants":[{"host":"dandy-07","session":"session-a","name":"agent-a","pid":10,"processStart":"100"},{"host":"dandy-07","session":"session-b","name":"agent-b","pid":11,"processStart":"101"}],"current":true}]}"#
    let discovery = try PeerDiscovery.decodeValidated(Data(json.utf8))
    #expect(discovery.groups?.count == 1)
    #expect(discovery.links?.isEmpty == true)
    #expect(discovery.groups?.first?.participants.map(\.pid) == [10, 11])
    let bad = json.replacingOccurrences(of: "agent-b", with: "agent b")
    #expect(throws: (any Error).self) { try PeerDiscovery.decodeValidated(Data(bad.utf8)) }
}

@Test("Peer discovery requires explicit safe SSH target and noninteractive authentication")
func peerDiscoveryRemoteArguments() throws {
    let args = try PeerDiscovery.remoteArguments(host: "dandy-07", helper: ".local/bin/relay-peer-link")
    #expect(args.contains("BatchMode=yes"))
    #expect(args.contains("StrictHostKeyChecking=yes"))
    #expect(args.last == "exec '.local/bin/relay-peer-link' --discover")
    for host in ["", "-oProxyCommand=x", "host;command", "user@host"] {
        #expect(throws: (any Error).self) {
            try PeerDiscovery.remoteArguments(host: host, helper: ".local/bin/relay-peer-link")
        }
    }
    for helper in ["", "-bad", "$(command)", "path with spaces", "bad'path"] {
        #expect(throws: (any Error).self) {
            try PeerDiscovery.remoteArguments(host: "dandy-07", helper: helper)
        }
    }
}

@Test("Peer discovery rejects malformed identities and duplicate process targets")
func peerDiscoveryValidation() throws {
    func payload(_ peers: [DiscoveredPeer], truncated: Bool = false) throws -> Data {
        try JSONEncoder().encode(PeerDiscovery(peers: peers, truncated: truncated))
    }
    let valid = DiscoveredPeer(name: "dandy-07--claude_1", sessionId: "session-123", pid: 42)
    #expect(try PeerDiscovery.decodeValidated(payload([valid], truncated: true)).truncated)
    #expect(try PeerDiscovery.decodeValidated(payload([])).peers.isEmpty)
    for bad in ["", "name\n", "name\u{1b}[31m", "a b", "a/b", "é", String(repeating: "a", count: 111)] {
        for peer in [DiscoveredPeer(name: bad, sessionId: "ok", pid: 42),
                     DiscoveredPeer(name: "ok", sessionId: bad, pid: 42)] {
            #expect(throws: (any Error).self) { try PeerDiscovery.decodeValidated(payload([peer])) }
        }
    }
    for peers in [[valid, valid], [DiscoveredPeer(name: "ok", sessionId: "ok", pid: 0)],
                  [DiscoveredPeer(name: "ok", sessionId: "ok", pid: Int(Int32.max) + 1)]] {
        #expect(throws: (any Error).self) { try PeerDiscovery.decodeValidated(payload(peers)) }
    }
    #expect(throws: (any Error).self) { try PeerDiscovery.decodeValidated(Data(repeating: 32, count: 262_145)) }
}

@Test("Local discovery adds pane ownership only from an exact daemon process incarnation")
func localDiscoveryMergesVerifiedPaneOwner() {
    let rawPeer = DiscoveredPeer(name: "claude", sessionId: "session-a", pid: 42, procStart: "start-a")
    let stalePaneRecord = DiscoveredPeer(name: "claude", sessionId: "session-a", pid: 42,
        procStart: "reused", paneID: "pane-stale")
    let verifiedPaneRecord = DiscoveredPeer(name: "claude", sessionId: "session-a", pid: 42,
        procStart: "start-a", paneID: "pane-a")
    let raw = PeerDiscovery(peers: [rawPeer], truncated: false)
    let stale = PeerDiscovery.mergeLocal(raw: raw, paneBound: PeerDiscovery(peers: [stalePaneRecord], truncated: false))
    #expect(stale.peers.first?.paneID == nil)
    let merged = PeerDiscovery.mergeLocal(raw: raw, paneBound: PeerDiscovery(peers: [verifiedPaneRecord], truncated: false))
    #expect(merged.peers.first?.paneID == "pane-a")
    #expect(merged.peers.first?.procStart == "start-a")
}

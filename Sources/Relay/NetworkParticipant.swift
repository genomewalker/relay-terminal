import Foundation

/// Session identities are scoped to their host, never merged by display name.
struct NetworkParticipant: Identifiable {
    struct Identity: Hashable { let host: String; let session: String; let local: Bool }
    let id: Identity
    var name: String
    var discovered = false
    var boundPeer: DiscoveredPeer? = nil

    static func peersForPane(_ peers: [DiscoveredPeer], paneID: String, roots: [String]) -> [DiscoveredPeer] {
        peers.filter { peer in
            guard peer.parentSession == nil, let start = peer.procStart, !start.isEmpty, start != "0" else { return false }
            if let owner = peer.paneID { return owner == paneID }
            return matchesProcess(peer, roots: roots)
        }
    }

    /// Prefer relayd's verified pane ancestry. Direct Ghostty panes do not have
    /// daemon workers, so their fallback is an exact foreground PID match.
    static func localPeersForPane(_ peers: [DiscoveredPeer], paneID: String, foregroundPID: pid_t?) -> [DiscoveredPeer] {
        return peers.filter { peer in
            guard peer.parentSession == nil,
                  peer.procStart.map({ !$0.isEmpty && $0 != "0" }) == true else { return false }
            if let owner = peer.paneID { return owner.caseInsensitiveCompare(paneID) == .orderedSame }
            guard let foregroundPID, foregroundPID > 0 else { return false }
            return peer.pid == Int(foregroundPID)
        }
    }

    enum IdentityStatus: String {
        case noAgent = "No messaging agent"
        case discovering = "Discovering messaging identity"
        case stale = "Discovery unavailable"
        case duplicate = "Duplicate identity"
        case unregistered = "Messaging not registered"
        case offline = "Host disconnected"
        var explanation: String {
            switch self {
            case .noAgent: return "This is a shell, not a registered messaging agent."
            case .discovering: return "Waiting for the first verified messaging inventory from this host."
            case .stale: return "The last discovery is no longer current. Wait for discovery to recover; no address will be guessed."
            case .duplicate: return "More than one live record matches this pane or shares its session ID. Linking is blocked until the identity is unique."
            case .unregistered: return "An agent is visible, but the current messaging inventory has no unique record bound to this pane."
            case .offline: return "Reconnect this host before verifying its messaging identity."
            }
        }
    }
    var identityStatus: IdentityStatus? = nil

    static func unresolvedStatus(isShell: Bool, connected: Bool, observed: Bool, fresh: Bool, matchCount: Int, sessionCount: Int) -> IdentityStatus? {
        if matchCount > 1 || sessionCount > 1 { return .duplicate }
        if matchCount == 1 && sessionCount == 1 && fresh { return nil }
        if isShell { return .noAgent }
        if !connected { return .offline }
        if !observed { return .discovering }
        if !fresh { return .stale }
        return .unregistered
    }

    func messagingLabel(now: Date) -> String {
        if let identityStatus { return identityStatus.rawValue }
        if links.contains(where: { $0.displayState(now: now) == "Connected" }) { return "Messaging connected" }
        return discovered ? "No messaging link" : "Messaging not registered"
    }
    var links: [PeerNetworkStatus] = []
    var parentID: Identity? = nil
    var paneID: UUID? = nil
    var activity: String? = nil
    var externalEndpoint = false
    var directory: String? = nil
    var tabName: String? = nil
    var provider: String? = nil
    var lastEvent: String? = nil
    var lastEventAt: Date? = nil
    var lastTurnAt: Date? = nil
    var taskState: String? = nil

    /// Keep each relayd node's sessions together with their observed agents.
    /// Orphaned child records remain visible, but are never promoted to sessions.
    static func orderedForMap(_ participants: [Self], host: String) -> [Self] {
        let hosted = participants.filter { $0.id.host == host }
        let sessions = hosted.filter { $0.parentID == nil }
            .sorted { ($0.name, $0.id.session) < ($1.name, $1.id.session) }
        let agents = hosted.filter { $0.parentID != nil }
            .sorted { ($0.name, $0.id.session) < ($1.name, $1.id.session) }
        let children = Dictionary(grouping: agents, by: { $0.parentID! })
        let owned = Set(sessions.map(\.id))
        return sessions.flatMap { [$0] + (children[$0.id] ?? []) } + agents.filter { !owned.contains($0.parentID!) }
    }

    /// One-hop boundary only: never expand into the host-wide registry.
    static func withBoundaryEndpoints(_ scoped: [Self], links: [PeerNetworkStatus]) -> [Self] {
        let owned = Set(scoped.map(\.id))
        var result = scoped
        for link in links where owned.contains(link.sourceIdentity) || owned.contains(link.destinationIdentity) {
            for (id, name) in [(link.sourceIdentity, link.localName), (link.destinationIdentity, link.remoteName)] where !owned.contains(id) {
                if let index = result.firstIndex(where: { $0.id == id }) {
                    if !result[index].links.contains(where: { $0.id == link.id }) { result[index].links.append(link) }
                } else {
                    var endpoint = Self(id: id, name: name, links: [link])
                    endpoint.externalEndpoint = true
                    result.append(endpoint)
                }
            }
        }
        return result
    }

    /// Keep the exact endpoints of configured links visible even when neither
    /// endpoint can be bound to a Relay pane. This is intentionally limited to
    /// identities carried by the link receipts; it never imports the rest of a
    /// host discovery result or guesses a pane association.
    static func withActiveLinkEndpoints(_ panes: [Self], links: [PeerNetworkStatus]) -> [Self] {
        var result = panes
        let linkedIDs = Set(links.flatMap { [$0.sourceIdentity, $0.destinationIdentity] })
        for link in links {
            for (id, name) in [(link.sourceIdentity, link.localName), (link.destinationIdentity, link.remoteName)] {
                if let index = result.firstIndex(where: { $0.id == id }) {
                    if !result[index].links.contains(where: { $0.id == link.id }) {
                        result[index].links.append(link)
                    }
                } else {
                    var endpoint = Self(id: id, name: name, links: [link])
                    endpoint.externalEndpoint = true
                    result.append(endpoint)
                }
            }
        }
        return result.sorted {
            ($0.id.host, linkedIDs.contains($0.id) ? 0 : 1, $0.name, $0.id.session) <
            ($1.id.host, linkedIDs.contains($1.id) ? 0 : 1, $1.name, $1.id.session)
        }
    }

    static func matchesProcess(_ peer: DiscoveredPeer, roots: [String]) -> Bool {
        guard let start = peer.procStart, start != "0" else { return false }
        return roots.contains { root in
            let parts = root.split(separator: ":")
            return parts.count == 3 && Int(parts[1]) == peer.pid && String(parts[2]) == start
        }
    }

    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let fields = [name, id.host, id.session, directory ?? "", tabName ?? "", provider ?? ""]
        return words.allSatisfy { word in
            fields.contains { $0.localizedCaseInsensitiveContains(String(word)) }
        }
    }

    /// Last-known inspection survives a missing record; absence is not termination.
    static func resolveSelection(_ id: Identity?, current: [Self], previous: Self?) -> Self? {
        guard let id else { return nil }
        return current.first { $0.id == id } ?? (previous?.id == id ? previous : nil)
    }

    static func collect(local: [DiscoveredPeer], links: [PeerNetworkStatus], remote: [String: PeerDiscovery] = [:]) -> [Self] {
        var result: [Identity: Self] = [:]
        for peer in local {
            let id = Identity(host: "This Mac", session: peer.sessionId, local: true)
            result[id] = Self(id: id, name: peer.name, discovered: true)
        }
        for (host, discovery) in remote {
            for peer in discovery.peers {
                let id = Identity(host: host, session: peer.sessionId, local: false)
                result[id] = Self(id: id, name: peer.name, discovered: true)
            }
        }
        for link in links {
            for (id, name) in [
                (link.sourceIdentity, link.localName),
                (link.destinationIdentity, link.remoteName)
            ] {
                var participant = result[id] ?? Self(id: id, name: name)
                participant.links.append(link)
                result[id] = participant
            }
        }
        return result.values.sorted { ($0.id.host, $0.name, $0.id.session) < ($1.id.host, $1.name, $1.id.session) }
    }
}

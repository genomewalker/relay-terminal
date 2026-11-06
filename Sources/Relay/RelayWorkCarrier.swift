import Foundation

/// Carries Work-link messages between this app's relayd hosts over the host
/// channel the app already holds, for routes whose peer binding names the Relay
/// host channel. relayd signs every envelope with its pinned node key and the
/// receiving relayd verifies it, so this carrier can delay or drop a message
/// but cannot forge, alter or redirect one. A claim never returns the text
/// twice: after the first dispatch every claim is a signed receipt query.
enum RelayWorkCarrier {
    struct Item: Equatable {
        let messageID: String
        let peerNodeID: String
    }

    struct Outbox: Equatable {
        let hostKey: String
        let nodeID: String
        let items: [Item]
    }

    struct Step: Equatable {
        let fromHost: String
        let toHost: String
        let messageID: String
    }

    static var pendingPacket: [String: Any] { ["operation": "work_native_pending"] }

    static func claimPacket(messageID: String) -> [String: Any] {
        ["operation": "work_native_claim", "message_id": messageID]
    }

    static func deliverPacket(envelope: String) -> [String: Any] {
        ["operation": "deliver_signed_work", "work_envelope": envelope]
    }

    static func settlePacket(messageID: String, reply: String) -> [String: Any] {
        ["operation": "work_native_settle", "message_id": messageID, "work_reply": reply]
    }

    static func outbox(hostKey: String, reply: [String: Any]?) -> Outbox? {
        guard let reply, let node = reply["node_id"] as? String, !node.isEmpty,
              let raw = reply["items"] as? [[String: Any]] else { return nil }
        let items = raw.compactMap { item -> Item? in
            guard let id = item["message_id"] as? String, let peer = item["peer_node_id"] as? String,
                  !id.isEmpty, !peer.isEmpty else { return nil }
            return Item(messageID: id, peerNodeID: peer)
        }
        return Outbox(hostKey: hostKey, nodeID: node, items: items)
    }

    /// Pairs each pending item with the connected host whose relayd reports the
    /// peer node. An item whose peer is not connected, is this host itself, or
    /// is reported by more than one host waits for a later pass.
    static func plan(_ outboxes: [Outbox]) -> [Step] {
        var hostsByNode: [String: [String]] = [:]
        for box in outboxes { hostsByNode[box.nodeID, default: []].append(box.hostKey) }
        var steps: [Step] = []
        for box in outboxes {
            for item in box.items where item.peerNodeID != box.nodeID {
                guard let hosts = hostsByNode[item.peerNodeID], hosts.count == 1, hosts[0] != box.hostKey else { continue }
                steps.append(Step(fromHost: box.hostKey, toHost: hosts[0], messageID: item.messageID))
            }
        }
        return steps
    }

    /// 5 s while a host has queued Work messages, 30 s otherwise. A send made
    /// while the carrier idles waits at most one quiet interval.
    static func interval(pending: Bool) -> Duration {
        pending ? .seconds(5) : .seconds(30)
    }
}

@MainActor final class RelayWorkCarrierLoop {
    private weak var workspace: WorkspaceModel?
    private var task: Task<Void, Never>?

    init(workspace: WorkspaceModel?) {
        self.workspace = workspace
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let workspace = self.workspace else { return }
                let pending = await self.tick(workspace)
                try? await Task.sleep(for: RelayWorkCarrier.interval(pending: pending))
            }
        }
    }

    /// One pass. Every failure leaves relayd's records as they were; the next
    /// pass claims again, which yields a receipt query and never a resend.
    func tick(_ workspace: WorkspaceModel) async -> Bool {
        var seen: Set<String> = []
        let profiles = workspace.panes.values.map(\.profile).filter { $0.backend == .relay && seen.insert($0.connectionKey).inserted }
        guard profiles.count > 1 else { return false }
        var byKey: [String: ConnectionProfile] = [:]
        var outboxes: [RelayWorkCarrier.Outbox] = []
        for profile in profiles {
            byKey[profile.connectionKey] = profile
            let reply = try? await RelayPaneMessaging.shared.daemonRequest(profile: profile, packet: RelayWorkCarrier.pendingPacket, attach: false)
            if let box = RelayWorkCarrier.outbox(hostKey: profile.connectionKey, reply: reply) { outboxes.append(box) }
        }
        let steps = RelayWorkCarrier.plan(outboxes)
        for step in steps {
            guard let from = byKey[step.fromHost], let to = byKey[step.toHost] else { continue }
            guard let claim = try? await RelayPaneMessaging.shared.daemonRequest(profile: from, packet: RelayWorkCarrier.claimPacket(messageID: step.messageID), attach: false),
                  let envelope = claim["work_envelope"] as? String,
                  let delivered = try? await RelayPaneMessaging.shared.daemonRequest(profile: to, packet: RelayWorkCarrier.deliverPacket(envelope: envelope), attach: false),
                  let reply = delivered["work_reply"] as? String else { continue }
            _ = try? await RelayPaneMessaging.shared.daemonRequest(profile: from, packet: RelayWorkCarrier.settlePacket(messageID: step.messageID, reply: reply), attach: false)
        }
        return outboxes.contains { !$0.items.isEmpty }
    }
}

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
        var nativeRoutes = 0
    }

    struct Step: Equatable {
        let fromHost: String
        let toHost: String
        let messageID: String
    }

    static var pendingPacket: [String: Any] { ["operation": "work_native_pending"] }

    static let carrierOperations: Set<String> = ["work_native_pending", "work_native_claim", "deliver_signed_work", "work_native_settle"]

    static func carries(_ packet: [String: Any]) -> Bool {
        (packet["operation"] as? String).map(carrierOperations.contains) ?? false
    }

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
        return Outbox(hostKey: hostKey, nodeID: node, items: items, nativeRoutes: reply["native_routes"] as? Int ?? 0)
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

    static let tick: Duration = .seconds(5)

    /// When a host is checked next: 5 s while it has queued Work messages, 30 s
    /// while it has a host-channel route, and every 10 min when it has none,
    /// so the carrier costs nothing until a link is switched to this route.
    /// A host that did not answer is retried after 30 s if it last reported a
    /// host-channel route, and after 10 min otherwise (for example a host
    /// without the Work helper).
    static func nextCheck(after box: Outbox?, previous: Outbox? = nil) -> TimeInterval {
        guard let box else { return (previous?.nativeRoutes ?? 0) > 0 ? 30 : 600 }
        if !box.items.isEmpty { return 5 }
        return box.nativeRoutes > 0 ? 30 : 600
    }
}

@MainActor final class RelayWorkCarrierLoop {
    private weak var workspace: WorkspaceModel?
    private var task: Task<Void, Never>?
    private var outboxes: [String: RelayWorkCarrier.Outbox] = [:]
    private var due: [String: Date] = [:]
    private var known: [String: RelayWorkCarrier.Outbox] = [:]

    init(workspace: WorkspaceModel?) {
        self.workspace = workspace
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let workspace = self.workspace else { return }
                await self.tick(workspace)
                try? await Task.sleep(for: RelayWorkCarrier.tick)
            }
        }
    }

    /// One pass over the hosts that are due. Every failure leaves relayd's
    /// records as they were; the next claim yields a receipt query, never a
    /// resend.
    func tick(_ workspace: WorkspaceModel, now: Date = Date()) async {
        var seen: Set<String> = []
        let profiles = workspace.panes.values.map(\.profile).filter { $0.backend == .relay && seen.insert($0.connectionKey).inserted }
        let keys = Set(profiles.map(\.connectionKey))
        outboxes = outboxes.filter { keys.contains($0.key) }
        due = due.filter { keys.contains($0.key) }
        known = known.filter { keys.contains($0.key) }
        guard profiles.count > 1 else { return }
        var byKey: [String: ConnectionProfile] = [:]
        for profile in profiles {
            let key = profile.connectionKey
            byKey[key] = profile
            guard now >= due[key] ?? .distantPast else { continue }
            let reply = try? await RelayPaneMessaging.shared.daemonRequest(profile: profile, packet: RelayWorkCarrier.pendingPacket, attach: false)
            let box = RelayWorkCarrier.outbox(hostKey: key, reply: reply)
            due[key] = now.addingTimeInterval(RelayWorkCarrier.nextCheck(after: box, previous: known[key]))
            if let box { known[key] = box }
            outboxes[key] = box
        }
        for step in RelayWorkCarrier.plan(Array(outboxes.values)) {
            guard let from = byKey[step.fromHost], let to = byKey[step.toHost] else { continue }
            guard let claim = try? await RelayPaneMessaging.shared.daemonRequest(profile: from, packet: RelayWorkCarrier.claimPacket(messageID: step.messageID), attach: false),
                  let envelope = claim["work_envelope"] as? String,
                  let delivered = try? await RelayPaneMessaging.shared.daemonRequest(profile: to, packet: RelayWorkCarrier.deliverPacket(envelope: envelope), attach: false),
                  let reply = delivered["work_reply"] as? String else { continue }
            _ = try? await RelayPaneMessaging.shared.daemonRequest(profile: from, packet: RelayWorkCarrier.settlePacket(messageID: step.messageID, reply: reply), attach: false)
        }
        // A carried item is gone from the cached outbox until its host is
        // checked again; drop the cache so one envelope is not re-claimed
        // within the same quiet interval.
        for key in outboxes.keys where !(outboxes[key]?.items.isEmpty ?? true) {
            outboxes[key] = nil
            due[key] = now.addingTimeInterval(5)
        }
    }
}

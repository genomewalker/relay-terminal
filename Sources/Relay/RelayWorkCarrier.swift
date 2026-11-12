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

    static let carrierOperations: Set<String> = ["work_native_pending", "work_native_claim", "deliver_signed_work", "work_native_settle", "work_native_refused"]

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

    static func refusedPacket(messageID: String, reason: String) -> [String: Any] {
        ["operation": "work_native_refused", "message_id": messageID, "work_refusal": reason]
    }

    /// The reason the peer's relayd gave for refusing a signed delivery, or nil
    /// when the peer could not be reached at all: only an answer from the
    /// peer's relayd is reported to the sender as a refusal.
    static func refusal(_ error: Error) -> String? {
        guard case RemoteCatalogError.failed(let message) = error else { return nil }
        let line = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(300))
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

    /// Retry delays after a failed check or a drop to zero routes, each well
    /// under the 9-minute signed window (remoteNativeSignedWindow).
    static let failureBackoff: [TimeInterval] = [30, 60, 120, 240]

    /// What the carrier last learned about one host. In memory only, so empty
    /// after an app restart.
    struct HostSchedule: Equatable {
        /// Host-channel routes in the last answer; nil before any answer.
        var routes: Int?
        /// Consecutive failed checks or settling checks after a route drop.
        var retries = 0
    }

    /// When a host is checked next: 5 s while it has queued Work messages, 30 s
    /// while it has a host-channel route, and every 10 min when it has none,
    /// so the carrier costs nothing until a link is switched to this route.
    /// A check that failed is retried after 30, 60, 120 and then every 240 s,
    /// never 600 s: a message queued on that host must be carried inside its
    /// signed window. An answer of zero routes after routes (or after a
    /// failure, or as the first answer since launch) is treated the same way,
    /// since a supervisor swap can briefly report none; only a host that keeps
    /// reporting zero through the backoff settles to the idle 600 s.
    static func nextCheck(after box: Outbox?, state: inout HostSchedule) -> TimeInterval {
        guard let box else {
            defer { state.retries += 1 }
            return failureBackoff[min(state.retries, failureBackoff.count - 1)]
        }
        if !box.items.isEmpty || box.nativeRoutes > 0 {
            state = HostSchedule(routes: box.nativeRoutes)
            return box.items.isEmpty ? 30 : 5
        }
        // The first 0-route answer after routes, or after failures with no
        // earlier answer, restarts the backoff: failures may have used it up
        // while relayd was down, and 600 s would outlast the signed window.
        if state.routes != 0 { state.retries = 0 }
        let settled = state.routes == 0 && state.retries == 0
        if !settled, state.retries < failureBackoff.count {
            defer { state.retries += 1 }
            state.routes = 0
            return failureBackoff[state.retries]
        }
        state = HostSchedule(routes: 0)
        return 600
    }

    /// Posted when a pane on a host attaches or catches up, so the carrier
    /// checks that host now instead of at its scheduled time.
    static let hostReadyNotification = Notification.Name("RelayWorkCarrier.hostReady")

    @MainActor static func hostReady(_ profile: ConnectionProfile) {
        guard profile.backend == .relay else { return }
        NotificationCenter.default.post(name: hostReadyNotification, object: nil, userInfo: ["key": profile.connectionKey])
    }

    /// Work tools whose completed call means the pane's relayd has just queued
    /// a message for this carrier (a send, or a send whose receipt it reads).
    static let workSendTools: Set<String> = ["relay_work_message", "relay_work_send_file"]

    /// A provider's PostToolUse for a Work send, by bare or MCP-qualified name
    /// (mcp__relay-work__relay_work_message).
    static func queuedWork(eventName: String, toolName: String?) -> Bool {
        guard eventName == "PostToolUse", let toolName, !toolName.isEmpty else { return false }
        let bare = toolName.components(separatedBy: "__").last ?? toolName
        return workSendTools.contains(bare)
    }

    /// Posted when a pane on a host has just sent a Work message, so the
    /// carrier checks that host at once instead of on its next scheduled pass.
    static let workQueuedNotification = Notification.Name("RelayWorkCarrier.workQueued")

    @MainActor static func workQueued(_ profile: ConnectionProfile) {
        guard profile.backend == .relay else { return }
        NotificationCenter.default.post(name: workQueuedNotification, object: nil, userInfo: ["key": profile.connectionKey])
    }
}

@MainActor final class RelayWorkCarrierLoop {
    typealias Request = @MainActor (ConnectionProfile, [String: Any]) async throws -> [String: Any]

    private weak var workspace: WorkspaceModel?
    private let request: Request
    private var task: Task<Void, Never>?
    private var outboxes: [String: RelayWorkCarrier.Outbox] = [:]
    private var due: [String: Date] = [:]
    private var schedules: [String: RelayWorkCarrier.HostSchedule] = [:]
    nonisolated(unsafe) private var readyObserver: NSObjectProtocol?
    nonisolated(unsafe) private var queuedObserver: NSObjectProtocol?
    private var wakeup: CheckedContinuation<Void, Never>?
    private var wakePending = false
    private var pauseGeneration = 0

    init(workspace: WorkspaceModel?, request: Request? = nil) {
        self.workspace = workspace
        self.request = request ?? { profile, packet in
            try await RelayPaneMessaging.shared.daemonRequest(profile: profile, packet: packet, attach: false)
        }
        readyObserver = NotificationCenter.default.addObserver(forName: RelayWorkCarrier.hostReadyNotification, object: nil, queue: nil) { [weak self] note in
            guard let key = note.userInfo?["key"] as? String else { return }
            MainActor.assumeIsolated { self?.hostReady(key) }
        }
        queuedObserver = NotificationCenter.default.addObserver(forName: RelayWorkCarrier.workQueuedNotification, object: nil, queue: nil) { [weak self] note in
            guard let key = note.userInfo?["key"] as? String else { return }
            MainActor.assumeIsolated { self?.workQueued(key) }
        }
    }

    deinit {
        if let readyObserver { NotificationCenter.default.removeObserver(readyObserver) }
        if let queuedObserver { NotificationCenter.default.removeObserver(queuedObserver) }
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let workspace = self.workspace else { return }
                await self.tick(workspace)
                await self.pause(RelayWorkCarrier.tick)
            }
        }
    }

    /// Sleeps between passes; wake() ends the sleep at once. A wake that
    /// arrives during a pass makes the next pause return immediately.
    func pause(_ duration: Duration) async {
        if wakePending {
            wakePending = false
            return
        }
        pauseGeneration &+= 1
        let generation = pauseGeneration
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wakeup = continuation
            Task { @MainActor [self] in
                try? await Task.sleep(for: duration)
                guard pauseGeneration == generation, let pending = wakeup else { return }
                wakeup = nil
                pending.resume()
            }
        }
    }

    func wake() {
        if let pending = wakeup {
            wakeup = nil
            pending.resume()
        } else {
            wakePending = true
        }
    }

    /// A pane on this host has just sent a Work message: its relayd queued it
    /// for this carrier, so check the host now. Unlike a reattach, what was
    /// learned about the host still holds, so its schedule is kept.
    func workQueued(_ key: String) {
        due[key] = nil
        wake()
    }

    /// The last failure logged per message, so a stuck message is logged once
    /// per reason rather than on every pass. In memory only.
    private(set) var noted: [String: String] = [:]

    private func note(_ step: RelayWorkCarrier.Step, _ name: String, _ reason: String) {
        let key = name + ": " + reason
        guard noted[step.messageID] != key else { return }
        if noted.count >= 256 { noted.removeAll() }
        noted[step.messageID] = key
        RelayDiagnostics.shared.record(category: "work_carrier", name: name, details: [
            "message_id": step.messageID, "from": step.fromHost, "to": step.toHost, "reason": reason,
        ])
    }

    private func reportRefusal(_ step: RelayWorkCarrier.Step, from: ConnectionProfile, reason: String) async {
        do {
            _ = try await request(from, RelayWorkCarrier.refusedPacket(messageID: step.messageID, reason: reason))
        } catch {
            note(step, "refusal_not_recorded", RelayWorkCarrier.refusal(error) ?? error.localizedDescription)
        }
    }

    /// A pane on this host attached or caught up: its relayd (or supervisor)
    /// may have just come back, so check it on the next pass.
    func hostReady(_ key: String) {
        due[key] = nil
        // Its relayd may have restarted, so what was known about it no longer
        // holds: a 0-route answer starts the short backoff again.
        schedules[key] = nil
    }

    func tick(_ workspace: WorkspaceModel, now: Date = Date()) async {
        await tick(profiles: workspace.panes.values.map(\.profile), now: now)
    }

    /// One pass over the hosts that are due. Every failure leaves relayd's
    /// records as they were; the next claim yields a receipt query, never a
    /// resend.
    func tick(profiles all: [ConnectionProfile], now: Date = Date()) async {
        var seen: Set<String> = []
        let profiles = all.filter { $0.backend == .relay && seen.insert($0.connectionKey).inserted }
        let keys = Set(profiles.map(\.connectionKey))
        outboxes = outboxes.filter { keys.contains($0.key) }
        due = due.filter { keys.contains($0.key) }
        schedules = schedules.filter { keys.contains($0.key) }
        guard profiles.count > 1 else { return }
        var byKey: [String: ConnectionProfile] = [:]
        for profile in profiles {
            let key = profile.connectionKey
            byKey[key] = profile
            guard now >= due[key] ?? .distantPast else { continue }
            let reply = try? await request(profile, RelayWorkCarrier.pendingPacket)
            let box = RelayWorkCarrier.outbox(hostKey: key, reply: reply)
            var schedule = schedules[key] ?? .init()
            due[key] = now.addingTimeInterval(RelayWorkCarrier.nextCheck(after: box, state: &schedule))
            schedules[key] = schedule
            outboxes[key] = box
        }
        for step in RelayWorkCarrier.plan(Array(outboxes.values)) {
            guard let from = byKey[step.fromHost], let to = byKey[step.toHost] else { continue }
            let claim: [String: Any]
            do {
                claim = try await request(from, RelayWorkCarrier.claimPacket(messageID: step.messageID))
            } catch {
                // The sending relayd records its own reason on the queue record.
                note(step, "claim_failed", RelayWorkCarrier.refusal(error) ?? error.localizedDescription)
                continue
            }
            guard let envelope = claim["work_envelope"] as? String else {
                if claim["status"] as? String != "settled" {
                    note(step, "claim_failed", "the sending relayd returned no signed message")
                }
                continue
            }
            let delivered: [String: Any]
            do {
                delivered = try await request(to, RelayWorkCarrier.deliverPacket(envelope: envelope))
            } catch {
                // The peer's relayd refused the signed message (a changed
                // target, say): tell the sending relayd, whose receipt shows
                // why. The message stays queued there; nothing is settled or
                // resent under a new ID. An unreachable peer is only logged.
                let reason = RelayWorkCarrier.refusal(error)
                note(step, reason == nil ? "deliver_unreachable" : "deliver_refused", reason ?? error.localizedDescription)
                if let reason {
                    await reportRefusal(step, from: from, reason: reason)
                }
                continue
            }
            guard let reply = delivered["work_reply"] as? String else {
                let reason = "the peer's relayd answered without a signed reply"
                note(step, "deliver_refused", reason)
                await reportRefusal(step, from: from, reason: reason)
                continue
            }
            do {
                _ = try await request(from, RelayWorkCarrier.settlePacket(messageID: step.messageID, reply: reply))
                noted[step.messageID] = nil
            } catch {
                // The next claim of the same message is a signed receipt query,
                // never a second delivery.
                note(step, "settle_failed", RelayWorkCarrier.refusal(error) ?? error.localizedDescription)
            }
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

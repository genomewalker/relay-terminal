import AppKit

/// A pending request from a Claude desktop session for a route link to one pane,
/// as the owner's daemon lists it. Its fields are what the owner is asked about.
struct DesktopLinkRequest: Codable, Equatable {
    let id: String
    let sessionID: String
    let accountRoot: String
    let paneID: String
    let createdAt: String
    let expiresAt: String
    /// The callers the saved pair with this pane would admit. Approval admits exactly these.
    let proposedCallers: [String]
    /// Why this request cannot be approved yet, when it cannot.
    let refusal: String?
    /// The host of the pane. Absent from an older listing.
    let peerNodeID: String?
    /// "relay_host_channel" when the app must carry the approval to the peer
    /// host; absent for an HTTPS route and from an older listing.
    let carrier: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case accountRoot = "account_root"
        case paneID = "pane_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case proposedCallers = "proposed_callers"
        case refusal
        case peerNodeID = "peer_node_id"
        case carrier
    }

    init(id: String, sessionID: String, accountRoot: String, paneID: String, createdAt: String, expiresAt: String,
         proposedCallers: [String] = [], refusal: String? = nil, peerNodeID: String? = nil, carrier: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.accountRoot = accountRoot
        self.paneID = paneID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.proposedCallers = proposedCallers
        self.refusal = refusal
        self.peerNodeID = peerNodeID
        self.carrier = carrier
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        accountRoot = try values.decode(String.self, forKey: .accountRoot)
        paneID = try values.decode(String.self, forKey: .paneID)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        expiresAt = try values.decode(String.self, forKey: .expiresAt)
        proposedCallers = try values.decodeIfPresent([String].self, forKey: .proposedCallers) ?? []
        refusal = try values.decodeIfPresent(String.self, forKey: .refusal)
        peerNodeID = try values.decodeIfPresent(String.self, forKey: .peerNodeID)
        carrier = try values.decodeIfPresent(String.self, forKey: .carrier)
    }

    /// The peer node the app must reach before approving, when the route is
    /// carried by the Relay host channel.
    var hostChannelPeer: String? {
        guard carrier == "relay_host_channel", let node = peerNodeID, !node.isEmpty else { return nil }
        return node
    }

    /// True until the daemon's expiry time has passed. Unparseable times are not live.
    func isLive(at now: Date) -> Bool {
        guard let expires = DesktopLinkRequest.parse(expiresAt) else { return false }
        return now < expires
    }

    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

enum DesktopLinkDecision: Equatable {
    case approved, rejected, cancelled, changed, unavailable
}

/// Carrying a host-channel approval failed before the pair was established.
enum DesktopLinkCarrierError: LocalizedError, Equatable {
    case noConnectedHost(String)
    case identityChanged(String)
    case peerUnsupported(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .noConnectedHost(let node):
            "No single connected host reports node \(node), so the approval could not reach it and nothing was sent to it. Open a pane on that host in Relay, then ask the session to request the link again."
        case .identityChanged(let node):
            "The signing key of the host for node \(node) changed since it was trusted. Confirm the new key in Relay before approving; nothing was sent to it."
        case .peerUnsupported(let node):
            "The requested host's relayd (node \(node)) does not support native desktop link approval; update it. Nothing was established."
        case .malformed: "The host-channel approval exchange returned an unexpected reply; nothing was established."
        }
    }
}

/// A daemon call failed after the owner had answered. The answer still counts.
struct DesktopLinkAnsweredFailure: Error {
    let decision: DesktopLinkDecision
    let underlying: Error
}

/// The owner's decision on one pending desktop link request. Nothing is approved
/// without the owner's click on the request as it was shown, with the callers it
/// lists. A request that changed or expired before the click is refused, and the
/// daemon checks the pair and callers again on its own side.
///
/// Defense in depth, not a boundary: the daemon refuses owner operations whose
/// caller is, or descends from, an agent process (pane agents and Claude desktop
/// sessions), and callers whose ancestry it cannot read. An agent can still reach
/// the owner operations through a non-agent process it starts outside its own
/// ancestry: a double fork or nohup reparented to init, tmux or screen, launchctl
/// or at, or `ssh <host> relayd communication`. Any other same-user program can
/// run them too. This panel is the owner's decision, not a defense against them.
@MainActor final class DesktopLinkApproval {
    /// Sends one owner operation to the daemon and returns its reply.
    typealias Requester = @MainActor (_ operation: String, _ packet: [String: Any]) async throws -> [String: Any]
    typealias Presenter = PeerNetworkApproval.Presenter
    /// The requester for the one connected host whose relayd reports this node
    /// ID, or nil when no single connected host does.
    typealias PeerResolver = @MainActor (_ nodeID: String) async throws -> Requester?

    private let requester: Requester
    private let peer: PeerResolver?
    private let present: Presenter

    init(requester: @escaping Requester, present: Presenter? = nil, peer: PeerResolver? = nil) {
        self.requester = requester
        self.peer = peer
        self.present = present ?? { alert, completion in
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ??
                    NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  window.attachedSheet == nil else { return false }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: completion)
            return true
        }
    }

    /// The owner's pending requests. Listing never approves anything.
    func pending() async throws -> [DesktopLinkRequest] {
        let reply = try await requester("route_desktop_link_list", [:])
        let data = try JSONSerialization.data(withJSONObject: reply["requests"] ?? [])
        return try JSONDecoder().decode([DesktopLinkRequest].self, from: data)
    }

    /// Asks the owner about one request. `current` is the owner's latest listing
    /// that the request was taken from.
    func decide(_ shown: DesktopLinkRequest, current: [DesktopLinkRequest]) async throws -> DesktopLinkDecision {
        guard current.contains(shown) else { return .changed }
        guard shown.refusal == nil, !shown.proposedCallers.isEmpty else { return .unavailable }
        let answer = await ask(shown)
        guard let answer else { return .unavailable }
        if answer == .alertFirstButtonReturn {
            // Reject needs no fresh check: removing a request is always safe.
            try await afterAnswer(.rejected) { _ = try await requester("route_desktop_link_reject", ["request_id": shown.id]) }
            return .rejected
        }
        guard answer == .alertSecondButtonReturn else { return .cancelled }
        // Re-read the owner's listing: a request that changed or expired after
        // it was shown is never approved.
        guard try await afterAnswer(.approved, { try await pending().contains(shown) }) else { return .changed }
        try await afterAnswer(.approved) {
            // A host-channel route needs the peer host to carry the exchange. Find it
            // before approve spends the owner capability and starts the freshness
            // window; with no single connected host, nothing is spent. An HTTPS
            // route (no carrier listed) needs no lookup.
            var carrier: Requester?
            if let node = shown.hostChannelPeer {
                guard let found = try await peer?(node) else { throw DesktopLinkCarrierError.noConnectedHost(node) }
                carrier = found
            }
            let reply = try await requester("route_desktop_link_approve", [
                "request_id": shown.id, "source_pane_id": shown.sessionID, "pane_id": shown.paneID,
                "allowed_callers": shown.proposedCallers])
            if reply["status"] as? String == "dispatch" { try await carry(reply, expected: shown.hostChannelPeer, via: carrier) }
        }
        return .approved
    }

    /// A route carried by the Relay host channel: relayd returned a proposal
    /// signed with its host key. It is delivered to the peer host's relayd and
    /// that relayd's signed reply is handed back; this host's relayd checks the
    /// reply against its pinned key before saving anything. This carrier can
    /// delay or drop the exchange but cannot forge, alter or redirect it.
    private func carry(_ dispatch: [String: Any], expected: String?, via carrier: Requester?) async throws {
        guard let node = dispatch["peer_node_id"] as? String, !node.isEmpty,
              let messageID = dispatch["message_id"] as? String, !messageID.isEmpty,
              let envelope = dispatch["establish_envelope"] as? String, !envelope.isEmpty else {
            throw DesktopLinkCarrierError.malformed
        }
        if let expected, expected != node { throw DesktopLinkCarrierError.malformed }
        // A route that became host-channel after the listing is resolved here.
        var resolved = carrier
        if resolved == nil { resolved = try await peer?(node) }
        guard let peerRequester = resolved else { throw DesktopLinkCarrierError.noConnectedHost(node) }
        let delivered: [String: Any]
        do {
            delivered = try await peerRequester("deliver_signed_desktop_establish", ["establish_envelope": envelope])
        } catch where error.localizedDescription.contains("unknown daemon communication operation") {
            // An older relayd answers at once with this refusal; name the fix.
            throw DesktopLinkCarrierError.peerUnsupported(node)
        }
        guard let reply = delivered["establish_reply"] as? String, !reply.isEmpty else { throw DesktopLinkCarrierError.malformed }
        let settled = try await requester("route_desktop_link_settle", ["message_id": messageID, "establish_reply": reply])
        guard settled["status"] as? String == "established" else { throw DesktopLinkCarrierError.malformed }
    }

    /// A daemon call made after the owner answered. Its failure carries the
    /// answer, so the request is not asked about again.
    private func afterAnswer<T>(_ decision: DesktopLinkDecision, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw DesktopLinkAnsweredFailure(decision: decision, underlying: error) }
    }

    /// Tells the owner once that the daemon did not carry out their answer.
    func report(_ failure: DesktopLinkAnsweredFailure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.decision == .rejected ? "The desktop link request was not rejected"
            : "The desktop link request was not approved"
        alert.informativeText = "Relay could not complete your answer: \(failure.underlying.localizedDescription)\n\n" +
            "This request will not be shown again. If the session asks again, it appears as a new request."
        alert.addButton(withTitle: "OK")
        _ = present(alert) { _ in }
    }

    private func ask(_ request: DesktopLinkRequest) async -> NSApplication.ModalResponse? {
        let alert = NSAlert()
        alert.messageText = "Allow a Claude desktop session to link to this pane?"
        alert.informativeText = "Desktop session: \(request.sessionID)\n" +
            "Account: \(request.accountRoot)\n" +
            "Target pane: \(request.paneID)\n" +
            "Callers the link admits: \(request.proposedCallers.joined(separator: ", "))\n\n" +
            "Approve creates one messaging link between this session and that pane, pinned to this session, " +
            "and admits exactly the callers listed. Reject discards the request. " +
            "The request expires at \(request.expiresAt)."
        alert.addButton(withTitle: "Reject")
        alert.addButton(withTitle: "Approve")
        return await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse?, Never>) in
            let shown = present(alert) { continuation.resume(returning: $0) }
            if !shown { continuation.resume(returning: nil) }
        }
    }
}

/// Shows pending desktop link requests to the owner as they arrive. It polls each
/// connected host's listing, and asks about each live request once per session.
/// The owner's answer is the only way a request is approved or rejected.
@MainActor final class DesktopLinkWatch {
    static let interval: Duration = .seconds(5)

    /// Identity of one request. The same pair requested again is a new request.
    nonisolated static func askKey(_ request: DesktopLinkRequest) -> String {
        request.id + "|" + request.createdAt
    }

    /// The requests to ask about now: live, approvable (no refusal, callers shown), and
    /// not yet answered.
    nonisolated static func due(_ listing: [DesktopLinkRequest], asked: Set<String>, now: Date) -> [DesktopLinkRequest] {
        listing.filter { $0.isLive(at: now) && $0.refusal == nil && !$0.proposedCallers.isEmpty && !asked.contains(askKey($0)) }
    }

    /// Records an answer. Only a decision the owner gave counts; a sheet that could
    /// not be shown, or a listing that changed, leaves the request to be offered again.
    nonisolated static func answered(_ decision: DesktopLinkDecision?, shown: DesktopLinkRequest, asked: Set<String>) -> Set<String> {
        guard let decision else { return asked }
        switch decision {
        case .approved, .rejected, .cancelled:
            return asked.union([askKey(shown)])
        case .changed, .unavailable:
            return asked
        }
    }

    /// The decision to record for one ask. A daemon failure after the owner's
    /// answer keeps the answer and is returned to be shown; any earlier failure
    /// is no answer, and the request is offered again.
    static func outcome(_ decide: () async throws -> DesktopLinkDecision) async -> (DesktopLinkDecision?, DesktopLinkAnsweredFailure?) {
        do { return (try await decide(), nil) }
        catch let failure as DesktopLinkAnsweredFailure { return (failure.decision, failure) }
        catch { return (nil, nil) }
    }

    private weak var workspace: WorkspaceModel?
    private var task: Task<Void, Never>?
    private var asked: Set<String> = []

    init(workspace: WorkspaceModel?) {
        self.workspace = workspace
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let workspace = self.workspace else { return }
                await self.tick(workspace)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    static func requester(_ profile: ConnectionProfile) -> DesktopLinkApproval.Requester {
        { operation, packet in
            var request = packet
            request["operation"] = operation
            return try await RelayPaneMessaging.shared.daemonRequest(profile: profile, packet: request, attach: false)
        }
    }

    /// The one other connected relay host whose relayd reports node. Nothing is
    /// pinned or saved: see DesktopLinkPeerLookup.
    static func peerRequester(_ node: String, workspace: WorkspaceModel, excluding own: ConnectionProfile) async throws -> DesktopLinkApproval.Requester? {
        var seen: Set<String> = [own.connectionKey]
        let profiles = workspace.panes.values.map(\.profile).filter { $0.backend == .relay && seen.insert($0.connectionKey).inserted }
        let trust = RelayNodeTrust.shared
        let lookup = DesktopLinkPeerLookup(hosts: profiles, pins: trust.pins, mismatches: trust.mismatches,
                                           identify: { try await trust.identify($0) })
        return try await lookup.resolve(node).map(requester)
    }

    /// One pass over the connected hosts. Requests are asked about one at a time.
    func tick(_ workspace: WorkspaceModel, now: Date = Date()) async {
        for host in RelayQuestionNotices.hosts(workspace) {
            let approval = DesktopLinkApproval(requester: Self.requester(host.profile), peer: { node in
                try await Self.peerRequester(node, workspace: workspace, excluding: host.profile)
            })
            guard let listing = try? await approval.pending() else { continue }
            for shown in Self.due(listing, asked: asked, now: now) {
                let (decision, failure) = await Self.outcome { try await approval.decide(shown, current: listing) }
                asked = Self.answered(decision, shown: shown, asked: asked)
                if let failure { approval.report(failure) }
            }
        }
    }
}

/// Selects the connected host that carries a host-channel approval to a peer
/// node. It only selects a carrier: the relayds verify every signed frame
/// against their own pins, so a wrong choice can fail the exchange but never
/// forge it. It pins, saves and records nothing.
///
/// Saved pins are matched first, without contacting any host. Only hosts with
/// no saved pin are asked for their node identity, all at once, and the answer
/// is whatever arrived within `timeout`, so one slow host cannot hold it up.
/// A host whose recorded key changed for this node is reported as such.
@MainActor struct DesktopLinkPeerLookup {
    typealias Identify = @MainActor (ConnectionProfile) async throws -> RelayNodeTrust.Pin

    let hosts: [ConnectionProfile]
    let pins: [UUID: RelayNodeTrust.Pin]
    let mismatches: [UUID: RelayNodeTrust.Mismatch]
    let identify: Identify
    var timeout: Duration = .seconds(10)

    func resolve(_ node: String) async throws -> ConnectionProfile? {
        if hosts.contains(where: { host in
            mismatches[host.id].map { $0.pinned.nodeID == node || $0.offered.nodeID == node } ?? false
        }) {
            throw DesktopLinkCarrierError.identityChanged(node)
        }
        let pinned = hosts.filter { pins[$0.id]?.nodeID == node }
        if !pinned.isEmpty { return pinned.count == 1 ? pinned[0] : nil }
        let unpinned = hosts.filter { pins[$0.id] == nil }
        guard !unpinned.isEmpty else { return nil }
        let answers = await Self.collect(unpinned, timeout: timeout, identify: identify)
        let matches = unpinned.filter { answers[$0.id] == node }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Asks every host at once and returns the node IDs that answered before
    /// the timeout. A host that has not answered by then is left out.
    private static func collect(_ hosts: [ConnectionProfile], timeout: Duration, identify: @escaping Identify) async -> [UUID: String] {
        let box = DesktopLinkLookupBox(remaining: hosts.count)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[UUID: String], Never>) in
            box.continuation = continuation
            for host in hosts {
                Task { @MainActor in
                    let pin = try? await identify(host)
                    box.answer(host.id, pin?.nodeID)
                }
            }
            box.timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                box.finish()
            }
        }
    }
}

@MainActor private final class DesktopLinkLookupBox {
    var remaining: Int
    var answers: [UUID: String] = [:]
    var continuation: CheckedContinuation<[UUID: String], Never>?
    var timer: Task<Void, Never>?

    init(remaining: Int) { self.remaining = remaining }

    func answer(_ id: UUID, _ node: String?) {
        remaining -= 1
        if let node, continuation != nil { answers[id] = node }
        if remaining == 0 { finish() }
    }

    func finish() {
        timer?.cancel()
        continuation?.resume(returning: answers)
        continuation = nil
    }
}

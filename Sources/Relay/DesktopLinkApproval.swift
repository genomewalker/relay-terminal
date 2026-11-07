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

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case accountRoot = "account_root"
        case paneID = "pane_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case proposedCallers = "proposed_callers"
        case refusal
    }

    init(id: String, sessionID: String, accountRoot: String, paneID: String, createdAt: String, expiresAt: String,
         proposedCallers: [String] = [], refusal: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.accountRoot = accountRoot
        self.paneID = paneID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.proposedCallers = proposedCallers
        self.refusal = refusal
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

    private let requester: Requester
    private let present: Presenter

    init(requester: @escaping Requester, present: Presenter? = nil) {
        self.requester = requester
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
            _ = try await requester("route_desktop_link_approve", [
                "request_id": shown.id, "source_pane_id": shown.sessionID, "pane_id": shown.paneID,
                "allowed_callers": shown.proposedCallers])
        }
        return .approved
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

    /// One pass over the connected hosts. Requests are asked about one at a time.
    func tick(_ workspace: WorkspaceModel, now: Date = Date()) async {
        for host in RelayQuestionNotices.hosts(workspace) {
            let approval = DesktopLinkApproval { operation, packet in
                var request = packet
                request["operation"] = operation
                return try await RelayPaneMessaging.shared.daemonRequest(profile: host.profile, packet: request, attach: false)
            }
            guard let listing = try? await approval.pending() else { continue }
            for shown in Self.due(listing, asked: asked, now: now) {
                let (decision, failure) = await Self.outcome { try await approval.decide(shown, current: listing) }
                asked = Self.answered(decision, shown: shown, asked: asked)
                if let failure { approval.report(failure) }
            }
        }
    }
}

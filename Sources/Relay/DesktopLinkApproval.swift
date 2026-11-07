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

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case accountRoot = "account_root"
        case paneID = "pane_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

enum DesktopLinkDecision: Equatable {
    case approved, rejected, cancelled, changed, unavailable
}

/// The owner's decision on one pending desktop link request. Nothing is approved
/// without the owner's click on the request as it was shown. A request that
/// changed or expired before the click is refused, and the daemon checks the
/// pair again on its own side.
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
        let answer = await ask(shown)
        guard let answer else { return .unavailable }
        if answer == .alertFirstButtonReturn {
            // Reject needs no fresh check: removing a request is always safe.
            _ = try await requester("route_desktop_link_reject", ["request_id": shown.id])
            return .rejected
        }
        guard answer == .alertSecondButtonReturn else { return .cancelled }
        // Re-read the owner's listing: a request that changed or expired after
        // it was shown is never approved.
        guard try await pending().contains(shown) else { return .changed }
        _ = try await requester("route_desktop_link_approve", [
            "request_id": shown.id, "source_pane_id": shown.sessionID, "pane_id": shown.paneID])
        return .approved
    }

    private func ask(_ request: DesktopLinkRequest) async -> NSApplication.ModalResponse? {
        let alert = NSAlert()
        alert.messageText = "Allow a Claude desktop session to link to this pane?"
        alert.informativeText = "Desktop session: \(request.sessionID)\n" +
            "Account: \(request.accountRoot)\n" +
            "Target pane: \(request.paneID)\n\n" +
            "Approve creates one messaging link between this session and that pane, pinned to this session. " +
            "Reject discards the request. The request expires at \(request.expiresAt)."
        alert.addButton(withTitle: "Reject")
        alert.addButton(withTitle: "Approve")
        return await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse?, Never>) in
            let shown = present(alert) { continuation.resume(returning: $0) }
            if !shown { continuation.resume(returning: nil) }
        }
    }
}

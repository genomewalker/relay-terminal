import Foundation

// Miko messages agent panes through Relay's existing daemon-owned message
// system (relayd communication: durable claim, link check, recipient
// revalidation, receipts, events, the provider inbox) as its own principal,
// "relay-assistant". The recipient host's relayd admits it only as an owner
// request (no pane or caller credential) and only for a pair saved on that
// host. That is all it can verify: any process of the same user could submit
// the same request, so nothing claims the Relay app or a user Run decision
// (relay_assistant_owner_submitted). There is no key to pin. Miko never
// borrows a pane's identity, kernel ancestry or a remote attestation anchor.
// The Mac reaches any host's relayd over its own host channel, so the Here
// pane and the recipient may be on different hosts.

/// The recipient as the user approved it on the card.
struct RelayAssistantRecipient: Equatable, Sendable {
    let provider: String
    let sessionID: String
    let pid: Int
    let start: String
    let socketIdentity: String
    let transport: String

    var expected: [String: Any] {
        ["provider": provider, "sessionID": sessionID, "pid": pid, "start": start,
         "socketIdentity": socketIdentity, "transport": transport]
    }
}

struct RelayAssistantMessageRequest: Sendable {
    let messageID: UUID
    let assistantRequestID: String
    let herePaneID: UUID
    let recipientPaneID: UUID
    let text: String
    let recipient: RelayAssistantRecipient
    /// "node": the pair is saved on the recipient's relayd; "desktop": a
    /// cross-host pair saved in this app, saved again on the recipient's host
    /// before sending. The host checks its own record either way.
    let linkScope: String
}

/// The message system as the assistant reaches it. Production: the recipient
/// host's relayd over the Mac app's authenticated host channel.
@MainActor protocol RelayAssistantMessagingPort: AnyObject {
    func recipient(_ pane: UUID) async throws -> RelayAssistantRecipient
    /// "node", "desktop" or nil when the user's pane and the recipient are not linked.
    func linkScope(_ here: UUID, _ recipient: UUID) async throws -> String?
    func send(_ request: RelayAssistantMessageRequest) async throws -> [String: Any]
    func receipt(_ messageID: UUID, recipient: UUID) async throws -> [String: Any]
    func inbox() async throws -> [[String: Any]]
}

enum RelayAssistantMessaging {
    static let senderName = "Miko (Relay assistant)"
    static let authentication = "relay_assistant_owner_submitted"
    /// Replies to Miko are addressed to this reserved inbox (relayd's
    /// communicationAssistantInboxID).
    static let inboxID = "a5515700-0000-4000-8000-00000000b0c5"

    /// The sender line the recipient sees. It claims only what the host checks.
    static func senderLine(requestID: String) -> String {
        "From \(senderName) via the recipient host's relayd (owner request, saved pair); request \(requestID)"
    }

    /// Daemon refusals returned before the durable claim: nothing was sent.
    static func refusedBeforeSend(_ message: String) -> Bool {
        ["needs_link", "recipient_changed", "relay-assistant principal not attested", "unknown daemon communication operation",
         "a message UUID", "the target pane has no verified native communication endpoint", "linked conversation changed",
         "message identity conflicts", "caller is paused", "relay-assistant messages are owner requests",
         "two distinct panes and the user's host are required", "the recipient must be a pane of this host"].contains { message.contains($0) }
    }
}

/// Production port: relayd's communication command on the recipient's host.
@MainActor final class RelayAssistantDaemonMessaging: RelayAssistantMessagingPort {
    typealias Daemon = @MainActor (ConnectionProfile, [String: Any]) async throws -> [String: Any]
    private weak var workspace: WorkspaceModel?
    private let daemon: Daemon
    private let savedLinks: @MainActor () async throws -> [[String: Any]]

    init(workspace: WorkspaceModel, daemon: Daemon? = nil,
         savedLinks: (@MainActor () async throws -> [[String: Any]])? = nil) {
        self.workspace = workspace
        self.daemon = daemon ?? { profile, packet in try await RelayPaneMessaging.shared.daemonRequest(profile: profile, packet: packet) }
        self.savedLinks = savedLinks ?? { [weak workspace] in
            guard let workspace else { return [] }
            return try await RelayPaneMessaging.shared.savedLinks(workspace: workspace)
        }
    }

    private func profile(_ pane: UUID) throws -> ConnectionProfile {
        guard let profile = workspace?.panes[pane]?.profile, profile.backend == .relay else {
            throw RemoteCatalogError.failed("The pane is not a Relay pane, so Relay's message system cannot reach it.")
        }
        return profile
    }

    func recipient(_ pane: UUID) async throws -> RelayAssistantRecipient {
        let reply = try await daemon(try profile(pane), ["operation": "discover", "pane_id": pane.uuidString.lowercased()])
        guard let endpoint = reply["endpoint"] as? [String: Any], let provider = endpoint["provider"] as? String,
              let session = endpoint["sessionID"] as? String, let pid = (endpoint["pid"] as? NSNumber)?.intValue,
              let start = endpoint["start"] as? String, let transport = endpoint["transport"] as? String,
              transport != "unavailable" else {
            throw RemoteCatalogError.failed(reply["error"] as? String ?? "No exact live agent conversation is bound to this pane.")
        }
        return .init(provider: provider, sessionID: session, pid: pid, start: start,
                     socketIdentity: endpoint["socketIdentity"] as? String ?? "", transport: transport)
    }

    func linkScope(_ here: UUID, _ recipient: UUID) async throws -> String? {
        let pair = Set([here.uuidString.lowercased(), recipient.uuidString.lowercased()])
        func members(_ link: [String: Any]) -> Set<String> {
            Set((link["members"] as? [[String: Any]] ?? []).compactMap { ($0["paneID"] as? String)?.lowercased() })
        }
        let recipientProfile = try profile(recipient)
        if (try? profile(here))?.connectionKey == recipientProfile.connectionKey {
            let reply = try await daemon(recipientProfile, ["operation": "list"])
            if (reply["links"] as? [[String: Any]] ?? []).contains(where: { members($0) == pair }) { return "node" }
        }
        // A cross-host pair is saved by this app (the existing cross-host rule).
        let saved = try await savedLinks()
        return saved.contains { $0["authority"] as? String == "legacy_desktop_record" &&
            $0["state"] as? String == "membership_saved" && members($0) == pair } ? "desktop" : nil
    }

    /// A cross-host pair lives in this app; the recipient's relayd checks
    /// pairs only from its own records, so save it there before sending.
    private func saveOnRecipientHost(_ request: RelayAssistantMessageRequest, _ profile: ConnectionProfile) async throws {
        let hereHost = (try? self.profile(request.herePaneID))?.connectionKey ?? "This Mac"
        let reply = try await daemon(profile, ["operation": "assistant_link_set",
            "source_pane_id": request.herePaneID.uuidString.lowercased(), "pane_id": request.recipientPaneID.uuidString.lowercased(),
            "here_host": hereHost])
        guard reply["status"] as? String == "linked" else {
            throw RemoteCatalogError.failed("needs_link: the recipient's host did not save the cross-host pair.")
        }
    }

    /// Called only by the explicit Settings report-registration action. The
    /// monitor's send path never creates, repairs or replaces a saved pair.
    func prepareShepherdLink(here: UUID, target: UUID, scope: String, linkID: String,
                             expectedRevision: String) async throws -> String {
        let profile = try profile(target)
        if scope == "node" {
            let reply = try await daemon(profile, ["operation": "list"])
            let pair = Set([here.uuidString.lowercased(), target.uuidString.lowercased()])
            guard let link = (reply["links"] as? [[String: Any]])?.first(where: {
                $0["id"] as? String == linkID && Set(($0["members"] as? [[String: Any]] ?? []).compactMap {
                    ($0["paneID"] as? String)?.lowercased()
                }) == pair
            }), let revision = link["updated_at"] as? String, !revision.isEmpty,
                  revision == expectedRevision else { throw RelayShepherdPushFailure.stale }
            return revision
        }
        guard scope == "desktop", try await linkScope(here, target) == "desktop" else { throw RelayShepherdPushFailure.stale }
        let reply = try await daemon(profile, ["operation": "assistant_link_set",
            "source_pane_id": here.uuidString.lowercased(), "pane_id": target.uuidString.lowercased(),
            "here_host": try self.profile(here).connectionKey])
        guard reply["status"] as? String == "linked", let revision = reply["link_revision"] as? String,
              RelayShepherdPushWire.text(revision, 128) else { throw RelayShepherdPushFailure.stale }
        return revision
    }

    func send(_ request: RelayAssistantMessageRequest) async throws -> [String: Any] {
        let profile = try profile(request.recipientPaneID)
        if request.linkScope == "desktop" { try await saveOnRecipientHost(request, profile) }
        return try await daemon(profile, ["operation": "assistant_send",
            "source_pane_id": request.herePaneID.uuidString.lowercased(), "pane_id": request.recipientPaneID.uuidString.lowercased(),
            "message_id": request.messageID.uuidString.lowercased(), "text": request.text,
            "assistant_request_id": request.assistantRequestID, "expected_recipient": request.recipient.expected])
    }

    func receipt(_ messageID: UUID, recipient: UUID) async throws -> [String: Any] {
        try await daemon(try profile(recipient), ["operation": "receipt", "message_id": messageID.uuidString.lowercased()])
    }

    func inbox() async throws -> [[String: Any]] {
        guard let workspace else { return [] }
        var seen: Set<String> = [], replies: [[String: Any]] = []
        for profile in workspace.panes.values.map(\.profile) where profile.backend == .relay && seen.insert(profile.connectionKey).inserted {
            guard let reply = try? await daemon(profile, ["operation": "assistant_inbox"]) else { continue }
            replies += reply["replies"] as? [[String: Any]] ?? []
        }
        return Array(replies.prefix(50))
    }
}

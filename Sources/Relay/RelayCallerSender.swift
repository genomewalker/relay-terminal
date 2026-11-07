import Foundation

/// A registered Relay client with no pane (for example a Claude desktop chat)
/// can send a pane message as itself. The recipient sees the caller's label and
/// id, never a pane. This is only a replacement for the "sender is a pane"
/// requirement: the input grant, the recipient checks, idempotency and receipts
/// are the ones every pane message already goes through.
enum RelayCallerSender {
    /// Provenance label. The Relay app resolved the credential, but the
    /// recipient's relayd cannot tell the app from any process of the same user
    /// that calls the pane-messaging helper, so the id and label are only claimed.
    static let authentication = "registered_caller_claimed"
    static let labelByteLimit = 80

    struct Sender: Equatable {
        let id: String
        let label: String
        /// The text the recipient reads, for example `caller "Claude desktop clients" (id 1a2b3c4d)`.
        var displayName: String { "caller \"\(label)\" (id \(id.prefix(8)))" }
    }

    enum Refusal: Error, LocalizedError, Equatable {
        case noSender, notRegistered, paused, unusableLabel
        var errorDescription: String? {
            switch self {
            case .noSender: return "A source pane is required unless the request carries a registered caller credential."
            case .notRegistered: return "The caller credential is not a registered client; a source pane is required."
            case .paused: return "This Relay caller is paused"
            case .unusableLabel: return "The registered caller has no usable label."
            }
        }
    }

    /// Identities that are not registered external clients. They never become a caller sender.
    @MainActor private static var reserved: Set<String> {
        ["legacy-unattributed", RelayCallerControl.assistantCaller, RelayCallerControl.supervisorCaller,
         RelayCallerControl.assistantPublisher]
    }

    /// The pure decision. `identity` is `RelayCallerControl.identity(token:)`:
    /// `legacy-unattributed` when no caller token was presented.
    @MainActor static func resolve(identity: String, label: String?, permitted: Bool) throws -> Sender {
        guard identity == identity.lowercased(), UUID(uuidString: identity) != nil, !reserved.contains(identity) else {
            throw identity == "legacy-unattributed" ? Refusal.noSender : Refusal.notRegistered
        }
        guard let label else { throw Refusal.notRegistered }
        guard permitted else { throw Refusal.paused }
        guard let clean = sanitizedLabel(label) else { throw Refusal.unusableLabel }
        return Sender(id: identity, label: clean)
    }

    /// Resolves the request's caller token against the registry. An unknown
    /// token already throws in `identity(token:)`.
    @MainActor static func resolve(token: String?, control: RelayCallerControl) throws -> Sender {
        let identity = try control.identity(token: token)
        return try resolve(identity: identity, label: control.summaries.first { $0.id == identity }?.label,
                           permitted: control.permitted(identity))
    }

    /// Control characters and line separators become spaces; quotes and
    /// backslashes become apostrophes; runs of whitespace collapse; the result
    /// is cut at a character boundary. Returns nil if nothing printable is left.
    nonisolated static func sanitizedLabel(_ raw: String) -> String? {
        var mapped = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0..<0x20, 0x7f, 0x80..<0xa0, 0x2028, 0x2029, 0xfeff: mapped.append(" ")
            case 0x22, 0x5c: mapped.append("'")
            default: mapped.append(scalar)
            }
        }
        var label = String(mapped).split(whereSeparator: { $0 == " " }).joined(separator: " ")
        while label.utf8.count > labelByteLimit { label.removeLast() }
        return label.isEmpty ? nil : label
    }

    /// The `source` object handed to the recipient host's relayd. It has no
    /// pane, session or socket key, and relayd refuses one if it appears.
    nonisolated static func source(_ sender: Sender, hostID: UUID) -> [String: Any] {
        ["authentication": authentication, "callerID": sender.id, "callerLabel": sender.label,
         "hostID": hostID.uuidString.lowercased()]
    }

    /// A pane-less submission: only these two keys. Proof fields belong to a
    /// pane sender and are refused rather than ignored.
    struct Submission: Decodable {
        let messageID: UUID
        let text: String
        /// Nil when the body names no source pane, or names keys a caller may not send.
        static func decode(_ body: Data) -> Submission? {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  Set(object.keys) == ["messageID", "text"] else { return nil }
            return try? JSONDecoder().decode(Submission.self, from: body)
        }
    }

    /// A caller cannot address a background session; pane-less bodies naming one are refused clearly.
    nonisolated static let sessionRefusal = "a registered caller cannot address a session; omit target_session_id"
    nonisolated static func namesSession(_ body: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        return object["target_session_id"] != nil || object["targetSessionID"] != nil
    }

    /// Whether the body names a source pane at all (the existing pane path).
    nonisolated static func namesSourcePane(_ body: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["sourcePaneID"] != nil
    }
}

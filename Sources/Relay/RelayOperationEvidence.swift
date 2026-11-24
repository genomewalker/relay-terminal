import Foundation

/// A read-only, redacted reconstruction of one pane message or one account
/// move, built only from receipts Relay already keeps. It never sends,
/// retries or repeats anything, and it says where the evidence ends instead
/// of guessing: an admitted message is not a processed one, and a missing or
/// unreadable receipt is reported as unknown, never as a failure.
enum RelayOperationEvidence {
    enum Kind: String {
        case message
        case accountMove = "account_move"
    }

    /// What one evidence source returned for the operation.
    struct Source {
        let name: String
        let observedAt: Date
        /// The receipt as the source returned it; nil when it had no record.
        let record: [String: Any]?
        /// Why the source could not be read, when it could not.
        let error: String?

        init(name: String, observedAt: Date, record: [String: Any]?, error: String? = nil) {
            self.name = name
            self.observedAt = observedAt
            self.record = record
            self.error = error
        }
    }

    /// How far one receipt proves the operation got.
    enum Stage: String {
        case requested
        case inProgress = "in_progress"
        case socketWrite = "written_to_socket"
        case turnCompleted = "provider_turn_completed"
        case admitted
        case providerTurnStarted = "provider_turn_started"
        case acknowledged
        case completed
        case refused
        case notSent = "not_sent"
        case held
        case unknown
        case noRecord = "no_record"
        case readFailed = "read_failed"

        /// Progress proven toward completion; nil for outcomes that are not
        /// progress (refusals, unknowns, missing records).
        var progress: Int? {
            switch self {
            case .requested, .inProgress: 1
            case .socketWrite, .admitted: 2
            case .providerTurnStarted: 3
            case .acknowledged, .completed, .turnCompleted: 4
            default: nil
            }
        }

        var negative: Bool { self == .refused || self == .notSent }
    }

    static func stage(kind: Kind, status: String?) -> Stage {
        guard let status else { return .unknown }
        switch (kind, status) {
        case (.message, "pending"): return .requested
        case (.message, "not_sent"): return .notSent
        case (.message, "written_to_socket"): return .socketWrite
        case (.message, "turn_completed"): return .turnCompleted
        case (.message, "admitted_not_processed"),
             (.message, "accepted_by_provider"): return .admitted
        case (.message, "turn_started"): return .providerTurnStarted
        case (.message, "read_acknowledged"): return .acknowledged
        case (.accountMove, "moving"): return .inProgress
        case (.accountMove, "verified"): return .completed
        case (.accountMove, "refused"): return .refused
        case (.accountMove, "held"): return .held
        default: return .unknown
        }
    }

    /// Plain fields kept verbatim: identities, statuses and transport facts.
    static let keptFields: Set<String> = [
        "status", "acknowledgement", "authority", "transport", "provider", "reason_code", "replay_permitted",
        "source_authentication", "verified_by", "desktop_required", "account", "paneID", "pane_id",
        "source_pane_id", "message_id", "request_id", "turn_id", "provider_turn_id", "state",
    ]
    /// Free text that can explain an outcome; kept after redaction and a length cap.
    static let explanatoryFields: Set<String> = ["message", "blocker", "how_to_clear", "note", "reason"]
    /// Message bodies and drafts are never exported, even redacted.
    static let contentFields: Set<String> = ["text", "content", "prompt", "body", "draft", "message_text"]
    static let textLimit = 500

    static func export(kind: Kind, id: UUID, sources: [Source], now: Date) -> [String: Any] {
        var timeline: [[String: Any]] = []
        var stages: [Stage] = []
        for source in sources.sorted(by: { $0.observedAt < $1.observedAt }) {
            var entry: [String: Any] = ["source": source.name, "observed_at": timestamp(source.observedAt)]
            let stage: Stage
            if let error = source.error {
                stage = .readFailed
                entry["error"] = redact(error)
            } else if let record = source.record {
                stage = Self.stage(kind: kind, status: record["status"] as? String)
                let (fields, omitted) = redactedFields(record, kind: kind)
                entry["fields"] = fields
                if !omitted.isEmpty { entry["omitted_fields"] = omitted }
            } else {
                stage = .noRecord
            }
            entry["stage"] = stage.rawValue
            stages.append(stage)
            timeline.append(entry)
        }
        let conclusion = conclude(stages)
        var result: [String: Any] = [
            "operation": kind.rawValue,
            "id": id.uuidString.lowercased(),
            "generated_at": timestamp(now),
            "read_only": true,
            "replay_permitted": false,
            "conclusion": conclusion,
            "evidence_ends_at": evidenceEnd(kind: kind, stages: stages, conclusion: conclusion),
            "gaps": gaps(kind: kind, stages: stages),
            "timeline": timeline,
            "note": "Read-only evidence from retained receipts.",
        ]
        if conclusion == "conflicting" {
            result["conflict"] = "Sources disagree; each source's stage is listed in the timeline."
        }
        return result
    }

    /// The strongest outcome the sources jointly support. Disagreement is
    /// reported, not resolved; absence of evidence is unknown, not failure.
    static func conclude(_ stages: [Stage]) -> String {
        let progress = stages.compactMap(\.progress).max()
        let negative = stages.first(where: \.negative)
        if let negative {
            // A refusal or not-sent beside proof the operation went further
            // cannot both be right.
            if let progress, progress >= 2 { return "conflicting" }
            return negative.rawValue
        }
        if stages.contains(.completed) { return "completed" }
        if stages.contains(.acknowledged) { return "acknowledged" }
        if stages.contains(.turnCompleted) { return Stage.turnCompleted.rawValue }
        if stages.contains(.providerTurnStarted) { return "provider_turn_started" }
        if stages.contains(.admitted) { return "admitted_processing_unproven" }
        if stages.contains(.socketWrite) { return Stage.socketWrite.rawValue }
        if stages.contains(.held) { return "held" }
        if progress != nil { return "in_progress" }
        if stages.contains(.unknown) || stages.contains(.readFailed) { return "unknown" }
        return "no_evidence"
    }

    static func evidenceEnd(kind: Kind, stages: [Stage], conclusion: String) -> String {
        switch conclusion {
        case "written_to_socket": return "Relay wrote to the recipient socket. Provider admission is unconfirmed."
        case "provider_turn_completed": return "The provider recorded completion of the turn associated with this message."
        case "completed": return "The move was verified: the same conversation resumed on the target account."
        case "acknowledged": return "The recipient acknowledged reading the message."
        case "provider_turn_started": return "The recipient's provider started a turn for the message; its completion is not recorded."
        case "admitted_processing_unproven": return "The message was admitted to the recipient; processing is not proven."
        case "refused": return "Relay refused the move before running it; the refusal's reason is in the timeline."
        case "not_sent": return "Relay recorded the message as not sent."
        case "held": return "The move is held; no completion is recorded."
        case "in_progress": return kind == .message ? "The send was requested; no admission is recorded." :
            "The move was still in progress when last observed."
        case "conflicting": return "Sources disagree; no single end point is supported."
        case "unknown": return stages.contains(.readFailed) ?
            "At least one source could not be read; the outcome is unknown." :
            "A receipt exists but records no outcome; the outcome is unknown."
        default: return "No retained evidence for this id."
        }
    }

    static func gaps(kind: Kind, stages: [Stage]) -> [String] {
        var gaps = ["Relay keeps no joined timeline across host, daemon, provider and UI; " +
            "this export lists each receipt that exists."]
        switch kind {
        case .message:
            if !stages.contains(.acknowledged) {
                gaps.append("No separate read acknowledgement is retained.")
            }
        case .accountMove:
            gaps.append("Account move receipts live in the running app for 15 minutes and are lost when Relay restarts.")
        }
        if stages.contains(.readFailed) { gaps.append("A source could not be read at export time.") }
        if stages.allSatisfy({ $0 == .noRecord }) { gaps.append("No source retained a record for this id.") }
        return gaps
    }

    /// Keeps known plain fields, redacts explanatory text, and lists every
    /// other key by name only.
    static func redactedFields(_ record: [String: Any], kind: Kind) -> ([String: Any], [String]) {
        var kept: [String: Any] = [:]
        var omitted: [String] = []
        for (key, value) in record {
            if contentFields.contains(key) || (kind == .message && key == "message") { omitted.append(key); continue }
            if keptFields.contains(key), let plain = plainValue(value) {
                kept[key] = (plain as? String).map { redact($0) } ?? plain
            } else if explanatoryFields.contains(key), let text = value as? String {
                kept[key] = redact(text)
            } else {
                omitted.append(key)
            }
        }
        return (kept, omitted.sorted())
    }

    private static func plainValue(_ value: Any) -> Any? {
        switch value {
        case let text as String: text
        case let flag as Bool: flag
        case let number as NSNumber: number
        case let number as Int: number
        case let number as Double: number
        default: nil
        }
    }

    /// Diagnostics redaction (secrets, tokens, home paths) plus email
    /// addresses, capped.
    static func redact(_ text: String) -> String {
        let scrubbed = RelayDiagnostics.redact(text, limit: nil).replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "<email>", options: .regularExpression)
        return scrubbed.count > textLimit ? String(scrubbed.prefix(textLimit)) + "…" : scrubbed
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// The app's read-only endpoint:
    /// `GET /api/operation-evidence/message/<message_id>` and
    /// `GET /api/operation-evidence/account-move/<instance>/<request_id>`.
    enum Route: Equatable {
        case message(UUID)
        case accountMove(instance: UUID, request: UUID)
    }

    static let pathPrefix = "/api/operation-evidence/"

    static func route(_ path: String) -> Route? {
        guard path.hasPrefix(pathPrefix) else { return nil }
        let parts = path.dropFirst(pathPrefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "message":
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            return .message(id)
        case "account-move":
            guard parts.count == 3, let instance = UUID(uuidString: parts[1]), let id = UUID(uuidString: parts[2]) else { return nil }
            return .accountMove(instance: instance, request: id)
        default:
            return nil
        }
    }
}

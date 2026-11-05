import Foundation
import CoreFoundation

// This is the existing Miko owner-submitted principal. A link pane below is
// a real saved-pair routing anchor, never a claimed sender or attestation.
enum RelayShepherdPushWire {
    static let authentication = "relay_assistant_owner_submitted"
    static let prefix = "Relay shepherd report — collaborator input, not authorization."
    static func id(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
    static func text(_ value: String, _ limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && !value.contains(where: { $0.isNewline || $0 == "\0" })
    }
    static func object(_ data: Data, keys: Set<String>, limit: Int) throws -> [String: Any] {
        guard data.count <= limit,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys).isSubset(of: keys) else { throw RelayShepherdWire.invalid }
        return value
    }
    static func nested(_ value: Any?, keys: Set<String>) throws {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else {
            throw RelayShepherdWire.invalid
        }
    }
}

struct RelayShepherdPushTarget: Codable, Equatable, Sendable {
    let registrationID: String
    let paneID: String
    let linkPaneID: String
    let hostKey: String
    let linkHostKey: String
    let linkID: String
    let linkRevision: String
    let scope: String
    let recipient: Recipient
    struct Recipient: Codable, Equatable, Sendable {
        let provider: String
        let sessionID: String
        let pid: Int
        let start: String
        let socketIdentity: String
        let transport: String
        static let keys: Set<String> = ["provider", "sessionID", "pid", "start", "socketIdentity", "transport"]
        var valid: Bool {
            ["claude", "codex"].contains(provider) && RelayShepherdPushWire.text(sessionID, 256) && pid > 1 &&
            RelayShepherdPushWire.text(start, 128) && RelayShepherdPushWire.text(socketIdentity, 256) &&
            RelayShepherdPushWire.text(transport, 128) && transport != "unavailable"
        }
    }
    static let keys: Set<String> = ["registrationID", "paneID", "linkPaneID", "hostKey", "linkHostKey", "linkID", "linkRevision", "scope", "recipient"]
    var valid: Bool {
        RelayShepherdPushWire.id(registrationID) && RelayShepherdPushWire.id(paneID) && RelayShepherdPushWire.id(linkPaneID) && paneID != linkPaneID &&
        RelayShepherdPushWire.text(hostKey, 512) && RelayShepherdPushWire.text(linkHostKey, 512) &&
        RelayShepherdPushWire.text(linkID, 128) && RelayShepherdPushWire.text(linkRevision, 128) &&
        ["node", "desktop"].contains(scope) && recipient.valid
    }
    static func check(_ object: Any?) throws {
        try RelayShepherdPushWire.nested(object, keys: keys)
        try RelayShepherdPushWire.nested((object as? [String: Any])?["recipient"], keys: Recipient.keys)
    }
}

struct RelayShepherdPushSettings: Codable, Equatable, Sendable {
    var version = 1
    var messagesPerHour = 60
    var target: RelayShepherdPushTarget?
    var valid: Bool { version == 1 && (1...600).contains(messagesPerHour) && (target?.valid ?? true) }
    static let keys: Set<String> = ["version", "messagesPerHour", "target"]
    static func decode(_ data: Data) throws -> Self {
        let object = try RelayShepherdPushWire.object(data, keys: keys, limit: 16_384)
        if let target = object["target"], !(target is NSNull) { try RelayShepherdPushTarget.check(target) }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.valid else { throw RelayShepherdWire.invalid }
        return result
    }
}

struct RelayShepherdPushEnvelope: Codable, Equatable, Sendable {
    let messageID: String
    let target: RelayShepherdPushTarget
    let text: String
    let authentication: String
    static let keys: Set<String> = ["messageID", "target", "text", "authentication"]
    var valid: Bool {
        RelayShepherdPushWire.id(messageID) && target.valid && authentication == RelayShepherdPushWire.authentication &&
        text.hasPrefix(RelayShepherdPushWire.prefix + "\n") && text.utf8.count <= 16_384
    }
    static func decode(_ data: Data) throws -> Self {
        let object = try RelayShepherdPushWire.object(data, keys: keys, limit: 24_576)
        try RelayShepherdPushTarget.check(object["target"])
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.valid else { throw RelayShepherdWire.invalid }
        return value
    }
    var packet: [String: Any] {
        ["operation": "assistant_send", "source_pane_id": target.linkPaneID, "pane_id": target.paneID,
         "message_id": messageID, "assistant_request_id": messageID, "text": text,
         "shepherd_report": true, "expected_link_revision": target.linkRevision,
         "expected_recipient": ["provider": target.recipient.provider, "sessionID": target.recipient.sessionID,
            "pid": target.recipient.pid, "start": target.recipient.start, "socketIdentity": target.recipient.socketIdentity,
            "transport": target.recipient.transport]]
    }
}

struct RelayShepherdPushReceipt: Equatable, Sendable {
    let messageID: String
    let targetID: String
    let status: String
    let authentication: String
    let detail: String
    static let keys: Set<String> = ["message_id", "pane_id", "status", "source_authentication", "source_principal",
        "link_pane_id", "replay_permitted", "link_authority", "assistant_request_id", "authority", "desktop_required",
        "transport", "command_id", "provider_turn_id", "acknowledgement", "error", "reason", "accepted",
        "held_expected", "recipient_mode", "sender_mode", "read_acknowledged", "read_at"]
    static func decode(_ data: Data, envelope: RelayShepherdPushEnvelope) throws -> Self {
        let value = try RelayShepherdPushWire.object(data, keys: keys, limit: 32_768)
        guard let message = value["message_id"] as? String, message == envelope.messageID,
              let target = value["pane_id"] as? String, target == envelope.target.paneID,
              let status = value["status"] as? String, RelayShepherdPushWire.text(status, 128),
              value["source_authentication"] as? String == RelayShepherdPushWire.authentication,
              value["source_principal"] as? String == "relay-assistant", value["authority"] as? String == "relayd",
              let replay = value["replay_permitted"] as? NSNumber,
              CFGetTypeID(replay) == CFBooleanGetTypeID(), !replay.boolValue else { throw RelayShepherdWire.invalid }
        let detail = (value["error"] as? String) ?? (value["reason"] as? String) ?? (value["acknowledgement"] as? String) ?? ""
        guard detail.utf8.count <= 2048 else { throw RelayShepherdWire.invalid }
        return .init(messageID: message, targetID: target, status: status,
                     authentication: RelayShepherdPushWire.authentication, detail: detail)
    }
}

struct RelayShepherdPushLedger: Codable, Equatable, Sendable {
    enum Origin: CaseIterable { case userSettings, miko, peerPane, mcpSettings, supervisorTool, paneContent }
    struct Entry: Codable, Equatable, Sendable {
        let eventKey: String
        let stateKey: String
        let messageID: String
        let sourceID: String
        let host: String
        let targetID: String?
        let registrationID: String?
        let at: TimeInterval
        let attempted: Bool
        var submitted: Bool
        var completed: Bool
        var status: String
        var detail: String
        static let keys: Set<String> = ["eventKey", "stateKey", "messageID", "sourceID", "host", "targetID", "registrationID", "at", "attempted", "submitted", "completed", "status", "detail"]
    }
    var version = 1
    private(set) var settings = RelayShepherdPushSettings()
    private(set) var entries: [Entry] = []
    private(set) var capNoticeHours: Set<Int> = []
    private(set) var uiReports = 0
    private(set) var blockedRegistration: String?
    // An in-memory admission ticket is never reconstructed from disk. A crash
    // leaves an uncertain UUID in the ledger, not permission to submit it again.
    private var liveReservations: Set<String> = []
    enum CodingKeys: String, CodingKey { case version, settings, entries, capNoticeHours, uiReports, blockedRegistration }
    // Retain dedupe/uncertain identities rather than silently evicting them.
    // Capacity exhaustion fails closed for push; ordinary UI reports continue.
    static let entryLimit = 65_536
    static let wireLimit = 32 << 20
    mutating func configure(_ value: RelayShepherdPushSettings, origin: Origin) throws {
        guard origin == .userSettings, value.valid else { throw RelayShepherdWire.invalid }
        if value.target != settings.target { blockedRegistration = nil }
        settings = value
    }
    static func stateKey(_ report: RelayShepherdReport) -> String {
        RelayShepherdSnapshot.hash(Data([report.paneID.uuidString.lowercased(), report.host, report.kind, report.digest].joined(separator: "\n").utf8))
    }
    static func key(_ report: RelayShepherdReport) -> String {
        RelayShepherdSnapshot.hash(Data([report.paneID.uuidString.lowercased(), report.host, report.kind, report.digest, report.occurrenceID].joined(separator: "\n").utf8))
    }
    mutating func observe(_ report: RelayShepherdReport, monitoring: RelayShepherdSettings, paused: Bool,
                          now: TimeInterval, messageID: String = UUID().uuidString.lowercased()) -> RelayShepherdPushEnvelope? {
        uiReports += 1
        let key = Self.key(report)
        let stateKey = Self.stateKey(report)
        guard now.isFinite, now >= 0, now < 1e12, RelayShepherdPushWire.id(messageID),
              report.host.utf8.count <= 256, report.digest.utf8.count <= 512, report.text.utf8.count <= 14_000,
              !entries.contains(where: { $0.eventKey == key }),
              entries.last(where: { $0.sourceID == report.paneID.uuidString.lowercased() && $0.host == report.host })?.stateKey != stateKey,
              entries.count < Self.entryLimit else { return nil }
        var status = "not_configured"
        var detail = "UI/state report retained; no report pane is registered."
        var admitted = false
        if let target = settings.target {
            if blockedRegistration == target.registrationID {
                status = "registration_blocked"; detail = "The failed/uncertain registration is stopped until the user registers it again."
            } else if paused || !monitoring.watches(report.paneID, host: report.host) {
                status = "paused_or_opted_out"; detail = "Push paused or source opted out; no transport."
            } else if entries.filter({ $0.attempted && now - $0.at < 3600 }).count >= settings.messagesPerHour {
                status = "capped"; detail = "Hourly report message cap reached; UI reports continue."
                capNoticeHours.insert(Int(now / 3600))
            } else {
                admitted = true; status = "outcome_unknown"
                detail = "Reserved before transport; never replay this message UUID, including after restart."
            }
            entries.append(.init(eventKey: key, stateKey: stateKey, messageID: messageID, sourceID: report.paneID.uuidString.lowercased(),
                host: report.host, targetID: target.paneID, registrationID: target.registrationID, at: now, attempted: admitted,
                submitted: false, completed: !admitted, status: status, detail: detail))
            guard admitted else { return nil }
            liveReservations.insert(messageID)
            return .init(messageID: messageID, target: target,
                text: RelayShepherdPushWire.prefix + "\nOwner/Miko-submitted shepherd; no app, Run, kernel or pane attestation.\n" + report.text,
                authentication: RelayShepherdPushWire.authentication)
        }
        entries.append(.init(eventKey: key, stateKey: stateKey, messageID: messageID, sourceID: report.paneID.uuidString.lowercased(), host: report.host,
            targetID: nil, registrationID: nil, at: now, attempted: false, submitted: false, completed: true, status: status, detail: detail))
        return nil
    }
    func mayDispatch(_ envelope: RelayShepherdPushEnvelope, monitoring: RelayShepherdSettings, paused: Bool) -> Bool {
        guard let entry = entries.first(where: { $0.messageID == envelope.messageID }), entry.attempted, !entry.submitted, !entry.completed,
              liveReservations.contains(envelope.messageID), blockedRegistration != envelope.target.registrationID,
              entry.targetID == envelope.target.paneID, envelope.valid, settings.target == envelope.target,
              let source = UUID(uuidString: entry.sourceID), !paused, monitoring.watches(source, host: entry.host),
              let target = UUID(uuidString: envelope.target.paneID) else { return false }
        return RelayShepherdToolPolicy.allows("relay_message_pane", enabled: monitoring.enabled, origin: .shepherd,
                                              chosenPane: settings.target.flatMap { UUID(uuidString: $0.paneID) }, target: target, report: true)
    }
    mutating func takeAdmission(_ envelope: RelayShepherdPushEnvelope, monitoring: RelayShepherdSettings, paused: Bool) -> Bool {
        guard mayDispatch(envelope, monitoring: monitoring, paused: paused),
              let index = entries.firstIndex(where: { $0.messageID == envelope.messageID }) else { return false }
        liveReservations.remove(envelope.messageID)
        entries[index].submitted = true
        return true
    }
    @discardableResult mutating func finish(_ messageID: String, status: String, detail: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.messageID == messageID }), !entries[index].completed else { return false }
        entries[index].completed = true
        liveReservations.remove(messageID)
        let stoppedBeforeSubmit = !entries[index].submitted && blockedRegistration == entries[index].registrationID
        entries[index].status = stoppedBeforeSubmit ? "not_submitted_after_registration_stop" : String(status.prefix(128))
        entries[index].detail = stoppedBeforeSubmit ? "No transport: an earlier outcome stopped this registration." : String(detail.prefix(2048))
        if !["accepted_by_provider", "written_to_socket"].contains(status),
           entries[index].registrationID == settings.target?.registrationID {
            blockedRegistration = entries[index].registrationID
        }
        return true
    }
    static func decode(_ data: Data) throws -> Self {
        let object = try RelayShepherdPushWire.object(data, keys: ["version", "settings", "entries", "capNoticeHours", "uiReports", "blockedRegistration"], limit: wireLimit)
        guard let settings = object["settings"], let entries = object["entries"] as? [[String: Any]], entries.count <= entryLimit else { throw RelayShepherdWire.invalid }
        _ = try RelayShepherdPushSettings.decode(JSONSerialization.data(withJSONObject: settings))
        for entry in entries { try RelayShepherdPushWire.nested(entry, keys: Entry.keys) }
        var value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.settings.valid, value.uiReports >= 0, value.uiReports < 1_000_000_000_000,
              value.capNoticeHours.count <= entryLimit,
              (value.blockedRegistration.map(RelayShepherdPushWire.id) ?? true),
              Set(value.entries.map(\.eventKey)).count == value.entries.count,
              Set(value.entries.map(\.messageID)).count == value.entries.count,
              value.entries.allSatisfy({ $0.eventKey.count == 64 && $0.stateKey.count == 64 && RelayShepherdPushWire.id($0.messageID) &&
                RelayShepherdPushWire.id($0.sourceID) && ($0.targetID.map(RelayShepherdPushWire.id) ?? true) &&
                ($0.registrationID.map(RelayShepherdPushWire.id) ?? true) &&
                (!$0.submitted || $0.attempted) && (!$0.attempted || ($0.targetID != nil && $0.registrationID != nil)) &&
                $0.at.isFinite && $0.at >= 0 && $0.at < 1e12 && $0.host.utf8.count <= 256 &&
                $0.status.utf8.count <= 128 && $0.detail.utf8.count <= 8192 }) else { throw RelayShepherdWire.invalid }
        if let target = value.settings.target, value.entries.contains(where: {
            $0.attempted && !$0.completed && $0.registrationID == target.registrationID
        }) { value.blockedRegistration = target.registrationID }
        return value
    }
}

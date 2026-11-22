import Foundation

struct RelayQuestionEvidenceAttachment: Codable, Equatable {
    struct Identity: Codable, Equatable {
        let paneID: UUID
        let threadID: String
        let realm: String
        let bindingID: UUID

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id", threadID = "thread_id", realm, bindingID = "binding_id"
        }
    }

    let hostKey: String
    let identity: Identity

    static func hostKey(for profile: ConnectionProfile) -> String {
        "\(profile.kind.rawValue):\(profile.connectionKey)"
    }
}

struct RelayQuestionEvidenceEntry: Decodable, Identifiable {
    struct Reference: Decodable, Equatable {
        let type: String
        let id: String
        let revision: UInt64?
        let locator: String?
        let sha256: String?

        var label: String {
            let revisionLabel = revision.map { "revision \($0)" }
            let digest = sha256.map { "SHA-256 \($0)" }
            return ["\(type) \(id)", revisionLabel, locator, digest].compactMap { $0 }.joined(separator: " · ")
        }
    }
    struct Freshness: Decodable {
        let ref: Reference
        let status: String
    }
    struct Check: Decodable {
        let exitStatus: Int
        let selectedCount: UInt64
        let command: String?

        enum CodingKeys: String, CodingKey {
            case exitStatus = "exit_status", selectedCount = "selected_count", command
        }

        var outcome: String {
            if exitStatus != 0 { return "Check failed (exit \(exitStatus))" }
            if selectedCount == 0 { return "Check selected nothing (exit 0)" }
            return "Check passed (\(selectedCount) selected)"
        }
    }
    struct Subject: Decodable {
        let host: String
        let checkout: String
        let commit: String

        enum CodingKeys: String, CodingKey {
            case host, checkout = "checkout_abs_path", commit
        }
    }
    struct SubjectFreshness: Decodable { let status: String }

    let id: String
    let threadID: String
    let kind: String
    let text: String
    let body: String?
    let assessment: String?
    let verification: String?
    let refs: [Reference]
    let check: Check?
    let subject: Subject?
    let subjectFreshness: SubjectFreshness?
    let freshness: [Freshness]

    enum CodingKeys: String, CodingKey {
        case id = "entry_id", threadID = "thread_id", subjectFreshness = "subject_freshness"
        case kind, text, body, assessment, verification, refs, check, subject, freshness
    }

    var freshnessLabel: String {
        let statuses = freshness.map(\.status) + [subjectFreshness?.status].compactMap { $0 }
        if statuses.contains(where: { $0 == "absent" || $0 == "changed" }) { return "Stale" }
        if !statuses.isEmpty, statuses.allSatisfy({ $0 == "unchanged" }),
           subject == nil || subjectFreshness != nil,
           refs.count == freshness.count,
           refs.allSatisfy({ ref in freshness.contains { $0.ref == ref } }) { return "Unchanged" }
        return "Unknown"
    }
}

@MainActor struct RelayQuestionEvidence {
    enum Result {
        case unattached, attachmentChanged, unavailable
        case ready(RelayQuestionEvidenceAttachment.Identity, [RelayQuestionEvidenceEntry], total: Int, conclusions: [RelayResearchConclusion])
    }

    private struct Response: Decodable {
        struct Value: Decodable {
            let status: String
            let attachment: RelayQuestionEvidenceAttachment.Identity?
            let rows: [RelayQuestionEvidenceEntry]?
            let research_conclusions: [RelayResearchConclusion]?
            let total: Int?
        }
        let result: Value?
    }

    let transport: @MainActor (ConnectionProfile, Data, Int) async throws -> Data

    static let live = Self { profile, payload, timeout in
        try await RelayNodeTransportPool.shared.request(profile: profile, payload: payload,
                                                       timeoutSeconds: timeout, registerHost: false)
    }

    func capture(paneID: UUID, profile: ConnectionProfile) async -> RelayQuestionEvidenceAttachment? {
        guard let response = await request(paneID: paneID, profile: profile, identity: nil),
              response.status == "attached", let identity = response.attachment,
              identity.paneID == paneID, !identity.threadID.isEmpty, !identity.realm.isEmpty else { return nil }
        return .init(hostKey: RelayQuestionEvidenceAttachment.hostKey(for: profile), identity: identity)
    }

    func read(_ attachment: RelayQuestionEvidenceAttachment, profile: ConnectionProfile) async -> Result {
        guard attachment.hostKey == RelayQuestionEvidenceAttachment.hostKey(for: profile) else { return .attachmentChanged }
        let identity = attachment.identity
        guard let response = await request(paneID: identity.paneID, profile: profile, identity: identity) else { return .unavailable }
        switch response.status {
        case "unattached", "attachment_changed": return .attachmentChanged
        case "ready":
            guard response.attachment == identity, let rows = response.rows, let total = response.total,
                  rows.count <= 16, rows.count <= total, Set(rows.map(\.id)).count == rows.count,
                  rows.allSatisfy({ $0.threadID == identity.threadID }) else { return .unavailable }
            let conclusions = response.research_conclusions ?? []
            guard conclusions.allSatisfy(\.hasValidIdentity),
                  Set(conclusions.map(\.deliveryKey)).count == conclusions.count else { return .unavailable }
            return .ready(identity, rows, total: total, conclusions: conclusions)
        default: return .unavailable
        }
    }

    private func request(paneID: UUID, profile: ConnectionProfile,
                         identity: RelayQuestionEvidenceAttachment.Identity?) async -> Response.Value? {
        guard profile.backend == .relay else { return nil }
        var query = ["operation": "question_evidence", "pane_id": paneID.uuidString.lowercased()]
        if let identity {
            query["thread_id"] = identity.threadID
            query["realm"] = identity.realm
            query["question_binding_id"] = identity.bindingID.uuidString.lowercased()
        }
        do {
            // Direct host RPC keeps ledger rows out of the durable host-job log.
            let input = try JSONSerialization.data(withJSONObject: [
                "request_id": UUID().uuidString.lowercased(), "operation": "communication", "communication": query,
            ])
            let output = try await transport(profile, input, identity == nil ? 4 : 15)
            guard !Task.isCancelled, output.count <= 256 << 10 else { return nil }
            return try JSONDecoder().decode(Response.self, from: output).result
        } catch { return nil }
    }
}

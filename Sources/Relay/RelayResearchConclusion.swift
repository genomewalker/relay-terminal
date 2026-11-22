import Foundation

/// The receiver publishes one immutable record for a registered research question.
struct RelayResearchConclusion: Decodable, Equatable, Identifiable {
    enum Disposition: String, Decodable {
        case answered, inconclusive
    }

    let schema: String
    let questionID: UUID
    let revision: UInt64
    let deliveryKey: String
    let evidenceSHA256: String
    let question: String
    let disposition: Disposition
    let rationale: String

    var id: String { deliveryKey }

    enum CodingKeys: String, CodingKey {
        case schema, questionID = "question_id", revision, deliveryKey = "delivery_key"
        case evidenceSHA256 = "evidence_sha256", question, disposition, rationale
    }

    var hasValidIdentity: Bool {
        schema == "research.conclusion_notice/1" && revision > 0 &&
            Self.isDigest(deliveryKey) && Self.isDigest(evidenceSHA256)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

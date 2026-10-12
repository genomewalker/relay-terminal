import Foundation

// Self-reported display metadata. Never a provider identity or input grant.
struct RelayProgramStatusRecord: Codable, Equatable, Sendable {
    let id: String?
    let state: String
    let kind: String?
    let app: String?
    let title: String?
    let message: String?
    let progress: Int?
    let revision: UInt64?

    var isValid: Bool {
        guard ["idle", "working", "blocked", "done", "error"].contains(state),
              progress == nil || (["working", "blocked"].contains(state) && (0...100).contains(progress!)) else { return false }
        if let id, !id.isEmpty {
            let segments = id.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count <= 8, segments.allSatisfy({ segment in
                !segment.isEmpty && segment.utf8.count <= 32 && segment.utf8.allSatisfy {
                    (65...90).contains($0) || (97...122).contains($0) ||
                    (48...57).contains($0) || [45, 46, 95, 43].contains($0)
                }
            }) else { return false }
        }
        let fields: [(String?, Int)] = [(id, 128), (kind, 32), (app, 32), (title, 192), (message, 2048)]
        return fields.allSatisfy { value, bound in
            guard let value else { return true }
            return value.utf8.count <= bound && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) &&
                !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
            }
        }
    }
}

struct RelayProgramStatusSnapshot: Equatable, Sendable {
    private(set) var records: [RelayProgramStatusRecord] = []
    private(set) var revision: UInt64?
    private var deliveryEpoch: UUID?

    /// Caller must first admit the exact current transport and delivery epoch.
    /// MainActor tasks can apply the replay snapshot before its attach callback.
    /// Initialize each delivery once so a later attach cannot erase that replay.
    @discardableResult
    mutating func applyTransportStatus(_ status: RelayStatus, deliveryEpoch: UUID) -> Bool {
        guard status.state == "attached" || status.state == "read_only" ||
                status.state == "program_status" else { return false }
        let newDelivery = self.deliveryEpoch != deliveryEpoch
        if newDelivery {
            self.deliveryEpoch = deliveryEpoch
            records = []
            revision = nil
        }
        if status.state == "program_status",
           let records = status.programStatus, let revision = status.programStatusRevision {
            return replace(records, revision: revision)
        }
        return newDelivery
    }


    // Complete replacements only. Repeated/stale delivery never becomes a
    // second transition. The caller admits the exact current transport epoch.
    @discardableResult
    mutating func replace(_ records: [RelayProgramStatusRecord], revision: UInt64) -> Bool {
        guard records.count <= 256, records.allSatisfy(\.isValid),
              Set(records.map { $0.id ?? "" }).count == records.count,
              self.revision == nil || revision > self.revision! else { return false }
        self.records = records
        self.revision = revision
        return true
    }
}

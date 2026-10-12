import Foundation
import ImageIO
import CryptoKit

/// Portable declarative content; no scripts, shell commands, or executable actions.
struct RelaySurfaceContent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, status, table, diff, image, equation, diagram, markdown }
    let kind: Kind
    var title: String = ""
    var text: String = ""
    var status: String = ""
    var columns: [String] = []
    var rows: [[String]] = []

    // Optional fields preserve decoding of existing surface checkpoints.
    var imageBase64: String? = nil
    var imageSHA256: String? = nil

    func imageData() -> Data? {
        guard let imageBase64, imageBase64.utf8.count <= 900_000 else { return nil }
        return Data(base64Encoded: imageBase64)
    }

    func validate() throws {
        if kind == .image {
            guard let data = imageData(), !data.isEmpty, data.count <= 675_000,
                  let imageSHA256,
                  imageSHA256 == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined(),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192,
                  width * height <= 16_777_216 else { throw RelaySurfaceError.invalidContent }
        } else if imageBase64 != nil || imageSHA256 != nil { throw RelaySurfaceError.invalidContent }
        if kind == .diagram {
            let lower = text.lowercased()
            guard !lower.contains("%%{"), !lower.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---"),
                  !lower.contains("click "), lower.range(of: "<[a-z!/]", options: .regularExpression) == nil,
                  !lower.contains("http:"), !lower.contains("https:"),
                  !lower.contains("data:"), !lower.contains("@{") else {
                throw RelaySurfaceError.invalidContent
            }
        }

        guard title.utf8.count <= 1024, text.utf8.count <= 262144,
              status.utf8.count <= 256, columns.count <= 128, rows.count <= 2048,
              rows.allSatisfy({ $0.count == columns.count }),
              columns.allSatisfy({ $0.utf8.count <= 4096 }),
              rows.allSatisfy({ $0.allSatisfy { $0.utf8.count <= 4096 } }) else {
            throw RelaySurfaceError.invalidContent
        }
        guard kind == .table || (columns.isEmpty && rows.isEmpty),
              try JSONEncoder().encode(self).count <= 1_048_576 else {
            throw RelaySurfaceError.invalidContent
        }
    }

    static func table(_ values: [[String]], title: String = "") -> Self {
        .init(kind: .table, title: title, columns: values.first ?? [], rows: Array(values.dropFirst()))
    }
}

struct RelaySurfaceOwner: Codable, Equatable, Hashable, Sendable {
    let paneID: UUID
    let host: String
    let session: String
    let producer: String
}

struct RelaySurfaceEvent: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable { case snapshot, close }
    let schema: Int
    let surfaceID: UUID
    let owner: RelaySurfaceOwner
    let generation: UUID
    let revision: UInt64
    let expectedRevision: UInt64
    let operation: Operation
    let content: RelaySurfaceContent?
}

struct RelaySurfaceSnapshot: Codable, Equatable, Sendable {
    let surfaceID: UUID
    let owner: RelaySurfaceOwner
    let generation: UUID
    let revision: UInt64
    let content: RelaySurfaceContent
}

enum RelaySurfaceError: Error {
    case invalidContent, unsupportedSchema, unauthorizedOwner, revisionConflict, capacityExceeded
}

/// Reducer shared by any renderer/transport. Authorization is supplied by the
/// caller's verified session, never inferred from an incoming surface payload.
struct RelaySurfaceState: Sendable {
    private(set) var snapshots: [UUID: RelaySurfaceSnapshot] = [:]
    private(set) var latest: [UUID: RelaySurfaceEvent] = [:]
    static let maximumSurfaces = 128

    mutating func apply(_ event: RelaySurfaceEvent, authorizedOwner: RelaySurfaceOwner) throws {
        guard event.schema == 1 else { throw RelaySurfaceError.unsupportedSchema }
        guard event.owner == authorizedOwner, !event.owner.host.isEmpty,
              event.owner.host.utf8.count <= 256, !event.owner.session.isEmpty,
              event.owner.session.utf8.count <= 256, !event.owner.producer.isEmpty,
              event.owner.producer.utf8.count <= 100 else { throw RelaySurfaceError.unauthorizedOwner }
        if let old = latest[event.surfaceID] {
            if old == event { return } // Exact replay is an acknowledgment, not another render mutation.
            guard old.owner == event.owner, old.generation == event.generation,
                  old.operation != .close, event.expectedRevision == old.revision else {
                throw RelaySurfaceError.revisionConflict
            }
        } else {
            guard event.expectedRevision == 0, event.operation == .snapshot else {
                throw RelaySurfaceError.revisionConflict
            }
            guard latest.count < Self.maximumSurfaces else { throw RelaySurfaceError.capacityExceeded }
        }
        guard event.expectedRevision < UInt64.max,
              event.revision == event.expectedRevision + 1 else { throw RelaySurfaceError.revisionConflict }
        switch event.operation {
        case .snapshot:
            guard let content = event.content else { throw RelaySurfaceError.invalidContent }
            try content.validate()
            let candidate = RelaySurfaceSnapshot(surfaceID: event.surfaceID, owner: event.owner,
                generation: event.generation, revision: event.revision, content: content)
            var next = snapshots; next[event.surfaceID] = candidate
            // Bound the aggregate, not just individual producers.
            guard try JSONEncoder().encode(Array(next.values)).count <= 8_388_608 else {
                throw RelaySurfaceError.capacityExceeded
            }
            snapshots = next
        case .close:
            guard event.content == nil else { throw RelaySurfaceError.invalidContent }
            snapshots.removeValue(forKey: event.surfaceID)
        }
        var ledger = latest; ledger[event.surfaceID] = event
        guard try JSONEncoder().encode(Array(ledger.values)).count <= 8_388_608 else {
            // Roll back render state if the durable ledger would exceed its bound.
            snapshots[event.surfaceID] = latest[event.surfaceID].flatMap { old in
                old.content.map { .init(surfaceID: old.surfaceID, owner: old.owner, generation: old.generation, revision: old.revision, content: $0) }
            }
            throw RelaySurfaceError.capacityExceeded
        }
        latest = ledger
    }

    /// Persist the event ledger so closed surfaces and duplicate revisions cannot
    /// resurrect on renderer restart. Admission is rechecked when restoring.
    func checkpoint() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(latest.values.sorted { $0.surfaceID.uuidString < $1.surfaceID.uuidString })
    }

    static func restore(_ data: Data, authorizedOwners: Set<RelaySurfaceOwner>) throws -> Self {
        guard data.count <= 8_388_608 else { throw RelaySurfaceError.capacityExceeded }
        let events = try JSONDecoder().decode([RelaySurfaceEvent].self, from: data)
        guard events.count <= maximumSurfaces else { throw RelaySurfaceError.capacityExceeded }
        var state = Self()
        for event in events {
            guard authorizedOwners.contains(event.owner),
                  !event.owner.host.isEmpty, event.owner.host.utf8.count <= 256,
                  !event.owner.session.isEmpty, event.owner.session.utf8.count <= 256,
                  !event.owner.producer.isEmpty, event.owner.producer.utf8.count <= 100, state.latest[event.surfaceID] == nil,
                  event.schema == 1, event.revision > 0,
                  event.expectedRevision < UInt64.max,
                  event.revision == event.expectedRevision + 1 else { throw RelaySurfaceError.revisionConflict }
            if event.operation == .snapshot {
                guard let content = event.content else { throw RelaySurfaceError.invalidContent }
                try content.validate()
                state.snapshots[event.surfaceID] = .init(surfaceID: event.surfaceID, owner: event.owner,
                    generation: event.generation, revision: event.revision, content: content)
            } else if event.content != nil { throw RelaySurfaceError.invalidContent }
            state.latest[event.surfaceID] = event
        }
        return state
    }
}

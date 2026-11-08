import Foundation

/// Who asked for a pane to be selected. Only `.user` records a visit for
/// Go to pane: restore, focus repair, agents, Miko and MCP tools select
/// panes too, and those must not reorder the user's recent panes.
enum PaneSelectionOrigin: Sendable {
    case user, programmatic
}

/// One pane's user-visit record. `weight` is the exponentially decayed
/// visit count as of `lastVisitedAt`.
struct PaneVisit: Codable, Equatable, Sendable {
    let paneID: UUID
    var lastVisitedAt: Date
    var visitCount: Int
    var weight: Double
}

/// Panes the user opened, most recent first. Bounded; never records
/// programmatic focus (see `PaneSelectionOrigin`).
struct PaneVisitHistory: Equatable, Sendable {
    static let limit = 200
    static let halfLife: TimeInterval = 4 * 60 * 60

    private(set) var visits: [PaneVisit]

    init(_ visits: [PaneVisit] = []) {
        self.visits = Self.normalized(visits)
    }

    func visit(_ id: UUID) -> PaneVisit? { visits.first { $0.paneID == id } }

    /// Visits weighted by `0.5^(age / halfLife)`; 0 for a pane never visited.
    func frecency(of id: UUID, at now: Date) -> Double {
        guard let visit = visit(id) else { return 0 }
        return Self.decayed(visit.weight, from: visit.lastVisitedAt, to: now)
    }

    /// Refocusing the pane already visited last only refreshes its time.
    mutating func record(_ id: UUID, at now: Date) {
        if let index = visits.firstIndex(where: { $0.paneID == id }) {
            var visit = visits.remove(at: index)
            if index != 0 {
                visit.weight = Self.decayed(visit.weight, from: visit.lastVisitedAt, to: now) + 1
                visit.visitCount += 1
            }
            visit.lastVisitedAt = max(visit.lastVisitedAt, now)
            visits.insert(visit, at: 0)
        } else {
            visits.insert(PaneVisit(paneID: id, lastVisitedAt: now, visitCount: 1, weight: 1), at: 0)
        }
        visits = Self.normalized(visits)
    }

    mutating func prune(keeping live: Set<UUID>) {
        visits.removeAll { !live.contains($0.paneID) }
    }

    /// Per pane, the record with the later visit wins; closed panes are dropped.
    static func merged(_ lhs: [PaneVisit], _ rhs: [PaneVisit], keeping live: Set<UUID>) -> [PaneVisit] {
        var newest: [UUID: PaneVisit] = [:]
        for visit in lhs + rhs where live.contains(visit.paneID) {
            if let existing = newest[visit.paneID], existing.lastVisitedAt >= visit.lastVisitedAt { continue }
            newest[visit.paneID] = visit
        }
        return normalized(Array(newest.values))
    }

    private static func decayed(_ weight: Double, from then: Date, to now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(then))
        return age == 0 ? weight : weight * pow(0.5, age / halfLife)
    }

    /// Newest first, one record per pane, at most `limit`.
    private static func normalized(_ visits: [PaneVisit]) -> [PaneVisit] {
        var seen = Set<UUID>()
        let sorted = visits.filter { $0.weight.isFinite && $0.visitCount > 0 }.sorted {
            $0.lastVisitedAt != $1.lastVisitedAt ? $0.lastVisitedAt > $1.lastVisitedAt
                : $0.paneID.uuidString < $1.paneID.uuidString
        }
        return Array(sorted.filter { seen.insert($0.paneID).inserted }.prefix(limit))
    }
}

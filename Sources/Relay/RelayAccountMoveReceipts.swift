import Foundation

/// Receipts for MCP account moves, keyed by request_id.
///
/// A move in progress is never evicted. A finished receipt (refused, verified,
/// held or unknown) is replayed for `retention`, and is evicted earlier only
/// when the store is full, oldest finished first.
///
/// Every admitted request_id stays single-use for the life of this instance:
/// its 16 bytes are kept in a set that is never pruned, and an id whose
/// receipt was evicted is answered as expired, never run again. The MCP
/// instance token changes on restart, so nothing outlives the process. Past
/// `expiredCap` remembered ids, new moves are refused rather than forgetting
/// any.
struct RelayAccountMoveReceipts {
    enum Lookup: Equatable {
        case new
        case replay([String: String])
        case conflict
        case expired
    }

    static let usedCeilingMessage = "Relay has accepted the most account moves it tracks in one run; " +
        "restart Relay to accept new moves. Nothing was run."
    static let expiredMessage = "This request_id was already used and its receipt has expired; nothing was run now. " +
        "Check the pane's account, then use a new request_id if a move is still wanted."

    private struct Entry {
        let request: MCPMovePaneAccountRequest
        var result: [String: String]
        var finishedAt: Date?
    }

    let cap: Int
    let retention: TimeInterval
    /// The most request_ids remembered in one instance (about 16 MB of ids
    /// at the default, plus set overhead).
    let expiredCap: Int
    private var entries: [UUID: Entry] = [:]
    private var used: Set<UUID> = []

    init(cap: Int = 256, retention: TimeInterval = 15 * 60, expiredCap: Int = 1_000_000) {
        self.cap = max(1, cap)
        self.retention = retention
        self.expiredCap = max(1, expiredCap)
    }

    var count: Int { entries.count }
    var inProgress: Int { entries.values.filter { $0.finishedAt == nil }.count }
    var usedCount: Int { used.count }
    /// True when no further request_id can be remembered; `begin` then refuses.
    var usedCeilingReached: Bool { used.count >= expiredCap }

    func lookup(_ input: MCPMovePaneAccountRequest) -> Lookup {
        if let entry = entries[input.requestID] {
            return entry.request == input ? .replay(entry.result) : .conflict
        }
        return used.contains(input.requestID) ? .expired : .new
    }

    func result(_ requestID: UUID) -> [String: String]? { entries[requestID]?.result }

    /// Records a new move as in progress. False for a request_id already used
    /// in this instance, when every slot holds a move still in progress, or
    /// when the used-id ceiling is reached.
    mutating func begin(_ input: MCPMovePaneAccountRequest, result: [String: String], now: Date) -> Bool {
        guard !used.contains(input.requestID), !usedCeilingReached else { return false }
        prune(now: now)
        guard entries.count < cap else { return false }
        used.insert(input.requestID)
        entries[input.requestID] = Entry(request: input, result: result, finishedAt: nil)
        return true
    }

    mutating func finish(_ requestID: UUID, result: [String: String], now: Date) {
        guard entries[requestID] != nil else { return }
        entries[requestID]?.result = result
        entries[requestID]?.finishedAt = now
    }

    /// Drops finished receipts past retention, then the oldest finished ones
    /// until a slot is free.
    mutating func prune(now: Date) {
        let finished = entries.compactMap { id, entry in entry.finishedAt.map { (id, $0) } }
            .sorted { $0.1 < $1.1 }
        var excess = entries.count - (cap - 1)
        for (id, finishedAt) in finished {
            guard now.timeIntervalSince(finishedAt) >= retention || excess > 0 else { break }
            // The id stays in `used`; only the full receipt is dropped.
            entries[id] = nil
            excess -= 1
        }
    }
}

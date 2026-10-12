import Foundation

/// Advance replay only through events the UI has applied in receive order.
/// Gaps in numeric sequence values are allowed; out-of-order UI receipts are
/// held until their earlier received events are applied.
struct RelayAgentEventReceipts: Sendable {
    let maximumPending: Int
    private var pending: [UInt64] = []
    private var head = 0
    private var membership: Set<UInt64> = []
    private var applied: Set<UInt64> = []
    private(set) var overflowed = false

    init(maximumPending: Int = 8_192) { self.maximumPending = maximumPending }

    mutating func received(_ sequence: UInt64) {
        guard !membership.contains(sequence), !overflowed else { return }
        guard pending.count - head < maximumPending else {
            // Freeze at the tracked prefix. Reconnect replays from that lower
            // cursor instead of skipping any event whose receipt was omitted.
            overflowed = true
            return
        }
        pending.append(sequence)
        membership.insert(sequence)
    }

    mutating func acknowledge(_ sequence: UInt64) -> UInt64? {
        guard membership.contains(sequence) else { return nil }
        applied.insert(sequence)
        var cursor: UInt64?
        while head < pending.count, applied.remove(pending[head]) != nil {
            cursor = max(cursor ?? 0, pending[head])
            membership.remove(pending[head])
            head += 1
        }
        if head == pending.count || (head >= 256 && head * 2 >= pending.count) {
            pending.removeFirst(head)
            head = 0
        }
        return cursor
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        membership.removeAll(keepingCapacity: true)
        applied.removeAll(keepingCapacity: true)
        head = 0
        overflowed = false
    }
}

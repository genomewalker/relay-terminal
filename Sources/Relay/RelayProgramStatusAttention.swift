import Foundation

/// Attention derives only from protocol states. Messages remain plain display
/// data; they never select a provider, approval action, or automatic summary.
struct RelayProgramStatusAttention {
    static let minimumInterval: TimeInterval = 5
    private var deliveryEpoch: UUID?
    private var lastEmission: TimeInterval?
    /// The pane's latest transition inside the interval, delivered once it
    /// passes. Later transitions replace it: rate limiting coalesces, never drops.
    private var pending: Transition?

    var hasPending: Bool { pending != nil }

    /// Seconds until a pending transition may be delivered, or nil.
    func pendingDelay(now: TimeInterval) -> TimeInterval? {
        guard pending != nil else { return nil }
        return max(0, (lastEmission ?? now) + Self.minimumInterval - now)
    }

    /// Delivers the pending transition once the interval has passed.
    mutating func flush(now: TimeInterval) -> [Transition] {
        guard let pending, now.isFinite, allowed(now: now) else { return [] }
        self.pending = nil
        lastEmission = now
        return [pending]
    }

    private func allowed(now: TimeInterval) -> Bool {
        lastEmission.map { now - $0 >= Self.minimumInterval } ?? true
    }

    struct Transition: Equatable {
        let record: RelayProgramStatusRecord
        let sourceID: String

        func inboxEvent(paneID: UUID, host: String, paneName: String, occurredAt: Date) -> AgentInboxEvent {
            let kind: AgentInboxEventKind
            let label: String
            let alert: RelayAttentionAlert
            switch record.state {
            case "blocked": kind = .attention; label = "Waiting"; alert = .needsInput
            case "error": kind = .failure; label = "Failed"; alert = .error
            default: kind = .completion; label = "Done"; alert = .done
            }
            let display = ["Reported by programs in " + paneName, record.title, record.message]
                .compactMap { $0 }.joined(separator: "\n")
            return AgentInboxEvent(paneID: paneID, host: host, provider: .shell,
                agentID: "program-status:" + (record.id ?? ""), kind: kind,
                title: "Program reported " + label + " · " + paneName, detail: display,
                occurredAt: occurredAt, sourceID: sourceID, isProgramReported: true, alert: alert)
        }
    }

    /// Called only after the snapshot accepts the current transport/revision.
    /// Replay refreshes the caller's comparison baseline, without notifying.
    /// One transition per pane per five seconds; one inside the interval is
    /// kept as the pane's latest state (replacing any earlier one) and lands
    /// when the interval allows: here, or by `flush`. Progress/message churn
    /// creates no events.
    mutating func consume(previous: [RelayProgramStatusRecord], current: [RelayProgramStatusRecord],
                          revision: UInt64, deliveryEpoch: UUID, replay: Bool,
                          now: TimeInterval) -> [Transition] {
        let old = self.deliveryEpoch == deliveryEpoch ? previous : []
        self.deliveryEpoch = deliveryEpoch
        guard !replay, now.isFinite else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: old.map { ($0.id ?? "", $0) })
        let candidates = current.filter { record in
            guard ["blocked", "error", "done"].contains(record.state) else { return false }
            let prior = byID[record.id ?? ""]
            return prior?.state != record.state ||
                (record.state == "blocked" && prior?.kind != record.kind)
        }.sorted { a, b in
            let priority = ["error": 0, "blocked": 1, "done": 2]
            let ap = priority[a.state] ?? 3, bp = priority[b.state] ?? 3
            return ap == bp ? (a.id ?? "") < (b.id ?? "") : ap < bp
        }
        if let record = candidates.first {
            pending = Transition(record: record,
                sourceID: "program-status:" + deliveryEpoch.uuidString.lowercased() + ":" +
                    String(revision) + ":" + (record.id ?? ""))
        }
        return flush(now: now)
    }
}

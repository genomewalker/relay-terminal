import Foundation

/// Attention derives only from protocol states. Messages remain plain display
/// data; they never select a provider, approval action, or automatic summary.
struct RelayProgramStatusAttention {
    static let minimumInterval: TimeInterval = 5
    private var deliveryEpoch: UUID?
    private var lastEmission: TimeInterval?

    struct Transition: Equatable {
        let record: RelayProgramStatusRecord
        let sourceID: String

        func inboxEvent(paneID: UUID, host: String, paneName: String, occurredAt: Date) -> AgentInboxEvent {
            let kind: AgentInboxEventKind
            let label: String
            switch record.state {
            case "blocked": kind = .attention; label = "Waiting"
            case "error": kind = .failure; label = "Failed"
            default: kind = .completion; label = "Done"
            }
            let display = ["Reported by programs in " + paneName, record.title, record.message]
                .compactMap { $0 }.joined(separator: "\n")
            return AgentInboxEvent(paneID: paneID, host: host, provider: .shell,
                agentID: "program-status:" + (record.id ?? ""), kind: kind,
                title: "Program reported " + label + " · " + paneName, detail: display,
                occurredAt: occurredAt, sourceID: sourceID, isProgramReported: true)
        }
    }

    /// Called only after the snapshot accepts the current transport/revision.
    /// Replay refreshes the caller's comparison baseline, without notifying.
    /// One transition per pane per five seconds; suppressed events are dropped,
    /// never queued for late replay. Progress/message churn creates no events.
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
        guard let record = candidates.first,
              lastEmission.map({ now - $0 >= Self.minimumInterval }) ?? true else { return [] }
        lastEmission = now
        return [Transition(record: record,
            sourceID: "program-status:" + deliveryEpoch.uuidString.lowercased() + ":" +
                String(revision) + ":" + (record.id ?? ""))]
    }
}

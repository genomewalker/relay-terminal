import Foundation

/// A read-only projection of existing evidence. A reported plan, a transport
/// receipt and a completed task are deliberately different claims.
struct RelayTaskTriage: Equatable {
    struct Receipt: Equatable {
        let id: String
        let recipientPaneID: String
        let status: String
        let readAcknowledged: Bool
        var description: String {
            "Reported \(status); read acknowledgement: \(readAcknowledged ? "yes" : "unknown"). Task completion: unknown."
        }
    }

    struct Field: Equatable {
        enum Kind: String { case observed, inferred, unknown }
        let text: String
        let kind: Kind
        let source: String
        let at: Date?
    }

    let paneID: String
    let host: String
    let directory: String?
    let provider: String
    let connection: String
    let phase: String
    let sampledAt: Date
    let plans: [AgentTaskPlan]
    let receipts: [Receipt]
    let healthState: String
    let objective: Field
    let result: Field
    let blocker: Field
    let owner: Field
    let decision: Field
    let freshness: String

    static let staleAfter: TimeInterval = 15 * 60

    static func build(paneID: String, host: String, directory: String?, provider: String,
                      connection: String, phase: String, plans: [AgentTaskPlan],
                      healthState: String, blockers: [String], pendingDecision: String?,
                      receipts: [Receipt], now: Date) -> Self {
        let plans = plans.filter { $0.provider == provider }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
        let plan = plans.first
        let source = plan.map { "Structured plan \($0.id)" } ?? "No structured plan"
        let unknown = Field(text: "Unknown", kind: .unknown, source: "No source supplied", at: nil)
        let connected = connection.lowercased() == "connected"
        let timely = plan.map { $0.updatedAt <= now && now.timeIntervalSince($0.updatedAt) <= staleAfter } ?? false
        let freshness: String
        if !connected { freshness = "Disconnected: current task state unknown" }
        else if let plan, plan.updatedAt > now { freshness = "Unknown: plan timestamp is in the future" }
        else if plan == nil { freshness = "Unknown: no timestamped plan" }
        else if !timely { freshness = "Stale plan: older than 15 minutes; current task state unknown" }
        else { freshness = "Recent plan report; result not independently verified" }

        let active = plan?.steps.filter { $0.status == .in_progress } ?? []
        let objective: Field = active.count == 1
            ? Field(text: active[0].text, kind: .inferred, source: source + " (current step, not an explicit objective)", at: plan?.updatedAt)
            : unknown
        let completed = plan?.steps.filter { $0.status == .completed } ?? []
        let result = completed.last.map {
            Field(text: "Agent reports complete: " + $0.text, kind: .observed,
                  source: source + " (checklist report only; completion time and artifact verification unknown)", at: plan?.updatedAt)
        } ?? unknown

        let blocker: Field
        if !connected {
            blocker = Field(text: connection, kind: .observed, source: "Local connection model; remote liveness not verified", at: now)
        } else if !blockers.isEmpty {
            blocker = Field(text: blockers.joined(separator: "; "), kind: .observed,
                            source: "Cached health / capacity / pending-card reasons; source timestamp unavailable", at: nil)
        } else { blocker = unknown } // No observed blocker is not proof of no blocker.

        let decision: Field
        if let pendingDecision, !pendingDecision.isEmpty {
            decision = Field(text: pendingDecision, kind: .observed, source: "Pending Miko action card", at: nil)
        } else if !connected || !timely {
            decision = Field(text: "Check the source state before deciding what to do next", kind: .inferred,
                             source: "Connection / plan freshness", at: nil)
        } else { decision = unknown }
        return Self(paneID: paneID, host: host, directory: directory, provider: provider,
                    connection: connection, phase: phase, sampledAt: now, plans: plans,
                    receipts: receipts, healthState: healthState, objective: objective, result: result,
                    blocker: blocker, owner: unknown, decision: decision, freshness: freshness)
    }

    /// Only substantive source changes, not elapsed seconds or another UI read.
    var changeKey: String {
        ([connection, freshness, healthState, objective.text, result.text, blocker.text, decision.text]
         + plans.flatMap { [$0.id, String($0.updatedAt.timeIntervalSince1970)] }
         + receipts.flatMap { [$0.id, $0.status, String($0.readAcknowledged)] }).joined(separator: "\u{1f}")
    }

    func handoff(workspaceID: String, workspace: String, tabID: String, tab: String) -> String {
        let date = ISO8601DateFormatter()
        func field(_ label: String, _ value: Field) -> String {
            "\(label) [\(value.kind.rawValue)]: \(value.text)\n  Source: \(value.source); at: \(value.at.map(date.string) ?? "unknown")"
        }
        return """
        Workspace: \(workspace) [\(workspaceID)]
        Tab: \(tab) [\(tabID)]
        Host: \(host)
        Directory: \(directory ?? "unknown")
        Pane: \(paneID); provider: \(provider); provider conversation: unknown
        Local model sampled: \(date.string(from: sampledAt)); connection: \(connection); reported phase: \(phase)
        Evidence freshness: \(freshness)
        \(field("Objective", objective))
        \(field("Latest result report", result))
        \(field("Blocker", blocker))
        \(field("Decision owner", owner))
        \(field("Next decision", decision))
        Jobs: unknown (not inventoried by this view).
        Delivery: \(receipts.isEmpty ? "unknown (no receipt in this snapshot)" : receipts.map { "\($0.id) to \($0.recipientPaneID): \($0.description) Timestamp: unknown." }.joined(separator: "\n"))
        This snapshot neither resumes nor repairs a session. Recheck live bindings before acting.
        """
    }
}

/// Visible-session change notices; no notifications from unselected workspaces.
struct RelayTaskTriageChanges {
    private var previous: [String: String] = [:]
    mutating func observe(_ readings: [String: RelayTaskTriage]) -> [String] {
        let changed = readings.keys.sorted().filter { key in
            guard let old = previous[key], let reading = readings[key] else { return false }
            return old != reading.changeKey
        }
        previous = readings.mapValues(\.changeKey)
        return changed
    }
}

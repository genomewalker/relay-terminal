import Foundation

struct AgentTaskPlan: Codable, Equatable, Identifiable, Sendable {
    struct Step: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable { case pending, in_progress, completed }
        let text: String
        let status: Status
        var taskID: String? = nil
    }
    let id: String
    let provider: String
    let updatedAt: Date
    let steps: [Step]
    var completedCount: Int { steps.filter { $0.status == .completed }.count }

    static func applyingTask(event: [String: Any], provider: String, plans: [Self], now: Date) -> Self? {
        guard provider == "claude", event["hook_event_name"] as? String == "TaskChanged",
              let taskID = event["task_id"] as? String, !taskID.isEmpty, taskID.utf8.count <= 256 else { return nil }
        let owner = event["agent_id"] as? String ?? event["thread_id"] as? String ?? "root"
        guard !owner.isEmpty, owner.utf8.count <= 256 else { return nil }
        let id = provider + ":" + owner
        let old = plans.first { $0.id == id }
        guard old.map({ $0.updatedAt <= now }) ?? true else { return nil }
        var steps = old?.steps ?? []
        let index = steps.firstIndex { $0.taskID == taskID }
        let raw = event["task_status"] as? String ?? ""
        if raw == "deleted" {
            guard let index else { return nil }
            steps.remove(at: index)
        } else {
            let subject = event["task_subject"] as? String ?? ""
            let text = subject.isEmpty ? index.map { steps[$0].text } ?? "" : subject
            let status = raw.isEmpty ? index.map { steps[$0].status } : Step.Status(rawValue: raw)
            guard let status, !text.isEmpty, text.utf8.count <= 2048 else { return nil }
            let step = Step(text: text, status: status, taskID: taskID)
            if let index { steps[index] = step }
            else { guard steps.count < 100 else { return nil }; steps.append(step) }
        }
        return Self(id: id, provider: provider, updatedAt: now, steps: steps)
    }

    static func bounded(_ plans: [Self]) -> [Self] {
        var bytes = 0
        var kept: [Self] = []
        for plan in plans.suffix(100).reversed() {
            let cost = plan.steps.reduce(1024) { $0 + $1.text.utf8.count + 128 }
            guard bytes + cost <= 256 * 1024 else { continue }
            kept.append(plan)
            bytes += cost
        }
        return kept.reversed()
    }

    /// Only structured events, never prose/terminal matching. A successful
    /// TodoWrite hook is an observed checklist, not execution authorization.
    static func decode(event: [String: Any], provider: String, now: Date) -> Self? {
        let name = event["hook_event_name"] as? String ?? event["type"] as? String
        let rows: [[String: Any]]
        if name == "PlanUpdated" {
            guard let plan = event["plan"] as? [[String: Any]] else { return nil }
            rows = plan
        } else if name == "PostToolUse", event["tool_name"] as? String == "TodoWrite" {
            guard let input = event["tool_input"] as? [String: Any],
                  let todos = input["todos"] as? [[String: Any]] else { return nil }
            rows = todos
        } else { return nil }
        guard rows.count <= 100 else { return nil }
        var steps: [Step] = []
        for row in rows {
            guard let text = row["step"] as? String ?? row["content"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 2048,
                  let raw = row["status"] as? String, let status = Step.Status(rawValue: raw) else { return nil }
            steps.append(Step(text: text, status: status))
        }
        let owner = event["agent_id"] as? String ?? event["thread_id"] as? String ?? "root"
        guard !owner.isEmpty, owner.utf8.count <= 256 else { return nil }
        return Self(id: provider + ":" + owner, provider: provider, updatedAt: now, steps: steps)
    }
}

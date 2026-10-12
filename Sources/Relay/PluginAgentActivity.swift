import SwiftUI

struct PluginAgentSnapshot: Sendable {
    let capturedAt: Date
    let agents: [SubagentActivity]
    let total: Int
    let events: [AgentActivityItem]
    var plans: [AgentTaskPlan] = []

    init(agents: [SubagentActivity], events: [AgentActivityItem], plans: [AgentTaskPlan] = [], now: Date = Date()) {
        self.plans = Array(plans.suffix(100))
        capturedAt = now
        total = agents.count
        // Needs-input first; then recently changed agents. Do not reorder live while reading.
        self.agents = Array(agents.sorted {
            if ($0.phase == .needsInput) != ($1.phase == .needsInput) { return $0.phase == .needsInput }
            let left = $0.updates.last?.occurredAt ?? $0.startedAt
            let right = $1.updates.last?.occurredAt ?? $1.startedAt
            return left == right ? $0.id < $1.id : left > right
        }.prefix(100))
        self.events = Array(events.suffix(30))
    }

    func matching(_ query: String) -> [SubagentActivity] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return agents.filter { q.isEmpty || [$0.id, $0.label, $0.threadID ?? "", $0.phase.label].contains { $0.localizedCaseInsensitiveContains(q) } }
    }
}

struct PluginAgentActivityView: View {
    let snapshot: PluginAgentSnapshot
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
            HStack(spacing: RelayTheme.spacing(16)) {
                Text("\(snapshot.total) agents").fontWeight(.medium)
                Text("\(snapshot.agents.filter { $0.phase == .needsInput }.count) need attention")
                Spacer()
                Text(snapshot.capturedAt.formatted(date: .omitted, time: .standard))
            }.font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
            TextField("Find agent by name, identity or state", text: $query)
            if snapshot.total > snapshot.agents.count {
                Text("Showing 100 agents: needs-input first, then latest activity.").font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
                    ForEach(snapshot.plans) { plan in
                        DisclosureGroup("\(plan.id) · \(plan.completedCount)/\(plan.steps.count) completed") {
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                                Label(step.text, systemImage: step.status == .completed ? "checkmark.circle" : step.status == .in_progress ? "circle.lefthalf.filled" : "circle")
                                    .textSelection(.enabled)
                                    .accessibilityLabel("\(step.status.rawValue): \(step.text)")
                            }
                        }
                    }
                    ForEach(snapshot.matching(query)) { agent in
                        DisclosureGroup {
                            Text("ID: \(agent.id)\nThread: \(agent.threadID ?? "not reported")")
                                .font(.caption.monospaced()).textSelection(.enabled)
                            ForEach(agent.updates.suffix(20)) { update in
                                Text("\(update.occurredAt.formatted(date: .omitted, time: .standard)) · \(String(update.message.prefix(2000)))")
                                    .textSelection(.enabled)
                            }
                        } label: {
                            RelaySurfaceView(content: .init(kind: .status,
                                title: String(agent.label.prefix(200)), status: agent.phase.label))
                        }
                    }
                    if snapshot.matching(query).isEmpty { Text("No matching agents in this snapshot.").foregroundStyle(.secondary) }
                    DisclosureGroup("Recent pane activity (\(snapshot.events.count))") {
                        ForEach(snapshot.events) { event in
                            Text("\(event.occurredAt.formatted(date: .omitted, time: .standard)) · \(String(event.label.prefix(2000)))").textSelection(.enabled)
                        }
                    }
                }
            }
            Text("Captured pane activity · approvals remain in the agent terminal.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

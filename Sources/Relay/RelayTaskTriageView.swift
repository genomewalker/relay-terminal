import AppKit
import SwiftUI

/// Opt-in, local-window pilot. It does not query screens, send messages or
/// execute recovery. Evidence expands inline without navigating to a pane.
struct RelayTaskTriageView: View {
    let state: RelayControlCenterState
    @State private var selected: Set<String> = []
    @State private var expanded = false
    @State private var tracker = RelayTaskTriageChanges()
    @State private var notices: [String] = []
    @State private var showSources: Set<String> = []

    init(state: RelayControlCenterState, initiallyExpanded: Bool = false,
         initiallySelected: Set<String> = []) {
        self.state = state
        _expanded = State(initialValue: initiallyExpanded)
        _selected = State(initialValue: initiallySelected)
    }

    private var readings: [String: RelayTaskTriage] {
        var result: [String: RelayTaskTriage] = [:]
        for workspace in state.workspaces where selected.contains(workspace.id) {
            for tab in workspace.tabs {
                for pane in tab.panes {
                    if let triage = pane.triage { result[pane.id] = triage }
                }
            }
        }
        return result
    }

    var body: some View {
        DisclosureGroup("Tasks and decisions", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose workspaces for this window. This view reads cached evidence only; it does not change sessions or drafts.")
                    .foregroundStyle(RelayTheme.textMuted)
                ForEach(state.workspaces, id: \.id) { workspace in
                    Toggle(workspace.name, isOn: Binding(
                        get: { selected.contains(workspace.id) },
                        set: { if $0 { selected.insert(workspace.id) } else { selected.remove(workspace.id) } }
                    ))
                    if selected.contains(workspace.id) {
                        if workspace.otherWindowTabs > 0 {
                            Text("\(workspace.otherWindowTabs) owned tabs are outside this window: task state unknown.")
                                .foregroundStyle(RelayTheme.coral)
                        }
                        ForEach(workspace.tabs, id: \.id) { tab in
                            ForEach(tab.panes, id: \.id) { pane in
                                if let triage = pane.triage {
                                    task(triage, name: pane.name, workspace: workspace, tab: tab)
                                }
                            }
                        }
                    }
                }
                if selected.isEmpty { Text("No workspaces selected.").foregroundStyle(RelayTheme.textMuted) }
                if !state.unowned.isEmpty {
                    Text("Unowned tabs are excluded; workspace assignment is unknown.").foregroundStyle(RelayTheme.textMuted)
                }
                if !notices.isEmpty {
                    HStack {
                        Text("Evidence changed").fontWeight(.semibold)
                        Spacer()
                        Button("Dismiss notices") { notices = [] }
                    }
                    ForEach(notices, id: \.self) { Text($0).foregroundStyle(RelayTheme.coral) }
                }
            }.padding(.vertical, 6)
        }
        .accessibilityIdentifier("relay.monitoring.task-triage")
        .onChange(of: readings) { _, values in
            let changed = tracker.observe(values)
            for id in changed {
                let text = "Pane \(id): evidence changed; review its decision and sources."
                notices.removeAll { $0 == text }
                notices.insert(text, at: 0)
            }
            notices = Array(notices.prefix(8))
        }
    }

    private func task(_ value: RelayTaskTriage, name: String,
                      workspace: RelayControlCenterState.Workspace,
                      tab: RelayControlCenterState.Tab) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(tab.name) / \(name) · \(value.host)").fontWeight(.semibold)
            Text(value.freshness).foregroundStyle(RelayTheme.textMuted)
            field("Objective", value.objective)
            field("Latest result report", value.result)
            field("Blocker", value.blocker)
            field("Decision owner", value.owner)
            field("Next decision", value.decision)
            HStack {
                Button(showSources.contains(value.paneID) ? "Hide evidence" : "Show evidence") {
                    if showSources.contains(value.paneID) { showSources.remove(value.paneID) }
                    else { showSources.insert(value.paneID) }
                }
                Button("Copy handoff") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value.handoff(workspaceID: workspace.id, workspace: workspace.name,
                        tabID: tab.id, tab: tab.name), forType: .string)
                }
            }
            if showSources.contains(value.paneID) { evidence(value) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayTheme.textMuted.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func field(_ title: String, _ value: RelayTaskTriage.Field) -> some View {
        Text("\(title) [\(value.kind.rawValue)]: \(value.text)")
            .fixedSize(horizontal: false, vertical: true)
    }

    private func evidence(_ value: RelayTaskTriage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Host: \(value.host) · Pane: \(value.paneID) · Provider: \(value.provider)")
            Text("Directory: \(value.directory ?? "unknown") · Provider conversation: unknown")
            Text("Local model sampled: \(value.sampledAt.formatted(date: .abbreviated, time: .standard)); connection: \(value.connection); reported phase: \(value.phase)")
            Text("Health observation: \(value.healthState). Jobs and task-owner identity: unknown.")
            ForEach(value.plans, id: \.id) { plan in
                Text("Source plan \(plan.id) · \(plan.updatedAt.formatted(date: .abbreviated, time: .standard))")
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                    Text("  [\(step.status.rawValue)] \(step.text)")
                }
            }
            Text("Plan reports are not artifact verification. Receipt stages are separate: submitted, admitted, processed, read; none proves task completion.")
            if value.receipts.isEmpty { Text("Delivery receipt: unknown (none in this snapshot).") }
            ForEach(Array(value.receipts.enumerated()), id: \.offset) { _, receipt in
                Text("Message \(receipt.id) → \(receipt.recipientPaneID): \(receipt.description) Source: Miko message receipt cache; timestamp unknown.")
            }
        }
        .foregroundStyle(RelayTheme.textMuted)
        .textSelection(.enabled)
    }
}

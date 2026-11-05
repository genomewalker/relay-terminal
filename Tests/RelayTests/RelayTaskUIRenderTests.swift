import AppKit
import SwiftUI
import Testing
@testable import Relay

@MainActor private final class RenderModel: RelayAssistantModel {
    func step(_ request: RelayAssistantModelRequest) async throws -> RelayAssistantModelStep {
        let text = "The focused continuation checks are complete. The next step is to review the rendered panel and prepare the combined candidate. Account migration is waiting for your decision."
        return .init(stopReason: "end_turn", content: [.object(["type": .string("text"), "text": .string(text)])], toolCalls: [], chargedMicrousd: 1)
    }
}

@Suite("Opt-in native UI rendering", .serialized)
@MainActor struct RelayTaskUIRenderTests {
    @Test func renderPanels() async throws {
        guard let output = ProcessInfo.processInfo.environment["RELAY_UI_RENDER_DIR"] else { return }
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let model = RenderModel()
        let journal = try RelayMikoTaskJournal.temporary()
        let harness = RelayAssistantHarness(policy: { .init() }, budget: RelayMikoActionBudget(),
            workspace: workspace, model: { _ in (model, "render-fixture") }, taskJournal: journal)
        _ = await harness.run("Finish the Miko continuation checks and show me what still needs a decision.", origin: .user)
        try render(RelayAssistantHaikuPanel(workspace: workspace, harness: harness),
                   size: NSSize(width: 560, height: 680), path: output + "/miko-panel.png")

        let now = Date()
        let plan = AgentTaskPlan(id: "claude:fixture", provider: "claude", updatedAt: now,
            steps: [.init(text: "Validate the manuscript figure against the source data", status: .in_progress)])
        let triage = RelayTaskTriage.build(paneID: "fixture-pane", host: "dandy-07",
            directory: "/maps/projects/research", provider: "claude", connection: "Connected",
            phase: "quiet", plans: [plan], healthState: "unknown", blockers: [],
            pendingDecision: nil, receipts: [], now: now)
        let pane = RelayControlCenterState.Pane(id: "fixture-pane", name: "Figure review",
            hostKey: "dandy-07", host: "dandy-07", agent: "claude", phase: "quiet",
            connection: "Connected", account: "Team", summary: "",
            context: .init(state: "unverified", reason: "Fixture"),
            supervision: .init(enabled: "false", enrollment: "none", refreshCapability: "unknown",
                lifecycle: "unknown", promptEmpty: "unknown", blocked: [], usage: [], management: "unavailable"),
            miko: [], shepherd: [], failover: .init(), triage: triage)
        var state = RelayControlCenterState()
        state.workspaces = [.init(id: "research", name: "Research", isInbox: false,
            tabs: [.init(id: "figures", name: "Manuscript", panes: [pane])], otherWindowTabs: 1)]
        try render(ScrollView { RelayTaskTriageView(state: state, initiallyExpanded: true,
            initiallySelected: ["research"]).padding(20) }
            .font(RelayTheme.font(size: 12)).foregroundStyle(RelayTheme.text)
            .background(RelayTheme.surface),
            size: NSSize(width: 880, height: 800), path: output + "/task-triage.png")
    }

    private func render<V: View>(_ content: V, size: NSSize, path: String) throws {
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
        window.orderOut(nil)
    }
}

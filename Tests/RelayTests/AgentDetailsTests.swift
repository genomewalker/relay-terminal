import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// "Agent details…" in a pane's menus and the clickable activity text in its
/// header open the floating inspector on the pane's main agent.
@MainActor @Suite(.serialized) struct AgentDetailsTests {
    private static func agentPane() throws -> (WorkspaceModel, PaneModel) {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.relayIsFrontmost = { true }
        workspace.newTab(profile: .sshConfigHost("agent-details.invalid"))
        let pane = try #require(workspace.activePane)
        pane.connectionState = .connected
        func send(_ json: String) { pane.receivedAgentEvent(Data(json.utf8)) }
        send(#"{"agent":"claude","event":{"hook_event_name":"SessionStart","event_id":"details-start"}}"#)
        send(#"{"agent":"claude","event":{"hook_event_name":"PreToolUse","tool_name":"Read","event_id":"details-read"}}"#)
        send(#"{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"explore-1","agent_type":"Explore"}}"#)
        send(#"{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"review-1","agent_type":"Reviewer"}}"#)
        send(#"{"agent":"claude","event":{"hook_event_name":"PreToolUse","tool_name":"Bash","event_id":"details-bash"}}"#)
        return (workspace, pane)
    }

    @Test func detailsOpenTheMainAgentAndListItsSubagents() throws {
        let (workspace, pane) = try Self.agentPane()
        defer { AgentIntelligenceStore.shared.markPaneRead(pane.id); workspace.shutdown() }
        #expect(pane.headerActivityDetail == "Using Bash")

        workspace.inspectAgent(paneID: pane.id)
        #expect(workspace.agentInspector == AgentInspectorSelection(paneID: pane.id, subagentID: nil))

        let snapshot = AgentInspectorPanel.capture(pane: pane, subagentID: nil)
        let agent = try #require(snapshot.agent)
        #expect(agent.updates.map(\.message).contains("Using Bash"))
        #expect(agent.updates.first?.message == "Using Bash")
        #expect(snapshot.subagents.map(\.id) == ["explore-1", "review-1"])
        #expect(snapshot.statusText == pane.headerStatus?.text)

        // A sub-agent row narrows the same inspector to that thread.
        workspace.inspectAgent(paneID: pane.id, subagentID: "review-1")
        let thread = AgentInspectorPanel.capture(pane: pane, subagentID: "review-1")
        #expect(thread.agent?.label == "Reviewer" && thread.subagents.isEmpty)
    }

    @Test func rendersMainAgentDetailsInBothAppearances() throws {
        let (workspace, pane) = try Self.agentPane()
        defer { AgentIntelligenceStore.shared.markPaneRead(pane.id); workspace.shutdown() }
        var rendered = 0
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            let panel = AgentInspectorPanel(pane: pane, subagentID: nil, showTerminal: {}, close: {})
                .environment(\.colorScheme, scheme)
            let shot = try RelaySnapshot.render(panel, name: "agent-details", width: 500, appearance: appearance)
            #expect(shot.size.height > 200)
            rendered += 1
        }
        #expect(rendered == 2)
    }
}

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

/// Agent details steps open View CLI conversation at their tool call.
@MainActor @Suite(.serialized) struct AgentDetailsConversationTests {
    private static func tool(_ id: String, _ name: String) -> RelayAgentConversationItem {
        RelayAgentConversationItem(id: id, turnID: nil, role: .tool,
                                   blocks: [.tool(name: name, status: "completed", summary: id)],
                                   revision: 1, complete: true)
    }

    @Test func stepsMapToTheirToolCallsCountingBackFromTheNewest() {
        let items = [Self.tool("bash-1", "Bash"), Self.tool("read-1", "Read"), Self.tool("bash-2", "Bash"),
                     RelayAgentConversationItem(id: "text", turnID: nil, role: .assistant,
                                                blocks: [.markdown("done")], revision: 1, complete: true),
                     Self.tool("bash-3", "Bash")]
        // Newest-first steps, as Agent details lists them.
        let now = Date()
        let steps = ["Using Bash", "Finished Bash", "Using Bash", "Using Read", "Started", "Using Bash"].map {
            SubagentUpdate(id: UUID(), message: $0, occurredAt: now)
        }
        let targets = steps.indices.map { AgentInspectorPanel.focus(forStepAt: $0, in: steps)?.target(in: items) }
        #expect(targets == ["bash-3", nil, "bash-2", "read-1", nil, "bash-1"])
        // Older than the loaded page: no target, so the view stays at the end.
        let missing = RelayConversationFocus(toolName: "Bash", ordinalFromEnd: 3)
        #expect(missing.target(in: items) == nil)
        #expect(RelayConversationFocus.toolName(of: "Using tool") == nil)
        #expect(RelayConversationFocus(toolName: "bash", ordinalFromEnd: 0).target(in: items) == "bash-3")
    }

    @Test func openingAStepShowsTheConversationWithItsFocus() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.newTab(profile: .sshConfigHost("agent-conversation.invalid"))
        let pane = try #require(workspace.activePane)
        let focus = RelayConversationFocus(toolName: "Bash", ordinalFromEnd: 1)
        AgentInspectorPanel.openConversation(pane: pane, focus: focus)
        #expect(pane.nativeConversationVisible)
        #expect(pane.conversationFocus == focus)
        pane.nativeConversationVisible = false
        AgentInspectorPanel.openConversation(pane: pane, focus: nil)
        #expect(pane.nativeConversationVisible && pane.conversationFocus == nil)
    }

    /// The conversation opened from a step outlines that step's call.
    @Test func rendersTheFocusedCallInBothAppearances() throws {
        _ = NSApplication.shared
        var rendered = 0
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            let pane = RelayNativeChatFixture.pane(active: true)
            let conversation = RelayNativeChatFixture.timelineConversation(pane: pane)
            let focus = RelayConversationFocus(toolName: "Edit", ordinalFromEnd: 0)
            #expect(focus.target(in: conversation.items) != nil)
            pane.conversationFocus = focus
            let store = RelayAgentTimelineStore(pane: pane, presenting: conversation)
            let view = RelayAgentTimelineView(pane: pane, store: store).frame(height: 900)
                .environment(\.colorScheme, scheme)
            let shot = try RelaySnapshot.render(view, name: "agent-step-conversation", width: 760, appearance: appearance)
            #expect(shot.size.height >= 899)
            // Resolved on appear and cleared, so a later open starts fresh.
            #expect(pane.conversationFocus == nil)
            rendered += 1
        }
        #expect(rendered == 2)
    }
}

/// A sub-agent whose event carries an empty type still gets a readable name.
@MainActor @Suite(.serialized) struct AgentDetailsSubagentLabelTests {
    @Test func emptyAgentTypeFallsBackToSubagent() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.newTab(profile: .sshConfigHost("agent-label.invalid"))
        let pane = try #require(workspace.activePane)
        pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"blank-1","agent_type":""}}"#.utf8))
        pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"named-1","agent_type":"Explore"}}"#.utf8))
        #expect(pane.subagents.map(\.label) == ["Subagent", "Explore"])
        AgentIntelligenceStore.shared.markPaneRead(pane.id)
    }
}

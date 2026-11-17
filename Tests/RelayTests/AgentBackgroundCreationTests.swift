import Foundation
import Testing
@testable import Relay

/// Panes and tabs that agents create (relay_new_local_tab, relay_new_stacked_pane,
/// relay_launch_agent, workspace newTab) are made in the background: the
/// user's selected tab, active pane and shown workspace do not change, and
/// the new terminal is started without being shown. A human's new tab still
/// selects and focuses it.
@MainActor @Suite("Agent-created panes and tabs stay in the background")
struct AgentBackgroundCreationTests {
    typealias F = MCPTabMoveTests

    struct Selection: Equatable {
        let tab: UUID?, pane: UUID?, workspace: UUID?
        @MainActor init(_ workspace: WorkspaceModel) {
            (tab, pane, self.workspace) = (workspace.selectedTabID, workspace.activePaneID, workspace.selectedWorkspaceID)
        }
    }

    /// Records background starts instead of opening a transport.
    static func recordStarts(_ workspace: WorkspaceModel) -> () -> [(UUID, RelayViewport)] {
        final class Box { var starts: [(UUID, RelayViewport)] = [] }
        let box = Box()
        workspace.createdPaneBackgroundStart = { pane, viewport in box.starts.append((pane.id, viewport)) }
        return { box.starts }
    }

    @Test(arguments: [false, true])
    func anchoredLocalTabInAHiddenWorkspaceLeavesSelectionAlone(byTab: Bool) throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let starts = Self.recordStarts(f.workspace)
        f.workspace.selectTab(f.a1.id) // W1 shown; the anchor is in W2
        let before = Selection(f.workspace)
        #expect(before.tab == f.a1.id && before.pane != nil && before.workspace == f.w1)
        let handler = MCPDirectTabRequests(), instance = UUID()
        let anchorPane = try #require(f.b1.allPaneIDs.first)
        let response = handler.newLocalTab(byTab ? F.newTab(instance, UUID(), tab: f.b1.id)
                                                 : F.newTab(instance, UUID(), pane: anchorPane),
                                           instance: instance, permits: F.all, workspace: f.workspace)
        #expect(response.status == 200)
        let result = F.json(response)
        let created = try #require(result["tabID"].flatMap(UUID.init(uuidString:)))
        let paneID = try #require(result["paneID"].flatMap(UUID.init(uuidString:)))
        #expect(Selection(f.workspace) == before)
        #expect(f.workspace.tabs.first { $0.id == created }?.allPaneIDs == [paneID])
        #expect(f.workspace.ownership.tabIDs(in: f.w2) == [f.b1.id, created, f.b2.id])
        // Its terminal is started although its tab was never shown.
        #expect(starts().map(\.0) == [paneID])
    }

    @Test func unanchoredLocalTabLeavesSelectionAlone() throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let starts = Self.recordStarts(f.workspace)
        f.workspace.selectTab(f.b2.id)
        let before = Selection(f.workspace)
        let handler = MCPDirectTabRequests(), instance = UUID()
        let response = handler.newLocalTab(F.newTab(instance, UUID()), instance: instance,
                                           permits: F.all, workspace: f.workspace)
        #expect(response.status == 200)
        let created = try #require(F.json(response)["tabID"].flatMap(UUID.init(uuidString:)))
        let paneID = try #require(F.json(response)["paneID"].flatMap(UUID.init(uuidString:)))
        #expect(created != before.tab && f.workspace.tabID(containingPane: paneID) == created)
        #expect(Selection(f.workspace) == before)
        #expect(starts().map(\.0) == [paneID])
    }

    /// The new pane joins the stack hidden; the shown member stays shown,
    /// in the selected tab and in a hidden one.
    @Test(arguments: [false, true])
    func newStackedPaneJoinsHiddenAndLeavesSelectionAlone(targetTabSelected: Bool) throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let starts = Self.recordStarts(f.workspace)
        f.workspace.selectTab(targetTabSelected ? f.b1.id : f.a1.id)
        let before = Selection(f.workspace)
        let y = try #require(f.b1.allPaneIDs.first)
        let layout = f.b1.layout
        let handler = MCPDirectTabRequests(), instance = UUID()
        let response = handler.newStackedPane(MCPStackPaneTests.newStacked(instance, UUID(), onto: y, host: "This Mac"),
                                              instance: instance, permits: F.all, workspace: f.workspace,
                                              resolve: MCPStackPaneTests.resolve)
        #expect(response.status == 200)
        let result = try #require(MCPStackPaneTests.result(response))
        let created = try #require(UUID(uuidString: result.paneID))
        #expect(Selection(f.workspace) == before)
        #expect(f.b1.layout == layout && f.b1.layout.paneIDs == [y])
        #expect(f.b1.stack(containing: y)?.members == [y, created] && f.b1.stack(containing: y)?.selected == y)
        #expect(result.selectedPaneID == y.uuidString.lowercased())
        #expect(starts().map(\.0) == [created])
        // A second agent pane joins the same stack, still hidden.
        let second = try f.workspace.newStackedPane(onto: y, profile: .local)
        #expect(f.b1.stack(containing: y)?.members == [y, created, second.paneID])
        #expect(f.b1.stack(containing: y)?.selected == y && f.b1.layout.paneIDs == [y])
        #expect(Selection(f.workspace) == before)
    }

    @Test func workspaceActionNewTabDoesNotRevealOrSelect() throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let starts = Self.recordStarts(f.workspace)
        f.workspace.selectTab(f.a1.id)
        let before = Selection(f.workspace)
        let sourceID = try #require(f.b1.allPaneIDs.first)
        let source = try #require(f.workspace.panes[sourceID])
        let made = try #require(f.workspace.applyWorkspaceAction(WorkspaceProposal(instance: UUID(), requestID: UUID(),
            paneID: source.id, action: .newTab), expected: source))
        #expect(Selection(f.workspace) == before)
        #expect(f.workspace.tabs.first { $0.id == made.0 }?.sessionID == f.b1.sessionID)
        #expect(f.workspace.tabID(containingPane: made.1) == made.0)
        #expect(starts().map(\.0) == [made.1])
    }

    @Test func humanNewTabStillSelectsAndIsStartedByItsView() throws {
        let f = try F.fixture()
        defer { f.workspace.shutdown() }
        let starts = Self.recordStarts(f.workspace)
        f.workspace.selectTab(f.a1.id)
        let made = try #require(f.workspace.newTabInActiveSession(profile: .local))
        #expect(f.workspace.selectedTabID == made.tabID && f.workspace.activePaneID == made.paneID)
        let other = f.workspace.newTab(profile: .local)
        #expect(f.workspace.selectedTabID == other.tabID && f.workspace.activePaneID == other.paneID)
        #expect(starts().isEmpty)
    }
}

import Combine
import Foundation
import Testing
@testable import Relay

/// Sidebar rows must not move under the pointer, and a drop the list accepts
/// must show. These use only API older than the fixes, so they also run
/// against the unfixed source.
@MainActor @Suite("Navigator rows stay put and drops show")
struct WorkspaceNavigatorGlitchTests {
    private func event(_ pane: UUID, _ title: String) -> AgentInboxEvent {
        AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .codex, kind: .failure, title: title,
                        occurredAt: Date(), sourceID: UUID().uuidString, alert: .error)
    }

    private func newPane(_ workspace: WorkspaceModel) throws -> (tab: TabModel, pane: PaneModel) {
        workspace.newTab(profile: .sshConfigHost("navigator-glitch.invalid"))
        return (try #require(workspace.selectedTab), try #require(workspace.activePane))
    }

    @Test func aWorkspaceDropKeepsTheInboxHeldUntilThePointerLeaves() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.shutdown() }
        let previous = workspace.navigatorSort
        defer { workspace.setNavigatorSortMode(previous) }
        workspace.setNavigatorSortMode(.attention)
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let alpha = workspace.createWorkspace(named: "Alpha"), beta = workspace.createWorkspace(named: "Beta")
        let late = try newPane(workspace)
        workspace.holdNavigatorOrder(inbox: store)
        store.record(event(late.pane.id, "late"))
        try workspace.performDrop(.workspaceBefore(workspaceID: beta, targetID: alpha))
        #expect(workspace.navigatorSort == .manual)
        // The pointer is still on the list: the inbox above it stays as shown.
        #expect(workspace.shownAttentionInbox(inbox: store).isEmpty)
        workspace.releaseNavigatorOrder()
        #expect(workspace.shownAttentionInbox(inbox: store).map(\.paneID) == [late.pane.id])
    }

    @Test func aTabDragWithinItsWorkspaceIsRefusedInAttentionOrder() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let previous = workspace.navigatorSort
        defer { workspace.setNavigatorSortMode(previous) }
        let home = workspace.createWorkspace(named: "Home"), other = workspace.createWorkspace(named: "Other")
        let t1 = try newPane(workspace).tab, t2 = try newPane(workspace).tab
        try workspace.moveTab(t1.id, toWorkspace: home)
        try workspace.moveTab(t2.id, toWorkspace: home)
        workspace.setNavigatorSortMode(.attention)
        // Accepted, this would move nothing shown: the sort decides the place.
        #expect(workspace.canDrop(.tabBeforeTab(tabID: t2.id, targetTabID: t1.id)) != nil)
        #expect(workspace.canDrop(.tabOnWorkspace(tabID: t2.id, workspaceID: home, index: nil)) != nil)
        // Another workspace, the tab rail's indexed drop, and Manual order still move it.
        #expect(workspace.canDrop(.tabOnWorkspace(tabID: t2.id, workspaceID: other, index: nil)) == nil)
        #expect(workspace.canDrop(.tabOnWorkspace(tabID: t2.id, workspaceID: home, index: 0)) == nil)
        workspace.setNavigatorSortMode(.manual)
        #expect(workspace.canDrop(.tabBeforeTab(tabID: t2.id, targetTabID: t1.id)) == nil)
    }

    @Test func aTabMovedToAnotherWorkspaceWhileHeldGoesLastThere() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let alpha = workspace.createWorkspace(named: "Alpha"), beta = workspace.createWorkspace(named: "Beta")
        let a1 = try newPane(workspace), a2 = try newPane(workspace), b = try newPane(workspace)
        try workspace.moveTab(a1.tab.id, toWorkspace: alpha)
        try workspace.moveTab(a2.tab.id, toWorkspace: alpha)
        try workspace.moveTab(b.tab.id, toWorkspace: beta)
        var navigation = WorkspaceNavigationState()
        let now = Date()
        for (offset, tab) in [a1.tab, a2.tab, b.tab].enumerated() {
            navigation.noteUse(.tab, id: tab.id, now: now.addingTimeInterval(Double(offset)))
        }
        workspace.holdNavigatorOrder(sort: .attention, inbox: store, navigation: navigation)
        try workspace.performDrop(.tabOnWorkspace(tabID: b.tab.id, workspaceID: alpha, index: nil))
        // Its rank was an offset among Beta's tabs; in Alpha it goes last.
        #expect(workspace.railTabs(inWorkspace: alpha, sort: .attention, inbox: store, navigation: navigation).map(\.id)
                == [a2.tab.id, a1.tab.id, b.tab.id])
    }

    @Test func aBriefExitKeepsTheHold() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.shutdown() }
        workspace.holdNavigatorOrder()
        // The pointer has just left (for the search field, or past the edge).
        workspace.settleNavigatorHold(pointerInside: false, dragging: false)
        #expect(workspace.navigatorHold != nil)
    }

    @Test func holdingTheNavigatorDoesNotRedrawTheWholeWindow() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        var changes = 0
        let sink = workspace.objectWillChange.sink { _ in changes += 1 }
        defer { sink.cancel() }
        workspace.holdNavigatorOrder()
        workspace.releaseNavigatorOrder()
        #expect(changes == 0)
    }

    @Test func aPaneClosedWhileHeldKeepsItsInboxRowUntilRelease() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let closed = try newPane(workspace), kept = try newPane(workspace)
        store.record(event(closed.pane.id, "closed"))
        store.record(event(kept.pane.id, "kept"))
        workspace.holdNavigatorOrder(inbox: store)
        let held = workspace.shownAttentionInbox(inbox: store).map(\.paneID)
        workspace.selectTab(closed.tab.id)
        workspace.selectPane(closed.pane.id)
        workspace.closeActivePane()
        #expect(workspace.panes[closed.pane.id] == nil)
        #expect(workspace.shownAttentionInbox(inbox: store).map(\.paneID) == held)
        workspace.releaseNavigatorOrder()
        #expect(workspace.shownAttentionInbox(inbox: store).map(\.paneID) == [kept.pane.id])
    }
}

import Foundation
import Testing
@testable import Relay

/// The navigator holds what it drew, ends a hold only after a real exit,
/// keeps row expansion by ID and counts what arrived while held.
@MainActor @Suite("Navigator hold, expansion and search")
struct WorkspaceNavigatorHoldDrawnTests {
    private func event(_ pane: UUID, _ title: String) -> AgentInboxEvent {
        AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .codex, kind: .failure, title: title,
                        occurredAt: Date(), sourceID: UUID().uuidString, alert: .error)
    }

    private func wait(_ pane: PaneModel) { pane.received("Do you want to proceed? (y/n)\n") }

    private func newPane(_ workspace: WorkspaceModel) throws -> (tab: TabModel, pane: PaneModel) {
        workspace.newTab(profile: .sshConfigHost("navigator-drawn.invalid"))
        return (try #require(workspace.selectedTab), try #require(workspace.activePane))
    }

    @Test func aHoldKeepsTheRowsAsLastDrawn() throws {
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
        func order() -> [UUID] {
            workspace.navigatorWorkspaces(sort: .attention, inbox: store, navigation: navigation).shown.map(\.id)
                .filter { $0 == alpha || $0 == beta }
        }
        func rail() -> [UUID] {
            workspace.railTabs(inWorkspace: alpha, sort: .attention, inbox: store, navigation: navigation).map(\.id)
        }
        let drawn = workspace.navigatorWorkspaces(sort: .attention, inbox: store, navigation: navigation)
        let drawnTabs = Dictionary(uniqueKeysWithValues: (drawn.shown + drawn.hidden).map {
            ($0.id, workspace.railTabs(inWorkspace: $0.id, sort: .attention, inbox: store, navigation: navigation))
        })
        #expect(order() == [beta, alpha])
        #expect(rail() == [a2.tab.id, a1.tab.id])
        // a1 starts waiting after the last redraw; the pointer arrives before the next.
        wait(a1.pane)
        workspace.holdNavigatorOrder(sort: .attention, inbox: store, navigation: navigation,
                                     drawn: drawn.shown + drawn.hidden, drawnTabs: drawnTabs)
        #expect(order() == [beta, alpha])
        #expect(rail() == [a2.tab.id, a1.tab.id])
        workspace.releaseNavigatorOrder()
        #expect(order() == [alpha, beta])
        #expect(rail() == [a1.tab.id, a2.tab.id])
    }

    @Test func reorderingAnUnpinnedTabInAttentionOrderSaysWhy() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let previous = workspace.navigatorSort
        defer { workspace.setNavigatorSortMode(previous) }
        let home = workspace.createWorkspace(named: "Home")
        let t1 = try newPane(workspace).tab, t2 = try newPane(workspace).tab
        try workspace.moveTab(t1.id, toWorkspace: home)
        try workspace.moveTab(t2.id, toWorkspace: home)
        workspace.setNavigatorSortMode(.attention)
        #expect(workspace.canDrop(.tabBeforeTab(tabID: t2.id, targetTabID: t1.id)) == .sortedByAttention)
        #expect(WorkspaceMoveRefusal.sortedByAttention.localizedDescription.contains("Manual"))
        // Pinned tabs keep their arranged order, so they still reorder.
        workspace.toggleTabPin(t1.id)
        workspace.toggleTabPin(t2.id)
        defer { workspace.toggleTabPin(t1.id); workspace.toggleTabPin(t2.id) }
        #expect(workspace.canDrop(.tabBeforeTab(tabID: t2.id, targetTabID: t1.id)) == nil)
    }

    @Test func aBriefExitKeepsTheHoldAndALongerOneEndsIt() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.shutdown() }
        let t0 = Date()
        workspace.holdNavigatorOrder()
        workspace.settleNavigatorHold(pointerInside: false, dragging: false, now: t0)
        #expect(workspace.navigatorHold != nil)
        // Back on the list, then off again: the grace period starts over.
        workspace.settleNavigatorHold(pointerInside: true, dragging: false, now: t0.addingTimeInterval(0.3))
        workspace.settleNavigatorHold(pointerInside: false, dragging: false, now: t0.addingTimeInterval(0.4))
        workspace.settleNavigatorHold(pointerInside: false, dragging: false, now: t0.addingTimeInterval(0.9))
        #expect(workspace.navigatorHold != nil)
        workspace.settleNavigatorHold(pointerInside: false, dragging: false, now: t0.addingTimeInterval(1.1))
        #expect(workspace.navigatorHold == nil)
    }

    @Test func expansionIsKeptByIDAcrossPinAndHide() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let id = workspace.createWorkspace(named: "Beta")
        let tab = try newPane(workspace).tab
        try workspace.moveTab(tab.id, toWorkspace: id)
        #expect(workspace.isNavigatorWorkspaceExpanded(id))
        #expect(!workspace.isNavigatorTabExpanded(tab.id))
        workspace.setNavigatorWorkspaceExpanded(id, false)
        workspace.setNavigatorTabExpanded(tab.id, true)
        workspace.setWorkspaceFavourite(id, true)
        workspace.setWorkspaceHidden(id, true)
        workspace.setWorkspaceHidden(id, false)
        workspace.setWorkspaceFavourite(id, false)
        #expect(!workspace.isNavigatorWorkspaceExpanded(id))
        #expect(workspace.isNavigatorTabExpanded(tab.id))
        workspace.setNavigatorWorkspaceExpanded(id, true)
        #expect(workspace.isNavigatorWorkspaceExpanded(id))
    }

    @Test func aWorkspaceFoundWithAPaddedQueryKeepsItsTabs() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let home = workspace.createWorkspace(named: "Alpha")
        let tab = try newPane(workspace).tab
        try workspace.moveTab(tab.id, toWorkspace: home)
        let record = try #require(workspace.ownership.workspace(home))
        #expect(workspace.navigatorWorkspaces(matching: "alpha ").shown.contains { $0.id == home })
        #expect(workspace.navigatorTabs(workspace.railTabs(inWorkspace: home), of: record, matching: "alpha ").map(\.id) == [tab.id])
        // A query matching only the tab still narrows to it.
        #expect(workspace.navigatorTabs(workspace.railTabs(inWorkspace: home), of: record, matching: "no-such-tab").isEmpty)
    }

    @Test func theHiddenPinIsNamedForAccessibility() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let id = workspace.createWorkspace(named: "Beta")
        #expect(WorkspaceNavigatorPin.accessibilityLabel(try #require(workspace.ownership.workspace(id))) == "Pin Beta")
        workspace.setWorkspaceFavourite(id, true)
        #expect(WorkspaceNavigatorPin.accessibilityLabel(try #require(workspace.ownership.workspace(id))) == "Unpin Beta")
    }

    @Test func attentionArrivingWhileHeldIsCountedNotListed() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let first = try newPane(workspace), second = try newPane(workspace)
        store.record(event(first.pane.id, "first"))
        #expect(workspace.attentionArrivedWhileHeld(inbox: store) == 0)
        workspace.holdNavigatorOrder(inbox: store)
        store.record(event(second.pane.id, "second"))
        store.markPaneRead(first.pane.id)
        #expect(workspace.shownAttentionInbox(inbox: store).map(\.paneID) == [first.pane.id])
        #expect(workspace.attentionArrivedWhileHeld(inbox: store) == 1)
        workspace.releaseNavigatorOrder()
        #expect(workspace.attentionArrivedWhileHeld(inbox: store) == 0)
    }
}

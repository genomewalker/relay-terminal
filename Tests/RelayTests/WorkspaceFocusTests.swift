import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Focus on chosen workspaces")
struct WorkspaceFocusTests {
    private func event(_ pane: UUID, _ alert: RelayAttentionAlert, _ title: String) -> AgentInboxEvent {
        AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .codex, kind: alert == .error ? .failure : .attention,
                        title: title, occurredAt: Date(), sourceID: UUID().uuidString, alert: alert)
    }

    /// A workspace holding one new tab; returns the workspace and its pane.
    private func workspaceWithPane(_ workspace: WorkspaceModel, named name: String) throws -> (id: UUID, pane: UUID) {
        let id = workspace.createWorkspace(named: name)
        workspace.newTab(profile: .sshConfigHost("workspace-focus.invalid"))
        let tab = try #require(workspace.selectedTab)
        try workspace.moveTab(tab.id, toWorkspace: id)
        return (id, try #require(tab.allPaneIDs.first))
    }

    @Test func focusListsOnlyFocusedWorkspacesAndEndingListsAllAgain() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let a = workspace.createWorkspace(named: "Alpha"), b = workspace.createWorkspace(named: "Beta")
        workspace.setWorkspaceHidden(b, true)
        let all = workspace.navigatorWorkspaces()

        workspace.focus(on: a)
        #expect(workspace.isFocusing)
        #expect(workspace.navigatorWorkspaces().shown.map(\.id) == [a])
        #expect(workspace.navigatorWorkspaces().hidden.isEmpty)
        #expect(workspace.navigatorWorkspaces(matching: "Beta").shown.isEmpty)

        workspace.addToFocus(b)
        #expect(workspace.focusedWorkspaceIDs() == [a, b])
        #expect(workspace.navigatorWorkspaces().hidden.map(\.id) == [b])
        workspace.removeFromFocus(a)
        #expect(workspace.focusedWorkspaceIDs() == [b])

        workspace.endFocus()
        #expect(!workspace.isFocusing)
        #expect(workspace.navigatorWorkspaces().shown.map(\.id) == all.shown.map(\.id))
        #expect(workspace.navigatorWorkspaces().hidden.map(\.id) == all.hidden.map(\.id))
    }

    @Test func focusKeepsOnlyExistingWorkspacesOnceAndNoneMeansOff() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let a = workspace.createWorkspace(named: "Alpha")
        workspace.setFocusedWorkspaces([UUID()])
        #expect(!workspace.isFocusing)
        #expect(workspace.focusedWorkspaces.isEmpty)
        workspace.setFocusedWorkspaces([a, a])
        #expect(workspace.focusedWorkspaces == [a])
        workspace.removeFromFocus(a)
        #expect(!workspace.isFocusing)

        // A focused workspace gone in another Relay's change no longer counts.
        #expect(workspace.focusedWorkspaceIDs(from: [a, UUID()]) == [a])
    }

    @Test func enteringFocusShowsAFocusedWorkspace() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let a = workspace.createWorkspace(named: "Alpha"), b = workspace.createWorkspace(named: "Beta")
        workspace.selectWorkspace(b)
        workspace.focus(on: a)
        #expect(workspace.selectedWorkspaceID == a)
        workspace.addToFocus(b)
        #expect(workspace.selectedWorkspaceID == a)
    }

    @Test func cyclingWorkspacesStaysInFocus() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let a = workspace.createWorkspace(named: "Alpha")
        _ = workspace.createWorkspace(named: "Beta")
        let c = workspace.createWorkspace(named: "Gamma")
        workspace.setFocusedWorkspaces([a, c])
        workspace.selectWorkspace(a)
        workspace.selectWorkspace(offset: 1)
        #expect(workspace.selectedWorkspaceID == c)
        workspace.selectWorkspace(offset: 1)
        #expect(workspace.selectedWorkspaceID == a)
    }

    @Test func theInboxListsPanesInFocusAndKeepsTheOthersUnread() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let a = try workspaceWithPane(workspace, named: "Alpha"), b = try workspaceWithPane(workspace, named: "Beta")
        store.record(event(a.pane, .error, "alpha failed"))
        store.record(event(b.pane, .needsInput, "beta asks"))

        workspace.focus(on: a.id)
        // The model's starting tab sits in the default workspace, also outside.
        #expect(workspace.panesInFocus() == [a.pane])
        #expect(workspace.isInFocus(paneID: a.pane))
        #expect(!workspace.isInFocus(paneID: b.pane))
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [a.pane])
        #expect(store.marker(for: b.pane) == .needsInput)
        #expect(store.panesNeedingUser { workspace.isInFocus(paneID: $0) } == 1)
        #expect(workspace.attentionOutsideFocus(inbox: store) == 1)
        #expect(workspace.attentionInbox(inbox: store, outsideFocus: true).count == 2)

        // Finished work outside focus is not counted as waiting.
        let c = try workspaceWithPane(workspace, named: "Gamma")
        store.record(AgentInboxEvent(paneID: c.pane, host: "dandy-07", provider: .codex, kind: .completion, title: "done",
                                     occurredAt: Date(), sourceID: UUID().uuidString, alert: .done))
        #expect(workspace.attentionOutsideFocus(inbox: store) == 1)

        workspace.endFocus()
        #expect(workspace.attentionOutsideFocus(inbox: store) == 0)
        #expect(workspace.panesInFocus() == nil)
        // Finished work (c) stays an unread marker, not an inbox row.
        #expect(Set(workspace.attentionInbox(inbox: store).map(\.paneID)) == [a.pane, b.pane])
        #expect(store.panesNeedingUser { workspace.isInFocus(paneID: $0) } == 2)
    }

    @Test func aPaneInNoFocusedWorkspaceIsMutedUntilFocusEnds() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let a = try workspaceWithPane(workspace, named: "Alpha")
        _ = try workspaceWithPane(workspace, named: "Beta")
        let loose = UUID()
        let notifier = RelayAttentionNotifier(workspace: workspace)
        workspace.focus(on: a.id)
        let placed = try #require(store.item(store.record(event(a.pane, .needsInput, "alpha asks"))))
        let unplaced = try #require(store.item(store.record(event(loose, .error, "loose failed"))))
        #expect(!workspace.isInFocus(paneID: loose))
        #expect(notifier.bannerDecision(placed, appActive: false) == .banner)
        #expect(notifier.bannerDecision(unplaced, appActive: false) == .skip("outside focus"))
        #expect(notifier.badgeCount(inbox: store) == 1)
        workspace.endFocus()
        #expect(workspace.isInFocus(paneID: loose))
        #expect(notifier.badgeCount(inbox: store) == 2)
    }

    @Test func aFloatingRPanelIsInItsTabsFocus() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let alpha = workspace.createWorkspace(named: "Alpha")
        let b = try workspaceWithPane(workspace, named: "Beta")
        workspace.newTab(profile: .sshConfigHost("workspace-focus.invalid"))
        let tab = try #require(workspace.selectedTab), console = try #require(workspace.activePane)
        let panel = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)
        try workspace.moveTab(tab.id, toWorkspace: alpha)
        #expect(!tab.allPaneIDs.contains(panel.id))
        let notifier = RelayAttentionNotifier(workspace: workspace)
        let item = try #require(store.item(store.record(event(panel.id, .error, "editor failed"))))
        workspace.focus(on: alpha)
        #expect(workspace.isInFocus(paneID: panel.id))
        #expect(notifier.bannerDecision(item, appActive: false) == .banner)
        #expect(notifier.badgeCount(inbox: store) == 1)
        workspace.focus(on: b.id)
        #expect(!workspace.isInFocus(paneID: panel.id))
        #expect(notifier.badgeCount(inbox: store) == 0)
    }

    @Test func aHeldInboxFollowsFocusChanges() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.releaseNavigatorOrder(); workspace.endFocus(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let a = try workspaceWithPane(workspace, named: "Alpha"), b = try workspaceWithPane(workspace, named: "Beta")
        store.record(event(a.pane, .error, "alpha failed"))
        store.record(event(b.pane, .error, "beta failed"))
        workspace.holdNavigatorOrder(inbox: store)
        #expect(Set(workspace.shownAttentionInbox(inbox: store).map(\.paneID)) == [a.pane, b.pane])
        workspace.focus(on: a.id)
        #expect(workspace.shownAttentionInbox(inbox: store).map(\.paneID) == [a.pane])
        workspace.endFocus()
        #expect(Set(workspace.shownAttentionInbox(inbox: store).map(\.paneID)) == [a.pane, b.pane])
        // Still held: a new alert waits for the release.
        let c = try workspaceWithPane(workspace, named: "Gamma")
        store.record(event(c.pane, .error, "gamma failed"))
        #expect(!workspace.shownAttentionInbox(inbox: store).map(\.paneID).contains(c.pane))
    }

    @Test func theFocusBarOffersEveryWorkspaceOutsideFocus() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let a = workspace.createWorkspace(named: "Alpha"), b = workspace.createWorkspace(named: "Beta")
        let c = workspace.createWorkspace(named: "Gamma")
        workspace.setWorkspaceHidden(c, true)
        #expect(workspace.workspacesOutsideFocus().isEmpty)
        workspace.focus(on: a)
        let offered = Set(workspace.workspacesOutsideFocus().map(\.id))
        #expect(offered.isSuperset(of: [b, c]))
        #expect(!offered.contains(a))
        // Rows outside focus are not listed, so the bar is the way to add one.
        #expect(!workspace.navigatorWorkspaces().shown.contains { $0.id == b })
        workspace.addToFocus(b)
        #expect(workspace.focusedWorkspaceIDs() == [a, b])
        #expect(!workspace.workspacesOutsideFocus().contains { $0.id == b })
    }

    @Test func bannersSkipPanesOutsideFocusWithoutCountingThem() {
        var policy = RelayAttentionBannerPolicy()
        let now = Date(), quiet = UUID()
        for _ in 0..<RelayAttentionBannerPolicy.burstLimit + 2 {
            #expect(policy.decide(paneID: UUID(), alert: .needsInput, occurredAt: now, now: now, appActive: false, inFocus: false)
                == .skip("outside focus"))
        }
        #expect(policy.decide(paneID: quiet, alert: .done, occurredAt: now, now: now, appActive: false, inFocus: false)
            == .skip("outside focus"))
        // Neither the burst nor this pane's repeat interval was used up.
        #expect(policy.decide(paneID: quiet, alert: .done, occurredAt: now, now: now, appActive: false) == .banner)
        for _ in 1..<RelayAttentionBannerPolicy.burstLimit {
            #expect(policy.decide(paneID: UUID(), alert: .done, occurredAt: now, now: now, appActive: false) == .banner)
        }
        #expect(policy.takeCoalesced() == 0)
    }

    @Test func theNotifierBannersPanesInFocusOnly() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let a = try workspaceWithPane(workspace, named: "Alpha"), b = try workspaceWithPane(workspace, named: "Beta")
        let notifier = RelayAttentionNotifier(workspace: workspace)
        workspace.focus(on: a.id)
        let inside = try #require(store.item(store.record(event(a.pane, .needsInput, "alpha asks"))))
        let outside = try #require(store.item(store.record(event(b.pane, .needsInput, "beta asks"))))
        #expect(notifier.bannerDecision(inside, appActive: false) == .banner)
        #expect(notifier.bannerDecision(outside, appActive: false) == .skip("outside focus"))
    }

    @Test func theBadgeCountsPanesInFocusUntilFocusEnds() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let a = try workspaceWithPane(workspace, named: "Alpha"), b = try workspaceWithPane(workspace, named: "Beta")
        store.record(event(a.pane, .error, "alpha failed"))
        store.record(event(b.pane, .needsInput, "beta asks"))
        let notifier = RelayAttentionNotifier(workspace: workspace)
        #expect(notifier.badgeCount(inbox: store) == 2)
        workspace.focus(on: a.id)
        #expect(notifier.badgeCount(inbox: store) == 1)
        workspace.endFocus()
        #expect(notifier.badgeCount(inbox: store) == 2)
    }

    @Test func enteringChangingAndEndingFocusNotifyTheNotifier() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.endFocus(); workspace.shutdown() }
        let a = workspace.createWorkspace(named: "Alpha"), b = workspace.createWorkspace(named: "Beta")
        let notifier = RelayAttentionNotifier.shared
        var seen = notifier.focusChangeCount
        workspace.focus(on: a)
        #expect(notifier.focusChangeCount > seen)
        seen = notifier.focusChangeCount
        workspace.addToFocus(b)
        #expect(notifier.focusChangeCount > seen)
        seen = notifier.focusChangeCount
        workspace.endFocus()
        #expect(notifier.focusChangeCount > seen)
    }
}

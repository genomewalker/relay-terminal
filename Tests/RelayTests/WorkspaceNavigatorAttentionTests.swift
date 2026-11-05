import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Workspaces navigator inbox and attention order")
struct WorkspaceNavigatorAttentionTests {
    private func event(_ pane: UUID, _ kind: AgentInboxEventKind, _ alert: RelayAttentionAlert, _ title: String,
                       at: Date = Date()) -> AgentInboxEvent {
        AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .codex, kind: kind, title: title,
                        occurredAt: at, sourceID: UUID().uuidString, alert: alert)
    }

    private func wait(_ pane: PaneModel) { pane.received("Do you want to proceed? (y/n)\n") }

    /// The attention signal stays in the scanned tail until enough output follows.
    private func goOn(_ pane: PaneModel) {
        pane.received(String(repeating: "x", count: 600) + "\n")
        pane.received("working\n")
    }

    private func newPane(_ workspace: WorkspaceModel) throws -> (tab: TabModel, pane: PaneModel) {
        workspace.newTab(profile: .sshConfigHost("navigator-attention.invalid"))
        return (try #require(workspace.selectedTab), try #require(workspace.activePane))
    }

    @Test func liveWaitingPaneIsListedFirstAfterItsAlertsAreRead() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let waiting = try newPane(workspace).pane, erred = try newPane(workspace).pane
        store.record(event(waiting.id, .attention, .needsInput, "question"))
        store.markPaneRead(waiting.id)
        store.record(event(erred.id, .failure, .error, "boom"))
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [erred.id])

        wait(waiting)
        let rows = workspace.attentionInbox(inbox: store)
        #expect(rows.map(\.paneID) == [waiting.id, erred.id])
        #expect(rows.first?.alert == .needsInput)

        goOn(waiting)
        #expect(waiting.phase != .needsInput)
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [erred.id])
    }

    @Test func waitingPaneWithAnOlderUnreadErrorCountsAsWaiting() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let pane = try newPane(workspace).pane
        store.record(event(pane.id, .failure, .error, "boom"))
        wait(pane)
        let rows = workspace.attentionInbox(inbox: store)
        #expect(rows.map(\.paneID) == [pane.id])
        #expect(rows.first?.alert == .needsInput)
        goOn(pane)
        #expect(workspace.attentionInbox(inbox: store).first?.alert == .error)
    }

    @Test func unreadAlertsKeepRankThenNewestFirstWithOneRowPerPane() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let base = Date()
        let finished = try newPane(workspace).pane, oldError = try newPane(workspace).pane
        let newError = try newPane(workspace).pane, failed = try newPane(workspace).pane
        store.record(event(finished.id, .completion, .done, "done", at: base.addingTimeInterval(9)))
        store.record(event(oldError.id, .failure, .error, "old", at: base.addingTimeInterval(1)))
        store.record(event(oldError.id, .completion, .done, "later done", at: base.addingTimeInterval(8)))
        store.record(event(newError.id, .failure, .error, "new", at: base.addingTimeInterval(5)))
        store.record(event(failed.id, .failure, .toolFailed, "tool", at: base.addingTimeInterval(7)))
        let gone = UUID()
        store.record(event(gone, .failure, .error, "closed pane", at: base.addingTimeInterval(10)))

        let rows = workspace.attentionInbox(inbox: store)
        #expect(rows.map(\.paneID) == [newError.id, oldError.id, failed.id, finished.id])
        #expect(rows.map(\.alert) == [.error, .error, .toolFailed, .done])
        #expect(Set(rows.map(\.paneID)).count == rows.count)
        store.markPaneRead(newError.id)
        #expect(workspace.attentionInbox(inbox: store).first?.paneID == oldError.id)
    }

    @Test func attentionOrderFloatsWaitingWorkspacesThenRecentUse() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let alpha = workspace.createWorkspace(named: "Alpha"), beta = workspace.createWorkspace(named: "Beta")
        let first = workspace.createWorkspace(named: "Empty one"), second = workspace.createWorkspace(named: "Empty two")
        let favourite = workspace.createWorkspace(named: "Favourite"), hidden = workspace.createWorkspace(named: "Hidden")
        let a1 = try newPane(workspace), a2 = try newPane(workspace), b = try newPane(workspace), h = try newPane(workspace)
        try workspace.moveTab(a1.tab.id, toWorkspace: alpha)
        try workspace.moveTab(a2.tab.id, toWorkspace: alpha)
        try workspace.moveTab(b.tab.id, toWorkspace: beta)
        try workspace.moveTab(h.tab.id, toWorkspace: hidden)
        workspace.setWorkspaceFavourite(favourite, true)
        workspace.setWorkspaceHidden(hidden, true)
        // Selection notes use in the saved state; a local one keeps the test exact.
        var navigation = WorkspaceNavigationState()
        let now = Date()
        for (offset, tab) in [a1.tab, a2.tab, b.tab].enumerated() {
            navigation.noteUse(.tab, id: tab.id, now: now.addingTimeInterval(Double(offset)))
        }
        let mine: Set<UUID> = [alpha, beta, first, second, favourite, hidden]
        func order(_ sort: WorkspaceNavigationState.NavigatorSort = .attention) -> [UUID] {
            workspace.navigatorWorkspaces(sort: sort, inbox: store, navigation: navigation).shown.map(\.id).filter(mine.contains)
        }

        // Most recent use first; unused ones keep their arrangement.
        #expect(order() == [favourite, beta, alpha, first, second])
        #expect(workspace.railTabs(inWorkspace: alpha, sort: .attention, inbox: store, navigation: navigation).map(\.id) == [a2.tab.id, a1.tab.id])

        // A waiting pane lifts its workspace above a more recent one, and its tab.
        wait(a1.pane)
        #expect(order() == [favourite, alpha, beta, first, second])
        #expect(workspace.railTabs(inWorkspace: alpha, sort: .attention, inbox: store, navigation: navigation).map(\.id) == [a1.tab.id, a2.tab.id])
        goOn(a1.pane)
        #expect(order() == [favourite, beta, alpha, first, second])

        // An unread alert counts too; hidden ones stay apart and the Inbox last.
        store.record(event(h.pane.id, .failure, .error, "hidden boom"))
        let lists = workspace.navigatorWorkspaces(sort: .attention, inbox: store, navigation: navigation)
        #expect(lists.hidden.map(\.id) == [hidden])
        #expect(!lists.shown.contains { $0.id == hidden })
        #expect(lists.shown.last?.id == WorkspaceOwnershipSnapshot.inboxID)
        store.record(event(a2.pane.id, .failure, .error, "boom"))
        #expect(order() == [favourite, alpha, beta, first, second])
        store.markPaneRead(a2.pane.id)
        #expect(order() == [favourite, beta, alpha, first, second])
    }

    @Test func manualOrderIsTheArrangedOrder() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let alpha = workspace.createWorkspace(named: "Alpha"), beta = workspace.createWorkspace(named: "Beta")
        let favourite = workspace.createWorkspace(named: "Favourite")
        let b = try newPane(workspace)
        try workspace.moveTab(b.tab.id, toWorkspace: beta)
        workspace.setWorkspaceFavourite(favourite, true)
        workspace.selectTab(b.tab.id)
        wait(b.pane)

        let shown = workspace.ownership.orderedWorkspaces.filter { $0.hidden != true }
        let arranged = shown.filter { $0.favourite && !$0.isInbox } + shown.filter { !$0.favourite && !$0.isInbox } + shown.filter(\.isInbox)
        #expect(workspace.navigatorWorkspaces(sort: .manual, inbox: store).shown.map(\.id) == arranged.map(\.id))
        #expect(workspace.navigatorWorkspaces().shown.map(\.id) == arranged.map(\.id))
        let ids = workspace.navigatorWorkspaces(sort: .manual, inbox: store).shown.map(\.id)
        #expect(ids.firstIndex(of: alpha)! < ids.firstIndex(of: beta)!)
        #expect(workspace.railTabs(inWorkspace: beta, sort: .manual).map(\.id) == workspace.railTabs(inWorkspace: beta).map(\.id))
    }

    @Test func navigatorDefaultsToAttentionOrderAndKeepsTheChoice() throws {
        #expect(WorkspaceNavigationState().navigatorSortMode == .attention)
        let legacy = #"{"expandedGroups":{},"lastSelectedTabs":{},"sort":"mostUsed"}"#
        var state = try JSONDecoder().decode(WorkspaceNavigationState.self, from: Data(legacy.utf8))
        #expect(state.navigatorSortMode == .attention)
        #expect(state.sortMode == .mostUsed)
        let chosen = #"{"expandedGroups":{},"lastSelectedTabs":{},"navigatorSort":"manual"}"#
        #expect(try JSONDecoder().decode(WorkspaceNavigationState.self, from: Data(chosen.utf8)).navigatorSortMode == .manual)
        state.navigatorSortMode = .manual
        let decoded = try JSONDecoder().decode(WorkspaceNavigationState.self, from: JSONEncoder().encode(state))
        #expect(decoded.navigatorSortMode == .manual)
        #expect(decoded.sortMode == .mostUsed)

        let tab = UUID(), now = Date()
        #expect(state.lastUse(.tab, id: tab) == nil)
        state.noteUse(.tab, id: tab, now: now)
        #expect(state.lastUse(.tab, id: tab) == now)
    }

    @Test func aFloatingRPanelNeedingAttentionLiftsItsWorkspaceAndTab() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let alpha = workspace.createWorkspace(named: "Alpha"), beta = workspace.createWorkspace(named: "Beta")
        let owner = try newPane(workspace)
        let editor = try workspace.addFloatingRPanel(consoleID: owner.pane.id, contentKind: .editor)
        let other = try newPane(workspace), b = try newPane(workspace)
        try workspace.moveTab(owner.tab.id, toWorkspace: alpha)
        try workspace.moveTab(other.tab.id, toWorkspace: alpha)
        try workspace.moveTab(b.tab.id, toWorkspace: beta)
        var navigation = WorkspaceNavigationState()
        let now = Date()
        for (offset, tab) in [owner.tab, other.tab, b.tab].enumerated() {
            navigation.noteUse(.tab, id: tab.id, now: now.addingTimeInterval(Double(offset)))
        }
        func order() -> [UUID] {
            workspace.navigatorWorkspaces(sort: .attention, inbox: store, navigation: navigation).shown.map(\.id)
                .filter { $0 == alpha || $0 == beta }
        }
        func rail() -> [UUID] {
            workspace.railTabs(inWorkspace: alpha, sort: .attention, inbox: store, navigation: navigation).map(\.id)
        }
        #expect(order() == [beta, alpha])
        #expect(rail() == [other.tab.id, owner.tab.id])

        store.record(event(editor.id, .failure, .error, "editor boom"))
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [editor.id])
        #expect(order() == [alpha, beta])
        #expect(rail() == [owner.tab.id, other.tab.id])
    }

    @Test func heldNavigatorOrderStaysUntilReleased() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
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
        #expect(order() == [beta, alpha])
        #expect(rail() == [a2.tab.id, a1.tab.id])

        workspace.holdNavigatorOrder(sort: .attention, inbox: store, navigation: navigation)
        wait(a1.pane)
        #expect(order() == [beta, alpha])
        #expect(rail() == [a2.tab.id, a1.tab.id])
        // The inbox is not held: the waiting pane is listed at once.
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [a1.pane.id])

        workspace.releaseNavigatorOrder()
        #expect(order() == [alpha, beta])
        #expect(rail() == [a1.tab.id, a2.tab.id])
    }

    @Test func aHoldEndsOnceThePointerIsOffAndNoDragRuns() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.holdNavigatorOrder()
        workspace.settleNavigatorHold(pointerInside: true, dragging: false)
        #expect(workspace.navigatorHold != nil)
        // A drag that left the list keeps it held.
        workspace.settleNavigatorHold(pointerInside: false, dragging: true)
        #expect(workspace.navigatorHold != nil)
        // Cancelled outside the list: the button is up, so it ends once the
        // pointer has stayed away for the grace period.
        let left = Date()
        workspace.settleNavigatorHold(pointerInside: false, dragging: false, now: left)
        #expect(workspace.navigatorHold != nil)
        workspace.settleNavigatorHold(pointerInside: false, dragging: false,
                                      now: left.addingTimeInterval(WorkspaceModel.navigatorHoldGrace))
        #expect(workspace.navigatorHold == nil)
    }

    @Test func selectingATabKeepsItsUseAfterItsSessionUnderAFullUsageList() throws {
        _ = WorkspaceNavigationState.updating { state in
            let now = Date()
            for _ in 0..<WorkspaceNavigationState.usageLimit {
                let busy = UUID()
                for _ in 0..<3 { state.noteUse(.tab, id: busy, now: now) }
            }
        }
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let tab = try newPane(workspace).tab
        #expect(workspace.navigationState.lastUse(.tab, id: tab.id) != nil)
        #expect(workspace.navigationState.lastUse(.session, id: tab.sessionID) != nil)
    }

    @Test func aTabUsedJustNowSurvivesAFullUsageList() {
        var state = WorkspaceNavigationState()
        let now = Date()
        for _ in 0..<WorkspaceNavigationState.usageLimit {
            let busy = UUID()
            for _ in 0..<3 { state.noteUse(.tab, id: busy, now: now) }
        }
        let fresh = UUID()
        state.noteUse(.tab, id: fresh, now: now)
        #expect(state.lastUse(.tab, id: fresh) == now)
    }

    @Test func draggingAWorkspaceInAttentionOrderSwitchesToManualAndKeepsTheArrangedOrder() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let previous = workspace.navigatorSort
        defer { workspace.setNavigatorSortMode(previous) }
        workspace.setNavigatorSortMode(.attention)
        let alpha = workspace.createWorkspace(named: "Alpha"), beta = workspace.createWorkspace(named: "Beta")
        let gamma = workspace.createWorkspace(named: "Gamma")
        let g = try newPane(workspace)
        try workspace.moveTab(g.tab.id, toWorkspace: gamma)
        wait(g.pane)
        let shown = workspace.navigatorWorkspaces(sort: .attention).shown.map(\.id)
        try #require(shown.firstIndex(of: gamma)! < shown.firstIndex(of: alpha)!)

        let arranged = workspace.navigatorWorkspaces(sort: .manual).shown.map(\.id)
        try #require(arranged != shown)

        workspace.holdNavigatorOrder()
        try workspace.performDrop(.workspaceBefore(workspaceID: beta, targetID: alpha))
        // The arranged order is kept, not the one shown; only Beta moved in it.
        var expected = arranged.filter { $0 != beta }
        expected.insert(beta, at: expected.firstIndex(of: alpha)!)
        #expect(workspace.navigatorSort == .manual)
        // Held until the pointer leaves; Manual order ignores the ranks.
        #expect(workspace.navigatorHold != nil)
        #expect(workspace.navigatorWorkspaces(sort: .manual).shown.map(\.id) == expected)
        workspace.releaseNavigatorOrder()
    }

    @Test func pinnedWorkspacesKeepManualOrderInAttentionSort() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let p1 = workspace.createWorkspace(named: "Pinned one"), p2 = workspace.createWorkspace(named: "Pinned two")
        let u1 = workspace.createWorkspace(named: "Loose one"), u2 = workspace.createWorkspace(named: "Loose two")
        workspace.setWorkspaceFavourite(p1, true)
        workspace.setWorkspaceFavourite(p2, true)
        defer {
            workspace.setWorkspaceFavourite(p1, false)
            workspace.setWorkspaceFavourite(p2, false)
        }
        let inPinned = try newPane(workspace), inLoose = try newPane(workspace)
        try workspace.moveTab(inPinned.tab.id, toWorkspace: p2)
        try workspace.moveTab(inLoose.tab.id, toWorkspace: u2)
        let navigation = WorkspaceNavigationState()
        let mine: Set<UUID> = [p1, p2, u1, u2]
        func order(_ sort: WorkspaceNavigationState.NavigatorSort) -> [UUID] {
            workspace.navigatorWorkspaces(sort: sort, inbox: store, navigation: navigation).shown.map(\.id).filter(mine.contains)
        }
        #expect(order(.attention) == [p1, p2, u1, u2])

        // A waiting pane re-sorts the unpinned rows only.
        wait(inPinned.pane)
        wait(inLoose.pane)
        #expect(order(.attention) == [p1, p2, u2, u1])
        #expect(order(.manual) == [p1, p2, u1, u2])
    }

    @Test func pinnedTabsKeepArrangedOrderAboveSortedTabs() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let home = workspace.createWorkspace(named: "Tabs")
        let t1 = try newPane(workspace), t2 = try newPane(workspace), t3 = try newPane(workspace)
        for tab in [t1.tab, t2.tab, t3.tab] { try workspace.moveTab(tab.id, toWorkspace: home) }
        workspace.toggleTabPin(t1.tab.id)
        workspace.toggleTabPin(t2.tab.id)
        defer {
            for tab in [t1.tab, t2.tab] where workspace.isTabPinned(tab.id) { workspace.toggleTabPin(tab.id) }
        }
        var navigation = WorkspaceNavigationState()
        navigation.noteUse(.tab, id: t3.tab.id, now: Date())
        wait(t2.pane)
        let expected = [t1.tab.id, t2.tab.id, t3.tab.id]
        for sort in WorkspaceNavigationState.NavigatorSort.allCases {
            #expect(workspace.railTabs(inWorkspace: home, sort: sort, inbox: store, navigation: navigation).map(\.id) == expected)
        }
    }

    @Test func attentionInboxCollapseIsSavedAndOlderStateIsExpanded() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let previous = workspace.navigationState.isAttentionInboxCollapsed
        defer { workspace.setAttentionInboxCollapsed(previous) }
        #expect(!WorkspaceNavigationState().isAttentionInboxCollapsed)
        let legacy = #"{"expandedGroups":{},"lastSelectedTabs":{},"navigatorSort":"attention"}"#
        #expect(try !JSONDecoder().decode(WorkspaceNavigationState.self, from: Data(legacy.utf8)).isAttentionInboxCollapsed)

        workspace.setAttentionInboxCollapsed(true)
        #expect(workspace.navigationState.isAttentionInboxCollapsed)
        #expect(WorkspaceNavigationState.load().isAttentionInboxCollapsed)
        workspace.setAttentionInboxCollapsed(false)
        #expect(!WorkspaceNavigationState.load().isAttentionInboxCollapsed)
    }

    @Test func attentionInboxShowsFiveThenCountsTheRest() {
        let entries = (0..<7).map { _ in AttentionInboxEntry(paneID: UUID(), alert: .error, title: "boom", occurredAt: nil) }
        let page = AttentionInboxPage.visible(entries, showingAll: false)
        #expect(page.rows == Array(entries.prefix(5)))
        #expect(page.hiddenCount == 2)
        let all = AttentionInboxPage.visible(entries, showingAll: true)
        #expect(all.rows == entries)
        #expect(all.hiddenCount == 0)
        #expect(AttentionInboxPage.visible(Array(entries.prefix(5)), showingAll: false).hiddenCount == 0)
    }

    @Test func dismissingAWaitingPaneHidesItUntilItsStateChanges() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let pane = try newPane(workspace).pane
        wait(pane)
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [pane.id])

        workspace.dismissAttention(pane.id, inbox: store)
        #expect(workspace.attentionInbox(inbox: store).isEmpty)
        // Still the same wait: it stays dismissed.
        wait(pane)
        #expect(pane.phase == .needsInput)
        #expect(workspace.attentionInbox(inbox: store).isEmpty)
        // Sorting still counts it.
        #expect(workspace.paneNeedsAttention(pane.id, inbox: store))

        goOn(pane)
        wait(pane)
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [pane.id])
    }

    @Test func aDismissedWaitStaysDismissedWhenASnapshotReplaysIt() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let pane = try newPane(workspace).pane
        func failure(_ id: String) -> String {
            #"{"agent":"claude","event":{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","event_id":"\#(id)"}}"#
        }
        func snapshot(_ seq: Int, _ events: [String]) -> Data {
            Data(#"{"agent":"relay","relay_event_seq":\#(seq),"event":{"type":"RelayStateSnapshot","events":[\#(events.joined(separator: ","))]}}"#.utf8)
        }
        pane.receivedAgentEvent(Data(failure("f-1").utf8))
        #expect(pane.phase == .needsInput)
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [pane.id])
        workspace.dismissAttention(pane.id, inbox: store)
        #expect(workspace.attentionInbox(inbox: store).isEmpty)

        // A reconnect replays the same event: the same wait, still dismissed.
        pane.receivedAgentEvent(snapshot(7, [failure("f-1")]))
        #expect(pane.phase == .needsInput)
        #expect(workspace.attentionInbox(inbox: store).isEmpty)

        // A later failure while still waiting is a new wait, live or replayed.
        pane.receivedAgentEvent(snapshot(8, [failure("f-1"), failure("f-2")]))
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [pane.id])
        workspace.dismissAttention(pane.id, inbox: store)
        pane.receivedAgentEvent(Data(failure("f-3").utf8))
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [pane.id])
    }

    /// A pane restored while waiting, from saved state with and without its
    /// wait's identity (older builds saved none), through the real decoder,
    /// constructor, inbox and Dismiss.
    @Test(arguments: [true, false])
    func aPaneRestoredWaitingListsAndCanBeDismissed(savedIdentity: Bool) throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let profile = ConnectionProfile.sshConfigHost("navigator-attention.invalid")
        let failure = #"{"agent":"claude","event":{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","event_id":"r-1"}}"#
        let live = PaneModel(profile: profile)
        live.receivedAgentEvent(Data(failure.utf8))
        let wait = try #require(live.waitIdentity)
        let state = PersistedAgentPaneState(waitIdentity: savedIdentity ? wait : nil, cursor: 4, kind: .claude,
            phase: .needsInput, summary: "Failed Bash", subagents: [], activities: [], resourceUsage: nil,
            progressPercent: nil, pendingApprovals: 0)
        let saved = try JSONDecoder().decode(PersistedAgentPaneState.self, from: JSONEncoder().encode(state.boundedForStorage()))
        let pane = PaneModel(profile: profile, savedAgentState: saved)
        workspace.storePane(pane)
        #expect(pane.phase == .needsInput)
        #expect(pane.waitIdentity == (savedIdentity ? wait : "restored"))
        // Never dismissed: listed.
        #expect(workspace.dismissedAttention.isEmpty)
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [pane.id])
        // Dismiss records the restored wait and hides it.
        workspace.dismissAttention(pane.id, inbox: store)
        #expect(workspace.dismissedAttention[pane.id] == pane.waitIdentity)
        #expect(workspace.attentionInbox(inbox: store).isEmpty)
        // A reconnect replays the event: with its saved identity it is the same wait.
        pane.receivedAgentEvent(Data(#"{"agent":"relay","relay_event_seq":9,"event":{"type":"RelayStateSnapshot","events":[\#(failure)]}}"#.utf8))
        #expect(pane.phase == .needsInput)
        #expect(workspace.attentionInbox(inbox: store).isEmpty == savedIdentity)
        // A missing dismissal never hides a row.
        #expect(!WorkspaceModel.isDismissedWait(nil, current: nil))
        #expect(WorkspaceModel.isDismissedWait("w", current: "w") && !WorkspaceModel.isDismissedWait("w", current: "v"))
        withExtendedLifetime(live) {}
    }

    @Test func aDropOntoTheSelectedRowStillShows() {
        let selected = NavigatorRowFill(selected: true, targeted: false, refused: false)
        let drop = NavigatorRowFill(selected: true, targeted: true, refused: false)
        #expect(selected == .selected && drop == .dropTarget)
        #expect(drop.color != selected.color)
        #expect(drop.outlined && !selected.outlined)
        #expect(NavigatorRowFill(selected: true, targeted: true, refused: true) == .refused)
        #expect(NavigatorRowFill(selected: false, targeted: false, refused: false).color == .clear)
    }

    @Test func dismissingAnUnreadAlertMarksItRead() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let pane = try newPane(workspace).pane
        store.record(event(pane.id, .failure, .error, "boom"))
        #expect(workspace.attentionInbox(inbox: store).map(\.paneID) == [pane.id])

        workspace.dismissAttention(pane.id, inbox: store)
        #expect(store.marker(for: pane.id) == nil)
        #expect(workspace.attentionInbox(inbox: store).isEmpty)
        #expect(workspace.dismissedAttention[pane.id] == nil)
    }
}

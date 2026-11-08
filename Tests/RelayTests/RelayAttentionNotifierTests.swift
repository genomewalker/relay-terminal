import AppKit
import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Pane attention alerts, markers and banners")
struct RelayAttentionNotifierTests {
    private func event(_ pane: UUID, _ kind: AgentInboxEventKind, _ alert: RelayAttentionAlert?, source: String) -> AgentInboxEvent {
        AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .codex, kind: kind, title: source,
                        occurredAt: Date(), sourceID: source, alert: alert)
    }

    @Test func markersShowEachPanesMostUrgentUnreadAlert() {
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let first = UUID(), second = UUID(), quiet = UUID()
        store.record(event(first, .completion, .done, source: "1"))
        #expect(store.marker(for: first) == .done && store.panesNeedingUser == 0)
        store.record(event(first, .attention, .needsInput, source: "2"))
        store.record(event(first, .completion, .done, source: "3"))
        #expect(store.marker(for: first) == .needsInput)
        store.record(event(first, .failure, .error, source: "4"))
        #expect(store.marker(for: first) == .error)
        store.record(event(second, .attention, .needsInput, source: "5"))
        // Inbox rows without an alert (peers, subagents) mark nothing.
        store.record(event(quiet, .failure, nil, source: "6"))
        store.record(event(quiet, .peer, nil, source: "7"))
        #expect(store.marker(for: quiet) == nil)
        #expect(store.panesNeedingUser == 2)

        store.markPaneRead(first)
        #expect(store.marker(for: first) == nil && store.marker(for: second) == .needsInput)
        #expect(store.panesNeedingUser == 1)
        let unread = store.items.filter { $0.paneID == first && !$0.isRead }
        #expect(unread.isEmpty)
    }

    @Test func attentionInboxListsPanesWaitingOnTheUserFirst() {
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let finished = UUID(), failed = UUID(), waiting = UUID(), erred = UUID(), quiet = UUID()
        let start = Date()
        func record(_ pane: UUID, _ kind: AgentInboxEventKind, _ alert: RelayAttentionAlert?,
                    _ source: String, after seconds: TimeInterval) {
            store.record(AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .codex, kind: kind,
                                         title: source, occurredAt: start.addingTimeInterval(seconds),
                                         sourceID: source, alert: alert))
        }
        record(finished, .completion, .done, "finished", after: 5)
        record(failed, .failure, .toolFailed, "tool", after: 4)
        record(erred, .failure, .error, "error", after: 3)
        record(waiting, .attention, .needsInput, "older input", after: 1)
        record(waiting, .completion, .done, "done later", after: 6)
        record(waiting, .attention, .needsInput, "newer input", after: 2)
        record(quiet, .peer, nil, "peer", after: 7)
        #expect(store.attentionPanes.map(\.paneID) == [waiting, erred, failed, finished])
        // A row shows the pane's newest item of its most urgent inbox alert.
        #expect(store.attentionPanes.first?.title == "newer input")

        // Within an alert, the newest comes first.
        let second = UUID()
        record(second, .attention, .needsInput, "second", after: 8)
        #expect(store.attentionPanes.prefix(2).map(\.paneID) == [second, waiting])

        store.markPaneRead(waiting)
        #expect(!store.attentionPanes.contains { $0.paneID == waiting })
        store.markAllRead()
        #expect(store.attentionPanes.isEmpty)
    }

    @Test func attentionInboxListsAWaitingPaneAsWaitingWhateverItsMarker() {
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let mixed = UUID(), erred = UUID()
        let start = Date()
        func record(_ pane: UUID, _ kind: AgentInboxEventKind, _ alert: RelayAttentionAlert,
                    _ source: String, after seconds: TimeInterval) {
            store.record(AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .codex, kind: kind,
                                         title: source, occurredAt: start.addingTimeInterval(seconds),
                                         sourceID: source, alert: alert))
        }
        record(mixed, .failure, .error, "old error", after: 1)
        record(erred, .failure, .error, "newer error", after: 2)
        record(mixed, .attention, .needsInput, "question", after: 3)
        // The marker still shows the error; the inbox lists the question first.
        #expect(store.marker(for: mixed) == .error)
        #expect(store.attentionPanes.map(\.paneID) == [mixed, erred])
        #expect(store.attentionPanes.first?.title == "question")
        #expect(store.attentionPanes.first?.alert == .needsInput)
    }

    @Test func openingAFloatingRPanelFromTheInboxShowsAndReadsIt() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.relayIsFrontmost = { true }
        workspace.newTab(profile: .sshConfigHost("inbox-r-test.invalid"))
        let console = workspace.activePane!
        let owner = workspace.selectedTabID
        let panel = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .terminal)
        workspace.newTab(profile: .sshConfigHost("inbox-r-test.invalid"))
        #expect(workspace.selectedTabID != owner)
        let store = AgentIntelligenceStore.shared
        store.record(event(panel.id, .attention, .needsInput, source: "floating-\(panel.id)"))
        #expect(store.attentionPanes.contains { $0.paneID == panel.id })

        workspace.revealPane(panel.id)
        #expect(workspace.selectedTabID == owner)
        #expect(workspace.activePaneID == panel.id)
        #expect(store.marker(for: panel.id) == nil)
        #expect(!store.attentionPanes.contains { $0.paneID == panel.id })
    }

    @Test func revealingAPaneInAnotherTabReadsOnlyThatPane() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.relayIsFrontmost = { true }
        workspace.newTab(profile: .sshConfigHost("inbox-reveal-test.invalid"))
        let target = workspace.activePane!
        workspace.splitActive(axis: .horizontal)
        // The tab remembers the sibling, the pane in front when it was left.
        let remembered = workspace.activePane!
        #expect(remembered.id != target.id)
        workspace.newTab(profile: .sshConfigHost("inbox-reveal-test.invalid"))
        let store = AgentIntelligenceStore.shared
        store.record(event(target.id, .attention, .needsInput, source: "target-\(target.id)"))
        store.record(event(remembered.id, .attention, .needsInput, source: "sibling-\(remembered.id)"))

        workspace.revealPane(target.id)
        #expect(workspace.activePaneID == target.id)
        #expect(store.marker(for: target.id) == nil)
        // Passing through the remembered sibling does not show it.
        #expect(store.marker(for: remembered.id) == .needsInput)
        store.markPaneRead(remembered.id)
    }

    @Test func attentionInboxOrdersByEventTimeNotDelivery() {
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let late = UUID(), other = UUID()
        let start = Date()
        func record(_ pane: UUID, _ source: String, after seconds: TimeInterval) {
            store.record(AgentInboxEvent(paneID: pane, host: "dandy-07", provider: .codex, kind: .attention,
                                         title: source, occurredAt: start.addingTimeInterval(seconds),
                                         sourceID: source, alert: .needsInput))
        }
        record(late, "newest question", after: 5)
        record(other, "middle question", after: 3)
        // A reconnect delivers an older event of the same pane last.
        record(late, "replayed old question", after: 1)
        #expect(store.attentionPanes.map(\.paneID) == [late, other])
        #expect(store.attentionPanes.first?.title == "newest question")
    }

    @Test func itemsForAPaneTheUserIsWatchingArriveRead() {
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let watched = UUID(), other = UUID()
        var seen: [String] = []
        store.onRecord = { item in
            seen.append(item.title)
            return item.paneID == watched
        }
        store.record(event(watched, .completion, .done, source: "a"))
        store.record(event(other, .completion, .done, source: "b"))
        // A replayed event is not new: no second call.
        store.record(event(other, .completion, .done, source: "b"))
        #expect(seen == ["a", "b"])
        #expect(store.marker(for: watched) == nil && store.marker(for: other) == .done)
    }

    @Test func hookEventsCarryTheirAlerts() {
        _ = NSApplication.shared // Urgent hook events announce to the main window.
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        func send(_ json: String) { pane.receivedAgentEvent(Data(json.utf8)) }
        send(#"{"agent":"claude","event":{"hook_event_name":"PermissionRequest","tool_name":"Bash","event_id":"n-1"}}"#)
        send(#"{"agent":"claude","event":{"hook_event_name":"Notification","notification_type":"idle_prompt","event_id":"n-2"}}"#)
        send(#"{"agent":"claude","event":{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","event_id":"n-3"}}"#)
        send(#"{"agent":"claude","event":{"hook_event_name":"SubagentStop","agent_id":"sub","event_id":"n-4"}}"#)
        send(#"{"agent":"claude","event":{"hook_event_name":"Stop","event_id":"n-5"}}"#)
        let items = AgentIntelligenceStore.shared.items.filter { $0.paneID == pane.id }
        func alert(_ kind: AgentInboxEventKind, _ title: String) -> RelayAttentionAlert?? {
            items.first { $0.kind == kind && $0.title.contains(title) }.map(\.alert)
        }
        #expect(alert(.attention, "Approval needed") == .some(.needsInput))
        #expect(alert(.attention, "needs your input") == .some(nil))
        #expect(alert(.failure, "failed") == .some(.toolFailed))
        #expect(alert(.completion, "finished") == .some(nil))
        #expect(alert(.completion, "completed a turn") == .some(.done))
        AgentIntelligenceStore.shared.markPaneRead(pane.id)
    }

    @Test func programStatusStatesMapToAlerts() {
        var policy = RelayProgramStatusAttention()
        for (index, (state, alert)) in [("blocked", RelayAttentionAlert.needsInput), ("error", .error), ("done", .done)].enumerated() {
            let record = RelayProgramStatusRecord(id: state, state: state, kind: nil, app: "fixture",
                                                  title: "Fixture", message: nil, progress: nil, revision: nil)
            let transition = policy.consume(previous: [], current: [record], revision: 1, deliveryEpoch: UUID(),
                                            replay: false, now: Double(index) * 100)
            #expect(transition.first?.inboxEvent(paneID: UUID(), host: "h", paneName: "p", occurredAt: Date()).alert == alert)
        }
    }

    // A burst from many panes is limited in banners, never in the record:
    // every pane is still listed as needing attention.
    @Test func aBurstBannersWithinTheLimitButEveryPaneNeedsAttention() {
        let notifier = RelayAttentionNotifier()
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        var decisions: [RelayAttentionBannerPolicy.Decision] = []
        store.onRecord = { item in
            if let decision = notifier.bannerDecision(item, appActive: false) { decisions.append(decision) }
            return false
        }
        let panes = (0..<9).map { _ in UUID() }
        for pane in panes {
            var policy = RelayProgramStatusAttention()
            let record = RelayProgramStatusRecord(id: "job", state: "blocked", kind: nil, app: "fixture",
                                                  title: "Fixture", message: nil, progress: nil, revision: nil)
            for transition in policy.consume(previous: [], current: [record], revision: 1, deliveryEpoch: UUID(),
                                             replay: false, now: 0) {
                store.record(transition.inboxEvent(paneID: pane, host: "h", paneName: "p", occurredAt: Date()))
            }
        }
        #expect(decisions.count == panes.count)
        #expect(decisions.filter { $0 == .banner }.count <= RelayAttentionBannerPolicy.burstLimit)
        #expect(decisions.filter { $0 == .coalesce }.count == panes.count - RelayAttentionBannerPolicy.burstLimit)
        #expect(Set(store.attentionPanes.map(\.paneID)) == Set(panes))
        #expect(store.panesNeedingUser == panes.count)
        #expect(panes.allSatisfy { store.marker(for: $0) == .needsInput })
    }

    @Test func bannersOnlyInTheBackgroundFreshAndRateLimited() {
        var policy = RelayAttentionBannerPolicy()
        let pane = UUID(), now = Date()
        #expect(policy.decide(paneID: pane, alert: .done, occurredAt: now, now: now, appActive: true) == .skip("Relay is frontmost"))
        #expect(policy.decide(paneID: pane, alert: .done, occurredAt: now.addingTimeInterval(-601), now: now,
                              appActive: false) == .skip("stale"))
        #expect(policy.decide(paneID: pane, alert: .done, occurredAt: now, now: now, appActive: false) == .banner)
        // Same pane and alert within a minute: once. Another alert still shows.
        #expect(policy.decide(paneID: pane, alert: .done, occurredAt: now, now: now.addingTimeInterval(30),
                              appActive: false) == .skip("repeat"))
        #expect(policy.decide(paneID: pane, alert: .needsInput, occurredAt: now, now: now.addingTimeInterval(1),
                              appActive: false) == .banner)
        // At most four banners per 30 s; the rest become one summary.
        #expect(policy.decide(paneID: UUID(), alert: .done, occurredAt: now, now: now.addingTimeInterval(2), appActive: false) == .banner)
        #expect(policy.decide(paneID: UUID(), alert: .done, occurredAt: now, now: now.addingTimeInterval(3), appActive: false) == .banner)
        #expect(policy.decide(paneID: UUID(), alert: .error, occurredAt: now, now: now.addingTimeInterval(4), appActive: false) == .coalesce)
        #expect(policy.decide(paneID: UUID(), alert: .done, occurredAt: now, now: now.addingTimeInterval(5), appActive: false) == .coalesce)
        #expect(policy.takeCoalesced() == 2 && policy.takeCoalesced() == 0)
        #expect(policy.decide(paneID: UUID(), alert: .done, occurredAt: now, now: now.addingTimeInterval(40), appActive: false) == .banner)
        // Later than a minute, the same pane and alert banners again.
        #expect(policy.decide(paneID: pane, alert: .done, occurredAt: now.addingTimeInterval(61), now: now.addingTimeInterval(61),
                              appActive: false) == .banner)
    }

    @Test func failedToolsBannerOncePerPaneEveryTenMinutes() {
        var policy = RelayAttentionBannerPolicy()
        let pane = UUID(), other = UUID(), now = Date()
        func tool(_ id: UUID, at seconds: TimeInterval) -> RelayAttentionBannerPolicy.Decision {
            let time = now.addingTimeInterval(seconds)
            return policy.decide(paneID: id, alert: .toolFailed, occurredAt: time, now: time, appActive: false)
        }
        #expect(tool(pane, at: 0) == .banner)
        #expect(tool(pane, at: 90) == .skip("repeat"))
        #expect(tool(pane, at: 599) == .skip("repeat"))
        // Another pane has its own allowance.
        #expect(tool(other, at: 100) == .banner)
        // A program-reported error on the same pane is not held back by tool failures.
        #expect(policy.decide(paneID: pane, alert: .error, occurredAt: now.addingTimeInterval(120),
                              now: now.addingTimeInterval(120), appActive: false) == .banner)
        #expect(tool(pane, at: 600) == .banner)
    }

    @Test func panesShownByAnyNavigationAreReadButTemporarySelectionsAreNot() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        var frontmost = true
        workspace.relayIsFrontmost = { frontmost }
        let store = AgentIntelligenceStore.shared
        workspace.newTab(profile: .sshConfigHost("attention-read.invalid"))
        let first = workspace.selectedTab!.id
        workspace.newTab(profile: .sshConfigHost("attention-read.invalid"))
        workspace.splitActive(axis: .horizontal)
        let second = workspace.selectedTab!
        let (left, right) = (second.allPaneIDs[0], second.allPaneIDs[1])
        let firstPane = workspace.paneIDs(inTab: first)[0]
        func alert(_ pane: UUID) {
            store.record(event(pane, .attention, .needsInput, source: UUID().uuidString))
        }
        defer { for pane in [left, right, firstPane] { store.markPaneRead(pane) } }

        // A temporary selection restores the original pane and reads nothing,
        // whether it selects a hidden pane or a hidden tab.
        let shownBefore = workspace.activePaneID!
        let hidden = shownBefore == left ? right : left
        alert(hidden)
        alert(firstPane)
        workspace.withoutNavigationEffects { workspace.selectPane(hidden) }
        workspace.withoutNavigationEffects { workspace.selectTab(first) }
        #expect(workspace.activePaneID == shownBefore)
        #expect(store.marker(for: hidden) == .needsInput)
        #expect(store.marker(for: firstPane) == .needsInput)

        // Switching tabs shows that tab's pane.
        workspace.selectTab(first)
        #expect(workspace.activePaneID == firstPane)
        #expect(store.marker(for: firstPane) == nil)

        // Keyboard navigation between panes.
        workspace.selectTab(second.id)
        let current = workspace.activePaneID!
        let other = current == left ? right : left
        alert(other)
        workspace.selectAdjacentPane(offset: 1)
        #expect(workspace.activePaneID == other)
        #expect(store.marker(for: other) == nil)

        // An alert on the pane already in front is read by selecting it again.
        alert(other)
        #expect(store.marker(for: other) == .needsInput)
        workspace.selectPane(other)
        #expect(store.marker(for: other) == nil)
        // While Relay is in the background, an agent's selection or focus
        // moving to a neighbour is not seen: markers stay.
        frontmost = false
        let back = other == left ? right : left
        alert(back)
        workspace.selectPane(back)
        #expect(workspace.activePaneID == back)
        #expect(store.marker(for: back) == .needsInput)
        alert(firstPane)
        workspace.selectTab(first)
        #expect(store.marker(for: firstPane) == .needsInput)
        frontmost = true
    }

    @Test func failedToolsMarkThePaneRedBelowNeedsInput() {
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let pane = UUID()
        store.record(event(pane, .completion, .done, source: "t0"))
        store.record(event(pane, .failure, .toolFailed, source: "t1"))
        #expect(store.marker(for: pane) == .toolFailed && RelayAttentionAlert.toolFailed.color == RelayTheme.red)
        // Agents usually recover from a failed tool: no Dock count.
        #expect(store.panesNeedingUser == 0)
        // A pane that then waits on the user shows that, not the failure.
        store.record(event(pane, .attention, .needsInput, source: "t2"))
        store.record(event(pane, .failure, .toolFailed, source: "t3"))
        #expect(store.marker(for: pane) == .needsInput && store.panesNeedingUser == 1)
        // A reported error still outranks waiting.
        store.record(event(pane, .failure, .error, source: "t4"))
        #expect(store.marker(for: pane) == .error)
    }
}

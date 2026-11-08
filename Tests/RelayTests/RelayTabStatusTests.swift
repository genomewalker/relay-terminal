import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// Tabs, navigator rows and session rows show the fleet board's status:
/// the same pane facts and the same agents-only rule, most urgent wins.
@MainActor @Suite("Tab and navigator status marks")
struct RelayTabStatusTests {
    private typealias Index = RelayWorkOverviewIndex

    private func fact(_ status: Index.PaneStatus, tab: UUID = UUID(), isAgent: Bool = true) -> Index.PaneFact {
        Index.PaneFact(paneID: UUID(), tabID: tab, name: "pane", workspaceName: "Relay", tabName: "dev",
                       host: "This Mac", status: status, detail: status.label, changedAt: nil,
                       hiddenStackMember: false, isAgent: isAgent)
    }

    // MARK: Aggregation

    @Test("A group shows its most urgent agent status, nothing when idle")
    func mostUrgentWins() {
        #expect(Index.groupStatus([]) == nil)
        #expect(Index.groupStatus([fact(.idle), fact(.idle)]) == nil)
        #expect(Index.groupStatus([fact(.idle), fact(.running)]) == .running)
        #expect(Index.groupStatus([fact(.running), fact(.disconnected), fact(.idle)]) == .disconnected)
        #expect(Index.groupStatus([fact(.running), fact(.disconnected), fact(.waiting)]) == .waiting)
        // Agents only, like the board: a running or lost plain shell shows nothing.
        #expect(Index.groupStatus([fact(.running, isAgent: false)]) == nil)
        #expect(Index.groupStatus([fact(.disconnected, isAgent: false), fact(.idle)]) == nil)
        // A shell prompt waiting on the user is a board row, so it shows.
        #expect(Index.groupStatus([fact(.waiting, isAgent: false), fact(.running)]) == .waiting)
        // Each mark is exactly the most urgent of the board's rows for the group.
        let all = [fact(.running), fact(.waiting, isAgent: false), fact(.disconnected, isAgent: false), fact(.idle)]
        #expect(Index.groupStatus(all) == Index.Fleet(all).rows.map(\.status).min())
    }

    @Test("The focused tab drops running but keeps waiting and disconnected")
    func focusedTab() {
        #expect(Index.groupStatus([fact(.running)], focused: true) == nil)
        #expect(Index.groupStatus([fact(.running), fact(.idle)], focused: true) == nil)
        #expect(Index.groupStatus([fact(.running), fact(.waiting)], focused: true) == .waiting)
        #expect(Index.groupStatus([fact(.running), fact(.disconnected)], focused: true) == .disconnected)

        let focused = UUID(), other = UUID(), quiet = UUID()
        let facts = [fact(.running, tab: focused), fact(.running, tab: other), fact(.idle, tab: other),
                     fact(.idle, tab: quiet), fact(.running, tab: quiet, isAgent: false)]
        let marks = Index.tabStatuses(facts, focusedTabID: focused)
        #expect(marks == [other: .running])
        let waitingFocus = Index.tabStatuses(facts + [fact(.waiting, tab: focused)], focusedTabID: focused)
        #expect(waitingFocus == [focused: .waiting, other: .running])
    }

    @Test("A workspace or session row shows the most urgent of its tabs")
    func rowsAggregateTabs() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let marks: [UUID: Index.PaneStatus] = [a: .running, b: .disconnected, c: .waiting]
        #expect(Index.mostUrgent([a, b, c, d], in: marks) == .waiting)
        #expect(Index.mostUrgent([a, b], in: marks) == .disconnected)
        #expect(Index.mostUrgent([a, d], in: marks) == .running)
        #expect(Index.mostUrgent([d], in: marks) == nil)
        #expect(Index.mostUrgent([UUID](), in: marks) == nil)
    }

    @Test("Each mark has its own shape and a spoken label")
    func markKinds() {
        typealias Mark = RelayStatusMark
        #expect(Mark.kind(nil, reduceMotion: false) == .none)
        #expect(Mark.kind(.idle, reduceMotion: false) == .none)
        #expect(Mark.kind(.running, reduceMotion: false) == .spinner)
        #expect(Mark.kind(.running, reduceMotion: true) == .staticRunning)
        #expect(Mark.kind(.waiting, reduceMotion: false) == .symbol(RelayTheme.StatusRole.warning.symbol))
        #expect(Mark.kind(.waiting, reduceMotion: true) == .symbol(RelayTheme.StatusRole.warning.symbol))
        #expect(Mark.kind(.disconnected, reduceMotion: false) == .symbol(RelayTheme.StatusRole.danger.symbol))
        #expect(Mark.spoken(.waiting) == "Warning: Waiting on you")
        #expect(Mark.spoken(.disconnected) == "Error: Disconnected")
        #expect(Mark.spoken(.running) == "Success: Running")
        #expect(Mark.size >= 10)
    }

    @Test("A row's needs-you alert replaces its waiting mark; other marks stay")
    func oneIconPerMeaning() {
        typealias Mark = RelayStatusMark
        #expect(Mark.status(.waiting, besideAlert: .needsInput) == nil)
        #expect(Mark.status(.waiting, besideAlert: .error) == nil)
        // Once the alert is read, the waiting mark shows again.
        #expect(Mark.status(.waiting, besideAlert: nil) == .waiting)
        // Routine alerts do not say the row waits.
        #expect(Mark.status(.waiting, besideAlert: .done) == .waiting)
        #expect(Mark.status(.waiting, besideAlert: .toolFailed) == .waiting)
        // Running and disconnected say something the alert does not.
        #expect(Mark.status(.running, besideAlert: .needsInput) == .running)
        #expect(Mark.status(.disconnected, besideAlert: .error) == .disconnected)
        #expect(Mark.status(nil, besideAlert: .needsInput) == nil)
    }

    @Test("The spinner's layer animation runs only while shown in a visible window")
    func spinnerGating() {
        _ = NSApplication.shared
        func spinning(_ view: RelaySpinnerView) -> Bool {
            (view.layer?.sublayers ?? []).contains { $0.animation(forKey: "spin") != nil }
        }
        let view = RelaySpinnerView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        view.animating = true
        #expect(!spinning(view), "no window, no animation")
        // Never ordered in: nothing appears on screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        #expect(spinning(view))
        view.animating = false
        #expect(!spinning(view), "a hidden window stops the animation")
        view.animating = true
        #expect(spinning(view))
        view.removeFromSuperview()
        #expect(!spinning(view))
    }

    // MARK: Live workspace

    private func send(_ pane: PaneModel, _ json: String) { pane.receivedAgentEvent(Data(json.utf8)) }

    private struct Fixture {
        let workspace: WorkspaceModel
        let tabs: [String: UUID]
        let panes: [PaneModel]
    }

    /// Relay: review waits on approval, build runs unfocused, sweep lost its
    /// connection, chitta runs in the focused tab, notes and logs are shells.
    /// Pan-barley holds a lost agent; SMDB a running one.
    private func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.relayIsFrontmost = { true }
        var tabs: [String: UUID] = [:]
        var panes: [PaneModel] = []
        func open(_ name: String, host: String) throws -> PaneModel {
            workspace.newTab(profile: .sshConfigHost(host))
            let pane = workspace.activePane!
            let id = workspace.selectedTabID!
            try workspace.renameTab(id, to: name)
            tabs[name] = id
            panes.append(pane)
            return pane
        }
        let review = try open("review", host: "tab-status-review.invalid")
        let build = try open("build", host: "tab-status-build.invalid")
        let sweep = try open("sweep", host: "tab-status-sweep.invalid")
        _ = try open("notes", host: "tab-status-notes.invalid")
        let chitta = try open("chitta", host: "tab-status-chitta.invalid")
        _ = try open("logs", host: "tab-status-logs.invalid")
        let align = try open("align", host: "tab-status-align.invalid")
        let views = try open("views", host: "tab-status-views.invalid")
        _ = try open("import", host: "tab-status-import.invalid")

        send(review, #"{"agent":"claude","event":{"hook_event_name":"PermissionRequest","tool_name":"Bash","event_id":"tab-status-1"}}"#)
        for (index, pane) in [build, chitta, sweep, align, views].enumerated() {
            send(pane, #"{"agent":"claude","event":{"hook_event_name":"PreToolUse","tool_name":"Bash","event_id":"tab-status-run-\#(index)"}}"#)
        }
        sweep.connectionState = .disconnected("Host unreachable")
        align.connectionState = .disconnected("Host unreachable")

        let main = workspace.workspaceID(forTab: tabs["review"]!)!
        workspace.renameWorkspace(main, to: "Relay")
        let barley = workspace.createWorkspace(named: "Pan-barley")
        let smdb = workspace.createWorkspace(named: "SMDB")
        try workspace.performDrop(.tabOnWorkspace(tabID: tabs["align"]!, workspaceID: barley, index: nil))
        try workspace.performDrop(.tabOnWorkspace(tabID: tabs["views"]!, workspaceID: smdb, index: nil))
        try workspace.performDrop(.tabOnWorkspace(tabID: tabs["import"]!, workspaceID: smdb, index: nil))
        workspace.selectWorkspace(main, origin: .user)
        workspace.selectTab(tabs["chitta"]!, origin: .user)
        for id in [main, barley, smdb] { workspace.setNavigatorWorkspaceExpanded(id, true) }
        return Fixture(workspace: workspace, tabs: tabs, panes: panes)
    }

    @Test("Real panes: tab, workspace and board status agree")
    func liveWorkspace() throws {
        let fixture = try makeFixture()
        let workspace = fixture.workspace
        defer {
            for pane in fixture.panes { AgentIntelligenceStore.shared.markPaneRead(pane.id) }
            workspace.shutdown()
        }
        let tabs = fixture.tabs
        #expect(workspace.selectedTabID == tabs["chitta"])
        let facts = Index.paneFacts(workspace)
        let marks = Index.tabStatuses(facts, focusedTabID: workspace.selectedTabID)
        #expect(marks[tabs["review"]!] == .waiting)
        #expect(marks[tabs["build"]!] == .running)
        #expect(marks[tabs["sweep"]!] == .disconnected)
        #expect(marks[tabs["chitta"]!] == nil, "the focused tab shows no spinner")
        #expect(marks[tabs["notes"]!] == nil && marks[tabs["logs"]!] == nil, "plain shells show nothing")
        #expect(marks[tabs["align"]!] == .disconnected)
        #expect(marks[tabs["views"]!] == .running)
        // Unfocused, the same tab runs; that is the board's status for its pane.
        let unfocused = Index.tabStatuses(facts, focusedTabID: nil)
        #expect(unfocused[tabs["chitta"]!] == .running)
        for (tabID, status) in unfocused {
            #expect(status == Index.Fleet(facts.filter { $0.tabID == tabID }).rows.map(\.status).min())
        }
        func row(_ workspaceID: UUID) -> Index.PaneStatus? {
            Index.mostUrgent(workspace.tabs(inWorkspace: workspaceID).map(\.id), in: marks)
        }
        #expect(row(workspace.workspaceID(forTab: tabs["review"]!)!) == .waiting)
        #expect(row(workspace.workspaceID(forTab: tabs["align"]!)!) == .disconnected)
        #expect(row(workspace.workspaceID(forTab: tabs["views"]!)!) == .running)
        // The review pane's approval is an unread needs-input alert, so its
        // session row shows that marker alone.
        let reviewPane = workspace.paneIDs(inTab: tabs["review"]!).first!
        let alert = AgentIntelligenceStore.shared.marker(for: reviewPane)
        #expect(alert == .needsInput)
        #expect(RelayStatusMark.status(marks[tabs["review"]!], besideAlert: alert) == nil)
    }

    // MARK: Snapshots

    @Test("Tab strip and navigator render marks in light and dark")
    func snapshots() throws {
        let fixture = try makeFixture()
        let workspace = fixture.workspace
        defer {
            for pane in fixture.panes { AgentIntelligenceStore.shared.markPaneRead(pane.id) }
            workspace.shutdown()
        }
        let strip = WorkspaceTabRail(workspace: workspace)
        let navigator = WorkspaceNavigator(workspace: workspace)
            .frame(height: 600)
            .background(RelayTheme.sidebar)
        // The session list, every session and tab expanded.
        for tab in workspace.tabs {
            if !workspace.navigationState.isExpanded(.session, id: tab.sessionID) {
                workspace.toggleNavigationGroup(.session, id: tab.sessionID)
            }
        }
        let sessionList = SessionManager(workspace: workspace).frame(height: 760).background(RelayTheme.sidebar)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let shot = try RelaySnapshot.render(strip, name: "tab-status-strip", width: 1240, appearance: appearance)
            #expect(shot.size.height >= 36)
            let sessions = try RelaySnapshot.render(sessionList, name: "navigator-status-sessions", width: 260,
                                                    appearance: appearance)
            #expect(sessions.size.height >= 400)
            let list = try RelaySnapshot.render(navigator, name: "navigator-status", width: 280, appearance: appearance)
            #expect(list.size.height >= 600)
        }
    }
}

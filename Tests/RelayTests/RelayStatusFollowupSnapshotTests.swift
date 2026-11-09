import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// A workspace with one pane in each state the status follow-ups touch: a
/// failed exit that still carries a stale "Started" activity and an "error"
/// program report, a clean exit, a running agent, a reconnecting agent and a
/// wait. Shared by the logic tests and the renders.
@MainActor enum RelayStatusFollowupFixture {
    @MainActor struct Panes {
        let workspace: WorkspaceModel
        let store: AgentIntelligenceStore
        let failed, clean, running, reconnecting, waiting: PaneModel
        var all: [PaneModel] { [failed, clean, running, reconnecting, waiting] }

        func tearDown() {
            for pane in all { AgentIntelligenceStore.shared.markPaneRead(pane.id) }
            workspace.shutdown()
        }
    }

    static func send(_ pane: PaneModel, _ event: String, _ id: String) {
        pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"\#(event)","tool_name":"Bash","event_id":"\#(id)"}}"#.utf8))
    }

    static func make() throws -> Panes {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.relayIsFrontmost = { true }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        func open(_ name: String) throws -> PaneModel {
            workspace.newTab(profile: .sshConfigHost("status-followup-\(name).invalid"))
            let pane = try #require(workspace.activePane)
            try workspace.renameTab(try #require(workspace.selectedTabID), to: name)
            pane.connectionState = .connected
            return pane
        }
        let failed = try open("old-run"), clean = try open("notes-run"), running = try open("build")
        let reconnecting = try open("sweep"), waiting = try open("review")
        let focus = try open("scratch")
        for pane in [failed, clean] { send(pane, "SessionStart", "followup-start-\(pane.id)") }
        // The failed run's last report was an error; its process then exited 2.
        let records = try JSONDecoder().decode([RelayProgramStatusRecord].self,
                                               from: Data(#"[{"state":"error","title":"Build failed"}]"#.utf8))
        failed.applyProgramStatus(RelayStatus(state: "program_status", programStatus: records, programStatusRevision: 1,
                                              programStatusReplay: true), deliveryEpoch: UUID())
        failed.exited(exitCode: 2)
        clean.exited(exitCode: 0)
        for (index, pane) in [running, reconnecting].enumerated() { send(pane, "PreToolUse", "followup-run-\(index)") }
        reconnecting.connectionState = .reconnecting("link")
        send(waiting, "PermissionRequest", "followup-wait")
        // Keep the marks of every row visible: focus a plain shell.
        workspace.selectTab(try #require(workspace.tabID(containingPane: focus.id)), origin: .user)
        return Panes(workspace: workspace, store: store, failed: failed, clean: clean, running: running,
                     reconnecting: reconnecting, waiting: waiting)
    }
}

/// Before/after renders for the status follow-ups, light and dark.
@MainActor @Suite("Status follow-up renders", .serialized)
struct RelayStatusFollowupSnapshotTests {
    @Test("Sidebar navigator, fleet board and pane headers render in light and dark")
    func renders() throws {
        let f = try RelayStatusFollowupFixture.make()
        defer { f.tearDown() }
        // Sidebar: the inbox with the failed exit and the tab rows' marks.
        try RelayUIShot.window(WorkspaceNavigator(workspace: f.workspace), "followup-sidebar-navigator",
                               size: NSSize(width: 280, height: 560), background: RelayTheme.sidebar)
        let facts = RelayWorkOverviewIndex.paneFacts(f.workspace)
        let fleet = RelayWorkOverviewIndex.Fleet(facts)
        let now = Date()
        let board = VStack(alignment: .leading, spacing: RelayTheme.Space.lg) {
            RelayFleetBoardHeader(counts: fleet.counts, hostCount: fleet.hostCount, filter: .constant(.all), onClose: {})
            RelayFleetBoardList(facts: facts, filter: .all, now: now, onOpen: { _ in })
                .padding(RelayTheme.Space.xl)
        }.relaySurface()
        let header = VStack(spacing: 8) {
            ForEach([f.clean, f.failed], id: \.id) { pane in
                ConnectionPath(pane: pane, active: true, compact: false, zoomed: false, isFloating: false,
                               select: {}, toggleZoom: {}, toggleFloating: {}, rename: {}, terminate: nil, close: {})
                    .environmentObject(PaneLinkSelection())
            }
        }
        let counts = RelayFleetCountsButton(counts: fleet.counts, action: {}).padding(8)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let light = appearance == .aqua
            func scheme<V: View>(_ view: V) -> AnyView { light ? AnyView(view.environment(\.colorScheme, .light)) : AnyView(view) }
            let shot = try RelaySnapshot.render(scheme(board), name: "followup-fleet-board", width: 720, appearance: appearance)
            #expect(shot.size.height > 200)
            let headers = try RelaySnapshot.render(scheme(header), name: "followup-pane-headers", width: 760, appearance: appearance)
            #expect(headers.size.height > 20)
            let chips = try RelaySnapshot.render(scheme(counts), name: "followup-fleet-counts", width: 280, appearance: appearance)
            #expect(chips.size.height > 10)
        }
    }
}

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

@MainActor @Suite("Fleet board, navigator counts and Go to pane share one status")
struct RelayFleetBoardTests {
    private typealias Index = RelayWorkOverviewIndex
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fact(_ name: String, host: String = "This Mac", workspace: String = "Relay",
                      tab: String = "dev", _ status: Index.PaneStatus, detail: String? = nil,
                      minutesAgo: Double? = nil, hidden: Bool = false) -> Index.PaneFact {
        Index.PaneFact(paneID: UUID(), tabID: UUID(), name: name, workspaceName: workspace, tabName: tab,
                       host: host, status: status, detail: detail ?? status.label,
                       changedAt: minutesAgo.map { now.addingTimeInterval(-$0 * 60) }, hiddenStackMember: hidden)
    }

    /// Several Mac panes, several dandy-07 panes; every status represented.
    private var fixture: [Index.PaneFact] {
        [
            fact("chitta-dev", tab: "chitta", .running, detail: "Working", minutesAgo: 0.2),
            fact("relay-review", tab: "review", .waiting, detail: "Needs input · 1 approval", minutesAgo: 3),
            fact("notes", workspace: "Writing", tab: "draft", .idle, detail: "Idle", minutesAgo: 95),
            fact("relay-build", tab: "build", .running, detail: "Working", minutesAgo: 1),
            fact("smdb-import", host: "dandy-07", workspace: "SMDB", tab: "import", .waiting,
                 detail: "Needs input", minutesAgo: 12),
            fact("pan-barley-align", host: "dandy-07", workspace: "Pan-barley", tab: "align", .running,
                 detail: "Working", minutesAgo: 0.5),
            fact("metadmg-sweep", host: "dandy-07", workspace: "Pan-barley", tab: "sweep", .disconnected,
                 detail: "Connection lost", minutesAgo: 41),
            fact("smdb-matviews", host: "dandy-07", workspace: "SMDB", tab: "views", .idle,
                 detail: "Idle", minutesAgo: nil, hidden: true),
        ]
    }

    // MARK: Classification

    @Test("Each status comes from pane metadata, waiting first")
    func classification() {
        func status(_ phase: AgentPhase, approvals: Int = 0, program: String? = nil,
                    _ connection: PaneConnectionState = .connected) -> Index.PaneStatus {
            Index.paneStatus(phase: phase, approvals: approvals, programState: program, connection: connection)
        }
        #expect(status(.needsInput) == .waiting)
        #expect(status(.active, approvals: 2) == .waiting)
        #expect(status(.quiet, program: "blocked") == .waiting)
        #expect(status(.quiet, program: "error") == .waiting)
        // A wait outranks a lost connection: it still needs the user.
        #expect(status(.needsInput, .disconnected("lost")) == .waiting)
        #expect(status(.active, .disconnected("lost")) == .disconnected)
        #expect(status(.quiet, .reconnecting("retrying")) == .disconnected)
        #expect(status(.quiet, .waitingForNetwork("VPN")) == .disconnected)
        #expect(status(.exited) == .disconnected)
        #expect(status(.active) == .running)
        #expect(status(.quiet, program: "working") == .running)
        #expect(status(.quiet) == .idle)
        #expect(status(.quiet, program: "done") == .idle)
        // First connection in progress is not a lost connection.
        #expect(status(.connecting, .connecting) == .idle)
        // The board's waiting is exactly Go to pane's Needs attention.
        for phase in AgentPhase.allCases {
            for approvals in [0, 1] {
                for program in [nil, "blocked", "error", "working", "done", "idle"] as [String?] {
                    #expect((status(phase, approvals: approvals, program: program) == .waiting)
                            == Index.needsAttention(phase: phase, approvals: approvals, programState: program))
                }
            }
        }
        #expect(Index.PaneStatus.waiting.role == .warning)
        #expect(Index.PaneStatus.running.role == .success)
        #expect(Index.PaneStatus.disconnected.role == .danger)
        #expect(Index.PaneStatus.idle.role == .neutral)
    }

    @Test("Counts equal the board's rows for every status and chip")
    func countsMatchRows() {
        let facts = fixture
        let counts = Index.PaneCounts(facts)
        #expect(counts == .init(waiting: 2, disconnected: 1, running: 3, idle: 2))
        for status in Index.PaneStatus.allCases {
            #expect(counts[status] == facts.filter { $0.status == status }.count)
        }
        for filter in RelayFleetFilter.allCases {
            let rows = Index.boardOrder(facts.filter(filter.includes))
            #expect(rows.count == (filter.status.map { counts[$0] } ?? counts.total))
        }
        let order = Index.boardOrder(facts)
        #expect(order.map(\.status) == order.map(\.status).sorted())
        #expect(order.prefix(2).map(\.name) == ["relay-review", "smdb-import"])
        #expect(order.first { $0.status == .running }?.name == "chitta-dev")
        #expect(RelayFleetFilter.initial(for: counts) == .waiting)
        #expect(RelayFleetFilter.initial(for: .init()) == .all)
        #expect(RelayFleetCountsButton.spokenSummary(.init()) == "All quiet")
        #expect(RelayFleetCountsButton.spokenSummary(counts) == "3 running, 2 waiting on you")
        #expect(Index.changeLabel(nil, now: now) == "No activity")
        #expect(Index.changeLabel(now.addingTimeInterval(-30), now: now) == "Just now")
        #expect(Index.changeLabel(now.addingTimeInterval(-12 * 60), now: now) == "12 min ago")
        #expect(Index.changeLabel(now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
    }

    // MARK: Live workspace

    private func send(_ pane: PaneModel, _ json: String) { pane.receivedAgentEvent(Data(json.utf8)) }

    @Test("Board, counts and Go to pane agree on waiting for real panes")
    func boardAndGoToPaneAgree() {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.relayIsFrontmost = { true }
        workspace.newTab(profile: .sshConfigHost("fleet-waiting.invalid"))
        let waiting = workspace.activePane!
        workspace.newTab(profile: .sshConfigHost("fleet-running.invalid"))
        let running = workspace.activePane!
        workspace.newTab(profile: .sshConfigHost("fleet-lost.invalid"))
        let lost = workspace.activePane!
        workspace.newTab(profile: .sshConfigHost("fleet-idle.invalid"))
        let idle = workspace.activePane!
        defer { for pane in [waiting, running, lost, idle] { AgentIntelligenceStore.shared.markPaneRead(pane.id) } }

        send(waiting, #"{"agent":"claude","event":{"hook_event_name":"PermissionRequest","tool_name":"Bash","event_id":"fleet-1"}}"#)
        send(running, #"{"agent":"claude","event":{"hook_event_name":"PreToolUse","tool_name":"Bash","event_id":"fleet-2"}}"#)
        lost.connectionState = .disconnected("Host unreachable")

        let facts = Index.paneFacts(workspace)
        let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.paneID, $0) })
        #expect(byID[waiting.id]?.status == .waiting)
        #expect(byID[running.id]?.status == .running)
        #expect(byID[lost.id]?.status == .disconnected)
        #expect(byID[lost.id]?.detail == lost.connectionStatusLabel)
        #expect(byID[idle.id]?.status == .idle)
        #expect(byID[waiting.id]?.host == "fleet-waiting.invalid")
        // A plain shell with no agent signal is not a row, only counted as not shown.
        #expect(byID[idle.id]?.isAgent == false && byID[lost.id]?.isAgent == false)
        #expect(byID[waiting.id]?.isAgent == true && byID[running.id]?.isAgent == true)
        let fleet = Index.fleet(workspace)
        #expect(Set(fleet.rows.map(\.paneID)) == [waiting.id, running.id])
        #expect(fleet.shellsNotShown == facts.filter { !$0.isAgent && $0.status != .waiting }.count)
        #expect(fleet.shellsNotShown >= 2)

        let goToPane = RelayQuickNavigate.entries(for: workspace, query: "")
        let attention = Set(goToPane.compactMap { entry -> UUID? in
            guard entry.group == .attention, case .pane(let id, _) = entry.destination else { return nil }
            return id
        })
        let boardWaiting = Set(facts.filter { RelayFleetFilter.waiting.includes($0) }.map(\.paneID))
        #expect(attention == [waiting.id])
        #expect(boardWaiting == attention)
        #expect(fleet.counts.waiting == attention.count)
        #expect(fleet.counts.running == 1)
        // Go to pane lists the board as an action.
        #expect(goToPane.contains { $0.destination == .fleetBoard && $0.group == .actions })
    }

    @Test("Plain shells are not rows; a shell waiting on the user still is")
    func agentsOnly() {
        func shell(_ name: String, _ status: Index.PaneStatus) -> Index.PaneFact {
            Index.PaneFact(paneID: UUID(), tabID: UUID(), name: name, workspaceName: "Relay", tabName: "sh",
                           host: "This Mac", status: status, detail: status.label, changedAt: nil,
                           hiddenStackMember: false, isAgent: false)
        }
        let agents = fixture
        let fleet = Index.Fleet(agents + [shell("zsh", .idle), shell("zsh 2", .running),
                                          shell("ssh", .disconnected), shell("confirm-prompt", .waiting)])
        #expect(fleet.rows.count == agents.count + 1)
        #expect(!fleet.rows.contains { $0.name == "zsh" || $0.name == "zsh 2" || $0.name == "ssh" })
        #expect(fleet.rows.contains { $0.name == "confirm-prompt" })
        #expect(fleet.shellsNotShown == 3)
        #expect(fleet.counts == Index.PaneCounts(fleet.rows))
        #expect(RelayFleetBoardHeader.subtitle(total: 8, hosts: 2, shellsNotShown: 40) == "8 agents on 2 hosts · 40 shells not shown")
        #expect(RelayFleetBoardHeader.subtitle(total: 1, hosts: 1, shellsNotShown: 0) == "1 agent on 1 host")
    }

    @Test("Opening a pane from the board records a user visit and closes the board")
    func jumpRecordsVisit() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.relayIsFrontmost = { true }
        workspace.newTab(profile: .sshConfigHost("fleet-jump.invalid"))
        let target = workspace.activePane!
        workspace.newTab(profile: .sshConfigHost("fleet-jump.invalid"))
        #expect(workspace.activePaneID != target.id)
        #expect(workspace.paneVisits.visit(target.id) == nil)
        workspace.presentFleetBoard(filter: .waiting)
        #expect(workspace.isFleetBoardPresented && workspace.fleetBoardInitialFilter == .waiting)

        let fact = Index.paneFacts(workspace).first { $0.paneID == target.id }!
        workspace.networkVisible = true
        RelayFleetBoard.open(fact, in: workspace)
        #expect(!workspace.networkVisible)
        #expect(workspace.activePaneID == target.id)
        #expect(workspace.selectedTabID == fact.tabID)
        #expect(workspace.paneVisits.visit(target.id)?.lastVisitedAt != nil)
        #expect(!workspace.isFleetBoardPresented)
    }

    @Test("Opening a pane from an attention notification records a user visit")
    func notificationOpenRecordsVisit() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.relayIsFrontmost = { true }
        workspace.newTab(profile: .sshConfigHost("fleet-notify.invalid"))
        let target = workspace.activePane!
        workspace.newTab(profile: .sshConfigHost("fleet-notify.invalid"))
        #expect(workspace.paneVisits.visit(target.id) == nil)
        RelayAttentionNotifier(workspace: workspace).open(target.id)
        #expect(workspace.activePaneID == target.id)
        #expect(workspace.paneVisits.visit(target.id)?.lastVisitedAt != nil)
        // Programmatic callers (agents, MCP) still record nothing.
        let other = workspace.paneIDs(inTab: workspace.tabs.last!.id)[0]
        _ = try? workspace.selectWorkspacePane(other)
        #expect(workspace.paneVisits.visit(other) == nil)
    }

    @Test("Keyboard shortcut is free and listed with Go to pane")
    func shortcut() {
        let binding = RelayCommand.fleetBoard.defaultBinding
        #expect(RelayKeyBindingStorage.conflict(for: binding, command: .fleetBoard, overrides: [:]) == nil)
        #expect(RelayKeyBindingStorage.reservedConflictName(for: binding) == nil)
        #expect(RelayCommand.fleetBoard.section == RelayCommand.quickNavigate.section)
    }

    // MARK: Snapshots

    @Test("Board and counts render in light and dark")
    func snapshots() throws {
        let facts = fixture
        let counts = Index.PaneCounts(facts)
        let board = VStack(alignment: .leading, spacing: 0) {
            RelayFleetBoardHeader(counts: counts, hostCount: Set(facts.map(\.host)).count,
                                  shellsNotShown: 40, filter: .constant(.all), onClose: {})
                .padding(RelayTheme.Space.xl)
            Divider()
            RelayFleetBoardList(facts: facts, filter: .all, now: now, onOpen: { _ in })
                .padding(RelayTheme.Space.xl)
        }.relaySurface()
        let waitingOnly = VStack(alignment: .leading, spacing: 0) {
            RelayFleetBoardHeader(counts: counts, hostCount: 2, filter: .constant(.waiting), onClose: {})
                .padding(RelayTheme.Space.xl)
            Divider()
            RelayFleetBoardList(facts: facts, filter: .waiting, now: now, onOpen: { _ in })
                .padding(RelayTheme.Space.xl)
        }.relaySurface()
        let header = VStack(alignment: .leading, spacing: RelayTheme.Space.md) {
            RelayFleetCountsButton(counts: counts, action: {})
            RelayFleetCountsButton(counts: .init(facts.filter { $0.status == .running }), action: {})
            RelayFleetCountsButton(counts: .init(facts.filter { $0.status == .waiting }), action: {})
            RelayFleetCountsButton(counts: .init(facts.filter { $0.status == .idle }), action: {})
        }
        .padding(RelayTheme.Space.md)
        .background(RelayTheme.sidebar)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let shot = try RelaySnapshot.render(board, name: "fleet-board", width: 720, appearance: appearance)
            #expect(shot.size.height > 400)
            let filtered = try RelaySnapshot.render(waitingOnly, name: "fleet-board-waiting", width: 720, appearance: appearance)
            #expect(filtered.size.height > 150)
            let counts = try RelaySnapshot.render(header, name: "fleet-counts", width: 240, appearance: appearance)
            #expect(counts.size.height > 60)
        }
    }
}

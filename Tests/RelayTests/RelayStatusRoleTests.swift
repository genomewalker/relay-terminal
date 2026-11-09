import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// Red is for failures: a lost or returning connection and a clean exit are
/// calm; a non-zero exit and an error still say so.
@MainActor @Suite("Status roles: red only for failures, labelled counts")
struct RelayStatusRoleTests {
    private typealias Index = RelayWorkOverviewIndex
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Each status maps to a calm or danger role, always with its own symbol")
    func roles() {
        func status(_ phase: AgentPhase, program: String? = nil, _ connection: PaneConnectionState = .connected,
                    failedExit: Bool = false) -> Index.PaneStatus {
            Index.paneStatus(phase: phase, approvals: 0, programState: program, connection: connection, failedExit: failedExit)
        }
        #expect(status(.quiet, .reconnecting("retry")).role == .pending)
        #expect(status(.quiet, .waitingForNetwork("VPN")).role == .pending)
        #expect(status(.active, .disconnected("lost")).role == .offline)
        #expect(status(.exited).role == .neutral)
        #expect(status(.quiet).role == .neutral)
        // A real failure keeps the attention role and says why.
        #expect(status(.exited, failedExit: true) == .waiting)
        #expect(status(.quiet, program: "error") == .waiting)
        // Nothing but a failure maps to red; the calm roles are grey.
        for state in Index.PaneStatus.allCases { #expect(state.role != .danger) }
        for role in [RelayTheme.StatusRole.pending, .offline] {
            #expect(role.color == RelayTheme.StatusRole.neutral.color)
            #expect(role != .danger && role.symbol != RelayTheme.StatusRole.danger.symbol)
        }
        #expect(Set(Index.PaneStatus.allCases.map(\.role.symbol)).count == Index.PaneStatus.allCases.count)
    }

    @Test("The summary strip is always labelled and stays on one line")
    func labels() {
        let counts = Index.PaneCounts(waiting: 2, disconnected: 2, reconnecting: 1, running: 3, idle: 9)
        #expect(RelayFleetCountsButton.segments(counts) == [.waiting, .disconnected, .reconnecting, .running])
        #expect(RelayFleetCountsButton.shortLabel(.disconnected, 2) == "2 disconnected")
        #expect(RelayFleetCountsButton.shortLabel(.reconnecting, 1) == "1 reconnecting")
        #expect(RelayFleetCountsButton.spokenSummary(counts) == "2 waiting on you, 2 disconnected, 1 reconnecting, 3 running")
        #expect(counts.total == 17)
        // The Disconnected chip also lists panes whose connection is returning.
        #expect(RelayFleetFilter.disconnected.statuses == [.disconnected, .reconnecting])
    }

    private func fact(_ name: String, _ status: Index.PaneStatus, detail: String, host: String = "dandy-07",
                      workspace: String = "Pan-barley", tab: String = "sweep", minutesAgo: Double = 5) -> Index.PaneFact {
        Index.PaneFact(paneID: UUID(), tabID: UUID(), name: name, workspaceName: workspace, tabName: tab, host: host,
                       status: status, detail: detail, changedAt: now.addingTimeInterval(-minutesAgo * 60),
                       hiddenStackMember: false)
    }

    @Test("Sidebar strip (compact and normal width) and fleet board, light and dark")
    func snapshots() throws {
        let facts = [
            fact("smdb-import", .waiting, detail: "Needs input", minutesAgo: 3),
            fact("old-run", .waiting, detail: "Exited with status 2", minutesAgo: 9),
            fact("metadmg-sweep", .disconnected, detail: "Connection lost", minutesAgo: 41),
            fact("pan-barley-align", .reconnecting, detail: "Reconnecting", minutesAgo: 6),
            fact("relay-build", .running, detail: "Working", host: "This Mac", workspace: "Relay", tab: "build", minutesAgo: 1),
            fact("notes", .idle, detail: "Exited", host: "This Mac", workspace: "Relay", tab: "notes", minutesAgo: 90),
        ]
        let counts = Index.PaneCounts(facts)
        let many = Index.PaneCounts(waiting: 2, disconnected: 21, reconnecting: 4, running: 69, idle: 3)
        let strips = VStack(alignment: .leading, spacing: RelayTheme.Space.md) {
            RelayFleetCountsButton(counts: counts, action: {}).frame(width: 244)
            RelayFleetCountsButton(counts: counts, action: {}).frame(width: 260)
            RelayFleetCountsButton(counts: many, action: {}).frame(width: 244)
            // The live app's counts at the compact sidebar width.
            RelayFleetCountsButton(counts: .init(waiting: 1, disconnected: 21, running: 69, idle: 3), action: {}).frame(width: 244)
        }
        .padding(RelayTheme.Space.md)
        .background(RelayTheme.sidebar)
        let board = VStack(alignment: .leading, spacing: 0) {
            RelayFleetBoardHeader(counts: counts, hostCount: 2, filter: .constant(.all), onClose: {})
                .padding(RelayTheme.Space.xl)
            Divider()
            RelayFleetBoardList(facts: facts, filter: .all, now: now, onOpen: { _ in })
                .padding(RelayTheme.Space.xl)
        }.relaySurface()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let light = appearance == .aqua
            let strip = try RelaySnapshot.render(light ? AnyView(strips.environment(\.colorScheme, .light)) : AnyView(strips),
                                                 name: "status-sidebar-strip", width: 280, appearance: appearance)
            #expect(strip.size.height > 60)
            let shot = try RelaySnapshot.render(light ? AnyView(board.environment(\.colorScheme, .light)) : AnyView(board),
                                                name: "status-fleet-board", width: 720, appearance: appearance)
            #expect(shot.size.height > 300)
        }
        let f = try RelayAttentionClassificationTests.makeFixture()
        defer { f.workspace.shutdown() }
        try RelayUIShot.window(WorkspaceNavigator(workspace: f.workspace, inbox: f.store), "status-sidebar-navigator",
                               size: NSSize(width: 244, height: 520), background: RelayTheme.sidebar)
        try RelayUIShot.window(WorkspaceNavigator(workspace: f.workspace, inbox: f.store), "status-sidebar-navigator-wide",
                               size: NSSize(width: 260, height: 520), background: RelayTheme.sidebar)
    }
}

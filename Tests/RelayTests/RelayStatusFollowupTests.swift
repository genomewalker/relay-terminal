import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// A failed exit reads the same everywhere (red, "Exited with status N"),
/// a clean exit is never red, and running never looks like reconnecting.
@MainActor @Suite("Status follow-ups", .serialized)
struct RelayStatusFollowupTests {
    private typealias Index = RelayWorkOverviewIndex

    @Test("A failed exit's inbox subtitle is its status, not a stale activity or report")
    func failedExitSubtitle() throws {
        let f = try RelayStatusFollowupFixture.make()
        defer { f.tearDown() }
        // The fixture's failed pane last said "Started" and reported an error.
        #expect(f.failed.agentActivities.contains { $0.label == "Started" })
        #expect(f.failed.programStatus.records.map(\.state) == ["error"])
        let rows = f.workspace.attentionInbox(inbox: f.store)
        let row = try #require(rows.first { $0.paneID == f.failed.id })
        #expect(row.title == "Exited with status 2")
        #expect(row.alert == .error)
        #expect(!rows.contains { $0.paneID == f.clean.id }, "a clean exit is not attention")
        // Dismissing hides it although the stale error report remains.
        f.workspace.dismissAttention(f.failed.id, inbox: f.store)
        #expect(!f.workspace.attentionInbox(inbox: f.store).contains { $0.paneID == f.failed.id })
    }

    @Test("The fleet board files a failed exit as Failed, red, like the sidebar")
    func fleetBoardFailedRow() throws {
        let f = try RelayStatusFollowupFixture.make()
        defer { f.tearDown() }
        let facts = Dictionary(uniqueKeysWithValues: Index.paneFacts(f.workspace).map { ($0.paneID, $0) })
        let failed = try #require(facts[f.failed.id])
        #expect(failed.status == .failed)
        #expect(failed.status.role == .danger)
        #expect(failed.detail == "Exited with status 2")
        // Same symbol and colour as the sidebar inbox row's error alert.
        #expect(failed.status.symbol == RelayAttentionAlert.error.symbol)
        // The alert draws with the red token, the role with danger: same colour.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            func rgb(_ color: NSColor) -> [CGFloat] {
                var value: [CGFloat] = []
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    let c = color.usingColorSpace(.sRGB)!
                    value = [c.redComponent, c.greenComponent, c.blueComponent]
                }
                return value
            }
            #expect(rgb(RelayPalette.danger) == rgb(RelayPalette.red), "\(name.rawValue)")
        }
        // Still waiting on the user: counted, listed under the Waiting filter.
        #expect(failed.status.needsUser)
        #expect(RelayFleetFilter.waiting.includes(failed))
        let fleet = Index.Fleet(Array(facts.values))
        #expect(fleet.counts.failed == 1 && fleet.counts.waiting == 1)
        #expect(RelayFleetFilter.initial(for: fleet.counts) == .waiting)
        // Waits and approvals stay amber; a clean exit is idle and grey.
        #expect(facts[f.waiting.id]?.status == .waiting)
        #expect(Index.PaneStatus.waiting.role == .warning)
        #expect(facts[f.clean.id]?.status == .idle)
        // The sidebar tab row's mark agrees.
        let marks = Index.tabStatuses(Array(facts.values), focusedTabID: f.workspace.selectedTabID)
        let tab = try #require(f.workspace.tabID(containingPane: f.failed.id))
        #expect(marks[tab] == .failed)
        #expect(RelayStatusMark.kind(marks[tab]) == .symbol(RelayTheme.StatusRole.danger.symbol))
        #expect(RelayFleetCountsButton.shortLabel(.failed, 1) == "1 failed")
    }

    @Test("The agent chip is muted after a clean exit and red only after a failed one")
    func agentChipRole() throws {
        let f = try RelayStatusFollowupFixture.make()
        defer { f.tearDown() }
        #expect(f.clean.phase == .exited && f.failed.phase == .exited)
        #expect(f.clean.exitRole == .neutral)
        #expect(f.clean.phaseColor == RelayTheme.StatusRole.neutral.color)
        #expect(f.failed.exitRole == .danger)
        #expect(f.failed.phaseColor == RelayTheme.StatusRole.danger.color)
        // The chip and the header status agree.
        #expect(f.clean.headerStatus?.role == f.clean.exitRole)
        #expect(f.failed.headerStatus?.role == f.failed.exitRole)
        // A running pane keeps its phase colour.
        #expect(f.running.exitRole == nil)
        #expect(f.running.phaseColor == f.running.phase.color)
    }

    @Test("Running uses a waveform, never the reconnecting arrows")
    func runningMark() throws {
        typealias Mark = RelayStatusMark
        #expect(Mark.kind(.running) != Mark.kind(.reconnecting))
        #expect(Mark.runningSymbol != RelayTheme.StatusRole.pending.symbol)
        #expect(!Mark.runningSymbol.contains("circlepath") && !Mark.runningSymbol.contains("arrow"))
        #expect(Index.PaneStatus.running.symbol != RelayTheme.StatusRole.success.symbol, "working is not finished")
        #expect(Index.PaneStatus.reconnecting.symbol == RelayTheme.StatusRole.pending.symbol)
        #expect(Index.PaneStatus.reconnecting.role.color == RelayTheme.StatusRole.neutral.color, "reconnecting stays grey")
        let f = try RelayStatusFollowupFixture.make()
        defer { f.tearDown() }
        let facts = Index.paneFacts(f.workspace)
        let marks = Index.tabStatuses(facts, focusedTabID: f.workspace.selectedTabID)
        let running = try #require(f.workspace.tabID(containingPane: f.running.id))
        let reconnecting = try #require(f.workspace.tabID(containingPane: f.reconnecting.id))
        #expect(marks[running] == .running && marks[reconnecting] == .reconnecting)
        #expect(Mark.kind(marks[running]) == .symbol("waveform"))
    }
}

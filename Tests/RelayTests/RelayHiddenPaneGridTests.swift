import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Hidden panes attach at their tab's grid")
struct RelayHiddenPaneGridTests {
    private let a = UUID(), b = UUID(), c = UUID(), split = UUID(), inner = UUID()

    @Test("A pane's share follows the split tree and its clamped ratios")
    func shares() {
        let layout = PaneLayout.split(id: split, axis: .horizontal, first: .pane(a),
            second: .split(id: inner, axis: .vertical, first: .pane(b), second: .pane(c)))
        let ratios = [split: 0.25, inner: 0.95]
        let first = RelayHiddenPaneGrid.share(of: a, in: layout, ratios: ratios)
        #expect(first?.width == 0.25 && first?.height == 1)
        let top = RelayHiddenPaneGrid.share(of: b, in: layout, ratios: ratios)
        #expect(top?.width == 0.75 && top?.height == 0.88)
        #expect(RelayHiddenPaneGrid.share(of: UUID(), in: layout, ratios: ratios) == nil)
    }

    // Panes 372a79db and 28711135 (dandy-07, 2026-11-15) came back about 58
    // columns wide from a stale saved grid while their tab lays them out
    // about 130 wide; the scrambled redraw blocked their account moves.
    @Test("A hidden half-width pane gets half the shown canvas, not its stale saved grid")
    func halfOfTheCanvas() {
        let shown = PaneLayout.pane(a)
        let canvas = RelayHiddenPaneGrid.canvas(layout: shown, ratios: [:]) { $0 == self.a ? .init(columns: 262, rows: 64) : nil }
        let hidden = PaneLayout.split(id: split, axis: .horizontal, first: .pane(b), second: .pane(c))
        let grid = RelayHiddenPaneGrid.viewport(for: c, layout: hidden, ratios: [:], stacks: [], canvas: canvas)
        #expect(grid == RelayViewport(columns: 131, rows: 64))
    }

    @Test("The canvas is recovered from a split shown tab")
    func canvasFromASplitTab() {
        let shown = PaneLayout.split(id: split, axis: .vertical, first: .pane(a), second: .pane(b))
        let grids: [UUID: RelayViewport] = [a: .init(columns: 200, rows: 15), b: .init(columns: 200, rows: 45)]
        let canvas = RelayHiddenPaneGrid.canvas(layout: shown, ratios: [split: 0.25]) { grids[$0] }
        #expect(canvas?.columns == 200 && canvas?.rows == 60)
    }

    @Test("A hidden stack member takes its stack's slot")
    func stackMember() {
        let hidden = PaneLayout.split(id: split, axis: .horizontal, first: .pane(a), second: .pane(b))
        let stack = PaneStack(id: UUID(), members: [b, c], selected: b)
        let grid = RelayHiddenPaneGrid.viewport(for: c, layout: hidden, ratios: [:], stacks: [stack],
                                                canvas: (columns: 200, rows: 50))
        #expect(grid == RelayViewport(columns: 100, rows: 50))
    }

    @Test("Unknown canvas, floating panes and tiny results fall back to the saved grid")
    func fallbacks() {
        let hidden = PaneLayout.pane(a)
        #expect(RelayHiddenPaneGrid.viewport(for: a, layout: hidden, ratios: [:], stacks: [], canvas: nil) == nil)
        #expect(RelayHiddenPaneGrid.viewport(for: b, layout: hidden, ratios: [:], stacks: [], canvas: (200, 50)) == nil)
        #expect(RelayHiddenPaneGrid.viewport(for: a, layout: hidden, ratios: [:], stacks: [], canvas: (15, 50)) == nil)
        #expect(RelayHiddenPaneGrid.canvas(layout: hidden, ratios: [:]) { _ in nil } == nil)
    }

    @Test("The scheduler starts a hidden pane at its layout grid when one is known")
    func schedulerPrefersTheLayoutGrid() {
        let scheduler = RelayBackgroundAttachScheduler()
        let known = PaneModel(profile: .sshConfigHost("dandy.invalid"), requiresExistingWorker: true)
        let unknown = PaneModel(profile: .sshConfigHost("dandy.invalid"), requiresExistingWorker: true)
        let saved = RelayViewport(columns: 58, rows: 40), layout = RelayViewport(columns: 131, rows: 64)
        var now: UInt64 = 0
        var started: [UUID: RelayViewport] = [:]
        scheduler.panes = { [known, unknown] }
        scheduler.nodes = { [] }
        scheduler.uptime = { now }
        scheduler.savedViewport = { _ in saved }
        scheduler.layoutViewport = { $0.id == known.id ? layout : nil }
        scheduler.start = { pane, viewport in started[pane.id] = viewport; pane.connectionState = .connected }
        scheduler.step()
        now = RelayBackgroundAttachPolicy.gapNanoseconds
        scheduler.step()
        #expect(started[known.id] == layout)
        #expect(started[unknown.id] == saved)
    }
}

import Foundation

/// The grid a hidden pane would have if its tab were shown now.
///
/// A restored pane whose tab has not been shown attaches in the background
/// (RelayBackgroundAttachScheduler). It used to attach at the grid its
/// snapshot log was last saved at, which can be far from its real size: on
/// 2026-11-15 Codex panes 372a79db and 28711135 came back about 58 columns
/// wide though their tab lays them out about 130 wide. The worker resized the
/// agent to that width, the agent redrew for it, and the screen was scrambled
/// until the tab was shown. Account moves and restarts then refused the pane
/// because its prompt could not be read.
///
/// All tabs of a workspace share one canvas. The shown tab's laid-out panes
/// give the canvas size in cells: a pane's grid divided by its share of the
/// canvas. The hidden pane's share of its own tab's canvas then gives its
/// grid. Dividers and padding are ignored; the result is within a column or
/// two of the real layout, which corrects it exactly once the tab is shown.
enum RelayHiddenPaneGrid {
    /// The share of the canvas, as (width, height) fractions, that `pane`
    /// occupies in `layout`. The ratio is clamped like RelaySplitGeometry.
    static func share(of pane: UUID, in layout: PaneLayout, ratios: [UUID: Double]) -> (width: Double, height: Double)? {
        switch layout {
        case .pane(let id):
            return id == pane ? (1, 1) : nil
        case .split(let id, let axis, let first, let second):
            let raw = ratios[id] ?? 0.5
            let ratio = min(max(raw.isFinite ? raw : 0.5, 0.12), 0.88)
            if let inner = share(of: pane, in: first, ratios: ratios) {
                return axis == .horizontal ? (inner.width * ratio, inner.height) : (inner.width, inner.height * ratio)
            }
            if let inner = share(of: pane, in: second, ratios: ratios) {
                return axis == .horizontal ? (inner.width * (1 - ratio), inner.height) : (inner.width, inner.height * (1 - ratio))
            }
            return nil
        }
    }

    /// The layout slot a pane occupies: itself, or the selected member of
    /// the stack it is hidden in. Floating panes have no slot.
    static func slot(of pane: UUID, layout: PaneLayout, stacks: [PaneStack]) -> UUID? {
        if layout.paneIDs.contains(pane) { return pane }
        return stacks.first { $0.members.contains(pane) && layout.paneIDs.contains($0.selected) }?.selected
    }

    /// The canvas size in cells, from the shown tab's laid-out panes. The
    /// largest laid-out pane is used, since it rounds least.
    static func canvas(layout: PaneLayout, ratios: [UUID: Double],
                       grid: (UUID) -> RelayViewport?) -> (columns: Double, rows: Double)? {
        var best: (area: Double, columns: Double, rows: Double)?
        for id in layout.paneIDs {
            guard let viewport = grid(id), let part = share(of: id, in: layout, ratios: ratios),
                  part.width > 0, part.height > 0 else { continue }
            let area = Double(viewport.columns) * Double(viewport.rows)
            if best == nil || area > best!.area {
                best = (area, Double(viewport.columns) / part.width, Double(viewport.rows) / part.height)
            }
        }
        return best.map { ($0.columns, $0.rows) }
    }

    /// The hidden pane's grid in its tab, or nil when the canvas or its slot
    /// is unknown (callers fall back to the saved grid).
    static func viewport(for pane: UUID, layout: PaneLayout, ratios: [UUID: Double], stacks: [PaneStack],
                         canvas: (columns: Double, rows: Double)?) -> RelayViewport? {
        guard let canvas, let slot = slot(of: pane, layout: layout, stacks: stacks),
              let part = share(of: slot, in: layout, ratios: ratios) else { return nil }
        let columns = Int((canvas.columns * part.width).rounded(.down))
        let rows = Int((canvas.rows * part.height).rounded(.down))
        guard columns >= 20, rows >= 5 else { return nil }
        return RelayViewport(columns: columns, rows: rows)
    }

    /// The grid `pane` would have in `workspace` if its tab were shown now.
    @MainActor static func viewport(for pane: UUID, in workspace: WorkspaceModel) -> RelayViewport? {
        guard let shown = workspace.selectedTab,
              let tab = workspace.tabs.first(where: { $0.allPaneIDs.contains(pane) }), tab !== shown else { return nil }
        let canvas = canvas(layout: shown.layout, ratios: shown.splitRatios) { workspace.panes[$0]?.runtime.laidOutGrid }
        return viewport(for: pane, layout: tab.layout, ratios: tab.splitRatios, stacks: tab.stacks, canvas: canvas)
    }
}

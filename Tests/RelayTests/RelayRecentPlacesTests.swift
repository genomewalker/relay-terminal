import AppKit
import SwiftUI
import Testing
@testable import Relay

/// ⌃Tab recent places (spec work/pane-close-detach-spec-20261110.md,
/// Feature 3): newest first across workspaces, a quick tap flips to the
/// previous pane, browsing records nothing, stale rows never jump.
@MainActor @Suite(.serialized) struct RelayRecentPlacesTests {
    private struct Fixture {
        let workspace: WorkspaceModel
        let a: PaneModel, b: PaneModel, c: PaneModel
        let alpha: UUID, beta: UUID
    }

    private static func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let alpha = workspace.createWorkspace(named: "Alpha"), beta = workspace.createWorkspace(named: "Beta")
        func pane(_ host: String, in owner: UUID) throws -> PaneModel {
            workspace.newTab(profile: .sshConfigHost(host))
            let tab = try #require(workspace.selectedTab)
            let pane = try #require(workspace.activePane)
            try workspace.moveTab(tab.id, toWorkspace: owner)
            return pane
        }
        let a = try pane("recent-a.invalid", in: alpha)
        let b = try pane("recent-b.invalid", in: beta)
        let c = try pane("recent-c.invalid", in: beta)
        for pane in [a, b, c] { workspace.revealPane(pane.id, origin: .user) }
        return Fixture(workspace: workspace, a: a, b: b, c: c, alpha: alpha, beta: beta)
    }

    @Test func listsTheCurrentPaneThenTheMostRecentAcrossWorkspaces() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let places = RelayRecentPlaces.places(for: f.workspace)
        #expect(Array(places.prefix(3).map(\.id)) == [f.c.id, f.b.id, f.a.id])
        #expect(places.first?.isCurrent == true)
        #expect(places.count <= RelayRecentPlaces.limit)
        let a = try #require(places.first { $0.id == f.a.id })
        #expect(a.location.hasPrefix("Alpha › "))
        #expect(a.accessibilityLabel.contains(a.title) && a.accessibilityLabel.contains("Alpha"))
    }

    /// Check 1: a quick tap goes to B; another goes back to C.
    @Test func aQuickTapFlipsToThePreviousPaneAndBack() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let switcher = RelayRecentPlacesSwitcher()
        switcher.install(workspace: f.workspace)
        defer { switcher.uninstall() }
        #expect(switcher.begin(places: RelayRecentPlaces.places(for: f.workspace)))
        #expect(switcher.handle(.released))
        #expect(f.workspace.activePaneID == f.b.id)
        #expect(!switcher.isVisible && !switcher.isActive)
        switcher.begin(places: RelayRecentPlaces.places(for: f.workspace))
        switcher.handle(.released)
        #expect(f.workspace.activePaneID == f.c.id)
    }

    /// Check 2: held with Tab twice lands on A, in A's workspace and tab.
    @Test func tabTwiceThenReleaseCrossesToTheOtherWorkspace() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let switcher = RelayRecentPlacesSwitcher()
        switcher.install(workspace: f.workspace)
        defer { switcher.uninstall() }
        switcher.begin(places: RelayRecentPlaces.places(for: f.workspace))
        switcher.handle(.next)
        #expect(switcher.places[switcher.selection].id == f.a.id)
        switcher.handle(.released)
        #expect(f.workspace.activePaneID == f.a.id)
        #expect(f.workspace.selectedWorkspaceID == f.alpha)
        #expect(f.workspace.selectedTabID == f.workspace.tabID(containingPane: f.a.id))
        // A digit jumps directly; Esc stays put.
        switcher.begin(places: RelayRecentPlaces.places(for: f.workspace))
        switcher.handle(.cancel)
        #expect(f.workspace.activePaneID == f.a.id)
        switcher.begin(places: RelayRecentPlaces.places(for: f.workspace))
        switcher.handle(.digit(3))
        #expect(f.workspace.activePaneID == f.b.id)
    }

    /// Check 3: a closed pane is not listed, and a row that went stale while
    /// open never jumps.
    @Test func closedPanesAreDroppedAndStaleRowsNeverJump() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let switcher = RelayRecentPlacesSwitcher()
        switcher.install(workspace: f.workspace)
        defer { switcher.uninstall() }
        let shown = RelayRecentPlaces.places(for: f.workspace)
        switcher.begin(places: shown)
        // B goes away while the switcher is open on it.
        f.workspace.revealPane(f.b.id, origin: .user)
        f.workspace.closeActivePane()
        let before = f.workspace.activePaneID
        switcher.handle(.released)
        #expect(f.workspace.activePaneID == before)
        #expect(f.workspace.panes[f.b.id] == nil)
        #expect(!RelayRecentPlaces.places(for: f.workspace).map(\.id).contains(f.b.id))
    }

    /// Check 4: opening and browsing change no visit order.
    @Test func browsingRecordsNoVisit() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let switcher = RelayRecentPlacesSwitcher()
        switcher.install(workspace: f.workspace)
        defer { switcher.uninstall() }
        let visits = f.workspace.paneVisits
        let active = f.workspace.activePaneID
        switcher.begin(places: RelayRecentPlaces.places(for: f.workspace))
        switcher.handle(.next); switcher.handle(.previous); switcher.handle(.other)
        switcher.handle(.cancel)
        #expect(f.workspace.paneVisits == visits)
        #expect(f.workspace.activePaneID == active)
        // Nothing else to go to: the key stays with the pane.
        #expect(!switcher.begin(places: Array(RelayRecentPlaces.places(for: f.workspace).prefix(1))))
    }

    @Test func defaultBindingIsControlTabAndRecordsTab() {
        let binding = RelayCommand.recentPlaces.defaultBinding
        #expect(binding == RelayKeyBinding("tab", control: true))
        #expect(binding.displayName == "⌃⇥")
        #expect(RelayCommand.recentPlaces.section == "Panes")
        #expect(RelayCommand.allCases.filter { $0 != .recentPlaces }.allSatisfy { $0.defaultBinding != binding })
    }

    /// Check 5: the panel in light and dark.
    @Test func panelRendersInBothAppearances() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let switcher = RelayRecentPlacesSwitcher()
        switcher.showForTesting(places: RelayRecentPlaces.places(for: f.workspace), selection: 1)
        var rendered = 0
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            let panel = RelayRecentPlacesPanel(switcher: switcher).padding(20).environment(\.colorScheme, scheme)
            let shot = try RelaySnapshot.render(panel, name: "recent-places", width: 640, appearance: appearance)
            #expect(shot.size.height > RelayViewerMetrics.barHeight(compact: false) + 3 * 30)
            rendered += 1
        }
        #expect(rendered == 2)
    }
}

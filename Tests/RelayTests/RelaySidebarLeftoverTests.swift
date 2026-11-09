import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// Leftovers from the sidebar redundancy pass: new tabs named after their
/// directory, inbox rows titled by the tab, and one header row instead of a
/// nearly empty top bar above the tab rail.
@MainActor @Suite("Sidebar leftovers")
struct RelaySidebarLeftoverTests {
    /// The redundancy fixture, with a second pane split into the Math tab so
    /// one inbox row belongs to a multi-pane tab.
    static func makeFixture() throws -> RelaySidebarRedundancyTests.Fixture {
        let f = try RelaySidebarRedundancyTests.makeFixture()
        let tab = try #require(f.workspace.tabs.first { $0.allPaneIDs.contains(f.math.id) })
        f.workspace.selectTab(tab.id, origin: .user)
        f.workspace.activePaneID = f.math.id
        f.workspace.splitActive(axis: .horizontal)
        let proofs = try #require(f.workspace.activePane)
        #expect(proofs.id != f.math.id)
        proofs.customName = "proofs"
        if let aegisTab = f.workspace.tabs.first(where: { $0.allPaneIDs.contains(f.aegis.id) }) {
            f.workspace.selectTab(aegisTab.id, origin: .user)
        }
        return f
    }

    @Test("A new tab is named after its directory, else after its host and ordinal")
    func directoryTabNames() {
        typealias Naming = WorkspaceTabNaming
        let home = "/Users/kbd606"
        func name(_ directory: String?, ordinal: Int = 17) -> String {
            Naming.newTabName(directory: directory, profileName: "dandy-07", ordinal: ordinal, home: home)
        }
        #expect(name("/projects/caeg/people/kbd606/project/sapropel") == "sapropel")
        #expect(name("/projects/caeg/people/kbd606/project/sapropel/") == "sapropel")
        #expect(name("~/project/sapropel") == "sapropel")
        #expect(name("  /work/pan_barley  ") == "pan_barley")
        // No directory, "/", "~" or a home directory: host and ordinal as before.
        #expect(name(nil) == "dandy-07 17")
        #expect(name("") == "dandy-07 17")
        #expect(name("   ") == "dandy-07 17")
        #expect(name("/") == "dandy-07 17")
        #expect(name("//") == "dandy-07 17")
        #expect(name("~") == "dandy-07 17")
        #expect(name("~/") == "dandy-07 17")
        #expect(name(home) == "dandy-07 17")
        #expect(name(home + "/") == "dandy-07 17")
        #expect(name("/home/kbd606") == "dandy-07 17")
        #expect(name("/Users/someone") == "dandy-07 17")
        #expect(name("/root") == "dandy-07 17")
        #expect(name(nil, ordinal: 1) == "dandy-07")
        // A directory inside a home is still a project.
        #expect(name("/home/kbd606/sapropel") == "sapropel")
        #expect(name(home + "/dev/term") == "term")
        #expect(Naming.newTabName(directory: nil, profileName: "Local shell", ordinal: 22, home: home) == "Local shell 22")
    }

    @Test("New tabs in the same directory name stay distinct; existing tabs keep their names")
    func directoryTabNamesInWorkspace() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let first = try #require(workspace.selectedTab)
        first.name = "Analysis"
        let session = first.sessionID
        workspace.newTab(inSession: session, profile: .local, directory: "/work/alpha/sapropel")
        let a = try #require(workspace.selectedTab)
        workspace.newTab(inSession: session, profile: .local, directory: "/work/beta/sapropel")
        let b = try #require(workspace.selectedTab)
        workspace.newTab(inSession: session, profile: .local, directory: nil)
        let plain = try #require(workspace.selectedTab)
        #expect(a.name == "sapropel" && b.name == "sapropel")
        #expect(plain.name == "\(ConnectionProfile.local.name) 4")
        #expect(first.name == "Analysis")
        workspace.panes[a.allPaneIDs[0]]?.directory = "/work/alpha/sapropel"
        workspace.panes[b.allPaneIDs[0]]?.directory = "/work/beta/sapropel"
        let shown = [a, b].map { workspace.tabDisplayName($0, fallback: "Tab") }
        #expect(shown == ["sapropel 1", "sapropel 2"])
    }

    @Test("Navigator inbox and header row at 700 and 1200 pt, light and dark")
    func snapshots() throws {
        let f = try Self.makeFixture()
        defer { f.workspace.shutdown() }
        try RelayUIShot.window(WorkspaceNavigator(workspace: f.workspace, inbox: f.store),
                               "leftover-navigator-260", size: NSSize(width: 260, height: 560),
                               background: RelayTheme.sidebar)
        for width: CGFloat in [700, 1200] {
            try RelayUIShot.window(
                VStack(spacing: 0) {
                    WorkspaceNavigationHeader(workspace: f.workspace) { WorkspaceTabRail(workspace: f.workspace) }
                    Spacer(minLength: 0)
                },
                "leftover-header-\(Int(width))", size: NSSize(width: width, height: 80), background: RelayTheme.canvas)
        }
    }
}

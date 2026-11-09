import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

/// A tab that still has its generated name ("dandy-07 17") is named once
/// after the first real folder its first pane reports; nothing else renames.
@MainActor @Suite("Tab folder naming")
struct RelayTabFolderNamingTests {
    /// A workspace whose selected tab is a fresh automatic "Local shell 2".
    private func autoTab() throws -> (WorkspaceModel, TabModel, PaneModel) {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let first = try #require(workspace.selectedTab)
        workspace.newTab(inSession: first.sessionID, profile: .local)
        let tab = try #require(workspace.selectedTab)
        let pane = try #require(workspace.panes[tab.allPaneIDs[0]])
        return (workspace, tab, pane)
    }

    @Test("An automatic tab takes the first folder its first pane reports")
    func renamedOnFirstDirectory() throws {
        let (workspace, tab, pane) = try autoTab()
        defer { workspace.shutdown() }
        #expect(tab.name == "\(ConnectionProfile.local.name) 2" && tab.automaticName == tab.name)
        pane.directory = "/projects/caeg/people/kbd606/project/sapropel"
        #expect(tab.name == "sapropel" && tab.automaticName == nil)
        // Rename once: a later cd is not followed.
        pane.directory = "/projects/caeg/people/kbd606/project/pan_barley"
        #expect(tab.name == "sapropel")
    }

    @Test("Home and root are skipped; the next real folder is adopted")
    func homeIgnoredThenAdopted() throws {
        let (workspace, tab, pane) = try autoTab()
        defer { workspace.shutdown() }
        let generated = tab.name
        for directory in [NSHomeDirectory(), NSHomeDirectory() + "/", "/", "~", "/home/kbd606", "/Users/someone", "/root"] {
            pane.directory = directory
            #expect(tab.name == generated && tab.automaticName == generated)
        }
        pane.directory = "/work/pan_barley"
        #expect(tab.name == "pan_barley" && tab.automaticName == nil)
    }

    @Test("A tab named by the user or an agent is never renamed")
    func namedTabsKeepTheirNames() throws {
        let (workspace, tab, pane) = try autoTab()
        defer { workspace.shutdown() }
        // Renamed to the very same text: still the user's name.
        let generated = tab.name
        try workspace.renameTab(tab.id, to: generated)
        #expect(tab.automaticName == nil)
        pane.directory = "/work/sapropel"
        #expect(tab.name == generated)

        let (other, agentTab, agentPane) = try autoTab()
        defer { other.shutdown() }
        agentTab.name = "Agent run"
        agentPane.directory = "/work/sapropel"
        #expect(agentTab.name == "Agent run" && agentTab.automaticName == nil)
        // Even if it is later set back to the generated text.
        agentTab.name = "\(ConnectionProfile.local.name) 2"
        agentPane.directory = "/work/other"
        #expect(agentTab.name == "\(ConnectionProfile.local.name) 2")
    }

    @Test("Only the first pane's folder names the tab")
    func nonFirstPaneIgnored() throws {
        let (workspace, tab, pane) = try autoTab()
        defer { workspace.shutdown() }
        let generated = tab.name
        workspace.activePaneID = pane.id
        workspace.splitActive(axis: .horizontal)
        let second = try #require(workspace.activePane)
        #expect(second.id != pane.id && tab.allPaneIDs.first == pane.id)
        second.directory = "/work/second"
        #expect(tab.name == generated && tab.automaticName == generated)
        pane.directory = "/work/first"
        #expect(tab.name == "first")
    }

    @Test("A tab opened in a folder, or from an older save, is not automatic")
    func restoredAndDirectoryTabs() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let first = try #require(workspace.selectedTab)
        workspace.newTab(inSession: first.sessionID, profile: .local, directory: "/work/sapropel")
        let named = try #require(workspace.selectedTab)
        #expect(named.name == "sapropel" && named.automaticName == nil)

        // The flag survives a save; an older save has none, so its
        // "<host> N" tabs keep their names.
        var saved = TabSnapshot(id: UUID(), sessionID: nil, name: "dandy-07 17", layout: .pane(UUID()),
                                floatingPanes: nil, splitRatios: nil)
        saved.automaticName = "dandy-07 17"
        #expect(try JSONDecoder().decode(TabSnapshot.self, from: JSONEncoder().encode(saved)).automaticName == "dandy-07 17")
        let legacy: [String: Any] = ["id": UUID().uuidString, "name": "dandy-07 17",
                                     "layout": try JSONSerialization.jsonObject(with: JSONEncoder().encode(PaneLayout.pane(UUID())))]
        let old = try JSONDecoder().decode(TabSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.automaticName == nil)

        // A tab like a restored legacy one (no flag) stays as it is.
        named.name = "dandy-07 17"
        let pane = try #require(workspace.panes[named.allPaneIDs[0]])
        pane.directory = "/work/elsewhere"
        #expect(named.name == "dandy-07 17")
    }

    @Test("Navigator and tab rail before and after folder naming, light and dark")
    func snapshots() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let pan = workspace.createWorkspace(named: "Pan-barley")
        let dandy = ConnectionProfile.sshConfigHost("dandy-07")
        var panes: [(PaneModel, String)] = []
        for (profile, generated, folder) in [(dandy, "dandy-07 17", "/projects/caeg/people/kbd606/project/sapropel"),
                                             (ConnectionProfile.local, "Local shell 22", "/Users/kbd606/dev/term"),
                                             (dandy, "dandy-07 18", "/home/kbd606")] {
            workspace.newTab(profile: profile)
            let pane = try #require(workspace.activePane)
            let tab = try #require(workspace.tabs.first { $0.allPaneIDs.contains(pane.id) })
            // Stand in for long-running ordinals; still Relay's generated name.
            tab.name = generated
            tab.automaticName = generated
            pane.connectionState = .connected
            try workspace.performDrop(.tabOnWorkspace(tabID: tab.id, workspaceID: pan, index: nil))
            panes.append((pane, folder))
        }
        workspace.selectWorkspace(pan, origin: .user)
        func render(_ phase: String) throws {
            try RelayUIShot.window(WorkspaceNavigator(workspace: workspace, inbox: store),
                                   "osc7-navigator-\(phase)", size: NSSize(width: 260, height: 420),
                                   background: RelayTheme.sidebar)
            try RelayUIShot.window(WorkspaceNavigationHeader(workspace: workspace) { WorkspaceTabRail(workspace: workspace) },
                                   "osc7-tab-rail-\(phase)", size: NSSize(width: 900, height: 36),
                                   background: RelayTheme.canvas)
        }
        try render("before")
        for (pane, folder) in panes { pane.directory = folder }
        let names = workspace.tabs(inWorkspace: pan).map(\.name)
        #expect(names == ["sapropel", "term", "dandy-07 18"])
        try render("after")
    }
}

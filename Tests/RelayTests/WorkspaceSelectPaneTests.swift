import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Selecting a pane for an agent or a banner")
struct WorkspaceSelectPaneTests {
    @Test func aFloatingRPanelIsSelectedInItsOwnTab() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.newTab(profile: .sshConfigHost("select-r-test.invalid"))
        let console = workspace.activePane!
        let owner = try #require(workspace.selectedTabID)
        let editor = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .editor)
        workspace.newTab(profile: .sshConfigHost("select-r-test.invalid"))
        #expect(workspace.selectedTabID != owner)

        let (tabID, paneID) = try workspace.selectWorkspacePane(editor.id)
        #expect(tabID == owner && paneID == editor.id)
        #expect(workspace.selectedTabID == owner)
        #expect(workspace.activePaneID == editor.id)
    }

    @Test func anUnknownPaneIsStillRefused() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.newTab(profile: .sshConfigHost("select-r-test.invalid"))
        let before = (workspace.selectedTabID, workspace.activePaneID)
        #expect(throws: PluginError.self) { try workspace.selectWorkspacePane(UUID()) }
        #expect(workspace.selectedTabID == before.0 && workspace.activePaneID == before.1)
    }

    @Test func aPaneInAnotherTabIsSelectedAsBefore() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        workspace.newTab(profile: .sshConfigHost("select-r-test.invalid"))
        let first = workspace.activePane!
        let owner = try #require(workspace.selectedTabID)
        workspace.splitActive(axis: .horizontal)
        workspace.newTab(profile: .sshConfigHost("select-r-test.invalid"))

        let (tabID, paneID) = try workspace.selectWorkspacePane(first.id)
        #expect(tabID == owner && paneID == first.id)
        #expect(workspace.selectedTabID == owner)
        #expect(workspace.activePaneID == first.id)
    }
}

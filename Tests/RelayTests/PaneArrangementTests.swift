import Foundation
import Testing
@testable import Relay

@MainActor
@Test func paneArrangementMinimizePreservesSession() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newFloatingPane()
    let pane = workspace.activePane!
    let placement = workspace.selectedTab!.floatingPanes[0]
    workspace.minimizeFloatingPane(pane.id)
    #expect(workspace.panes[pane.id] === pane)
    #expect(workspace.selectedTab!.floatingPanes[0].isMinimized)
    #expect(workspace.activePaneID != pane.id)
    workspace.selectPane(pane.id, origin: .user)
    #expect(!workspace.selectedTab!.floatingPanes[0].isMinimized)
    #expect(workspace.selectedTab!.floatingPanes[0].width == placement.width)
}

@MainActor
@Test func paneArrangementTileAndRestore() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newFloatingPane()
    workspace.newFloatingPane()
    let tab = workspace.selectedTab!
    tab.canvasSize = CGSize(width: 1200, height: 800)
    let before = tab.floatingPanes
    workspace.arrangeFloatingPanes(cascade: false)
    let first = tab.floatingPanes[0], second = tab.floatingPanes[1]
    #expect(first.originX + first.width <= second.originX)
    #expect(second.originX + second.width <= 1200)
    workspace.arrangeFloatingPanes(cascade: true)
    workspace.restorePaneArrangement()
    #expect(tab.floatingPanes == before)
    #expect(tab.savedArrangement == nil)
}

@MainActor
@Test func paneArrangementRefusesUnsafeRestore() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newFloatingPane()
    let tab = workspace.selectedTab!
    tab.canvasSize = CGSize(width: 1200, height: 800)
    workspace.arrangeFloatingPanes(cascade: true)
    workspace.newFloatingPane()
    let ids = tab.allPaneIDs
    workspace.restorePaneArrangement()
    #expect(tab.allPaneIDs == ids)
    #expect(workspace.operationError != nil)
}

@Test func paneArrangementLegacyDecode() throws {
    let id = UUID()
    let json = "{\"paneID\":\"\(id)\",\"originX\":1,\"originY\":2,\"width\":620,\"height\":410}"
    let placement = try JSONDecoder().decode(FloatingPanePlacement.self, from: Data(json.utf8))
    #expect(!placement.isMinimized)
}

@MainActor
@Test func paneArrangementRSurvivesSnapshotRoundTrip() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("r-restore-test"))
    let console = workspace.activePaneID!
    try workspace.activateRWorkspace(consoleID: console)
    workspace.arrangeRWorkspace()
    let tab = workspace.selectedTab!
    let editorID = tab.rLayoutEditorID!
    let editor = workspace.panes[editorID]!.editorRuntime
    let navigatorWasVisible = editor.navigatorVisible
    let saved = TabSnapshot(id: tab.id, sessionID: tab.sessionID, name: tab.name,
        layout: tab.layout, floatingPanes: tab.floatingPanes, splitRatios: tab.splitRatios,
        rLayoutEditorID: editorID, rResultsVisible: true)
    let restored = try JSONDecoder().decode(TabSnapshot.self, from: JSONEncoder().encode(saved))
    tab.rLayoutEditorID = nil; editor.externalRResults = false; editor.showsRResults = false
    tab.chrome.hide()
    workspace.restoreRLayout(restored, in: tab)
    #expect(tab.chrome.visible && tab.chrome.destination == .rWorkspace)
    #expect(tab.chrome.anchor?.paneID == console)
    #expect(tab.rLayoutEditorID == editorID)
    #expect(editor.externalRResults && editor.showsRResults)
    #expect(editor.navigatorVisible == navigatorWasVisible)
    #expect(editor.rSession == nil) // Never restore a saved handshake as a live process.
    var hidden = restored
    hidden.rResultsVisible = false
    workspace.restoreRLayout(hidden, in: tab)
    #expect(!editor.showsRResults)
    #expect(!tab.chrome.visible)
    var invalid = restored
    invalid.rLayoutEditorID = console
    tab.rLayoutEditorID = nil
    workspace.restoreRLayout(invalid, in: tab)
    #expect(tab.rLayoutEditorID == nil)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
    json.removeValue(forKey: "rLayoutEditorID"); json.removeValue(forKey: "rResultsVisible")
    let legacy = try JSONDecoder().decode(TabSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.rLayoutEditorID == nil)
}

@MainActor
@Test func rWorkspaceIsAdditiveToExistingPaneLayout() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("r-layout-test"))
    let console = workspace.activePaneID!
    try workspace.activateRWorkspace(consoleID: console)
    let editor = workspace.activePaneID!
    workspace.newFloatingPane()
    let other = workspace.activePaneID!
    workspace.selectPane(editor, origin: .user)
    let tab = workspace.selectedTab!
    let before = tab.layout
    let beforeFloating = tab.floatingPanes
    #expect(workspace.arrangeRWorkspace())
    #expect(tab.layout == before)
    #expect(tab.floatingPanes == beforeFloating)
    #expect(tab.floatingPanes.first { $0.paneID == other }?.isMinimized == false)
    #expect(workspace.panes[editor]!.editorRuntime.showsRResults)
    #expect(workspace.panes[editor]!.editorRuntime.externalRResults)
    #expect(tab.rLayoutEditorID == editor)
    #expect(tab.chrome.rightSurface(rLayoutEditorID: editor) == .contextDock(.rWorkspace))
    #expect(tab.savedArrangement == nil)
    tab.chrome.hide()
    #expect(tab.chrome.rightSurface(rLayoutEditorID: editor) == nil)
    #expect(tab.layout == before)
}

@MainActor
@Test func rWorkspaceAddsEditorOnlyBesideSelectedConsole() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("r-layout-test"))
    let console = workspace.activePaneID!
    workspace.splitActive(axis: .horizontal)
    let sibling = workspace.activePaneID!
    let tab = workspace.selectedTab!
    let before = tab.layout
    #expect(workspace.arrangeRWorkspace(consoleID: console))
    let editor = try #require(tab.rLayoutEditorID)
    #expect(tab.layout.paneIDs == [editor, console, sibling])
    #expect(tab.layout != before)
    #expect(tab.floatingPanes.isEmpty)
    #expect(workspace.panes[sibling] != nil)
    let arranged = tab.layout
    #expect(workspace.arrangeRWorkspace(consoleID: console))
    #expect(tab.layout == arranged)
}

@MainActor
@Test func rWorkspaceKeepsFloatingEditorAndZoom() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("r-layout-test"))
    let console = workspace.activePaneID!
    try workspace.activateRWorkspace(consoleID: console)
    let editor = workspace.activePaneID!
    workspace.toggleActivePaneFloating()
    let tab = workspace.selectedTab!
    let beforeLayout = tab.layout
    let beforeFloating = tab.floatingPanes
    workspace.togglePaneZoom(console)
    #expect(workspace.arrangeRWorkspace(consoleID: console))
    #expect(tab.layout == beforeLayout)
    #expect(tab.floatingPanes == beforeFloating)
    #expect(workspace.zoomedPaneID == console)
    #expect(tab.rLayoutEditorID == editor)
}

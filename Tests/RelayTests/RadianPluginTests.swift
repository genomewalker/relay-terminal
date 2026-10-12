import Foundation
import Testing
@testable import Relay

@Test("Radian development package declares only its implemented read capabilities")
func radianManifestCapabilities() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("docs/plugins/radian/relay-plugin.json"))
    let package = try RelayPluginPackage.decode(data, repository: "genomewalker/relay-plugin-radian")
    #expect(package.id == "relay.radian")
    #expect(package.supportsActivation)
    #expect(package.permissions.map(\.kind) == [.projectRead])
    #expect(package.contributions.compactMap(\.operation) == [.rWorkspace, .artifacts])
}

@MainActor
@Test("R layout preserves panes and activation is idempotent")
func rLayoutPreservesPanes() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("r-layout-test"))
    let console = workspace.activePaneID!
    workspace.splitActive(axis: .horizontal)
    let sibling = workspace.activePaneID!
    try workspace.activateRWorkspace(consoleID: console)
    let editor = workspace.activePaneID!
    #expect(workspace.selectedTab?.layout.paneIDs == [editor, console, sibling])
    #expect(workspace.panes[editor]?.remoteParentSessionID == console.uuidString.lowercased())
    try workspace.activateRWorkspace(consoleID: console)
    #expect(workspace.selectedTab?.layout.paneIDs == [editor, console, sibling])
    workspace.newTab(profile: .sshConfigHost("other-tab-test"))
    #expect(throws: (any Error).self) { try workspace.activateRWorkspace(consoleID: console) }
}

@MainActor
@Test("Local R layout captures the console project without starting R")
func localRLayout() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .local)
    let console = workspace.activePaneID!
    workspace.panes[console]?.directory = "/tmp/relay-local-r"
    try workspace.activateRWorkspace(consoleID: console)
    let editor = workspace.activePaneID!
    #expect(workspace.panes[editor]?.directory == "/tmp/relay-local-r")
    #expect(workspace.panes[editor]?.profile.kind == .local)
    #expect(workspace.selectedTab?.layout.paneIDs == [editor, console])
    try workspace.activateRWorkspace(consoleID: console)
    #expect(workspace.selectedTab?.layout.paneIDs == [editor, console])
}

@MainActor
@Test("Floating R workspace preserves a multi-panel tab and reuses its console")
func floatingRWorkspacePreservesTab() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("floating-r-test"))
    let console = workspace.activePane!
    workspace.splitActive(axis: .horizontal)
    workspace.splitActive(axis: .vertical)
    workspace.newFloatingPane()
    let tab = workspace.selectedTab!
    let layout = tab.layout
    let ids = tab.allPaneIDs
    let floating = tab.floatingPanes
    let ratios = tab.splitRatios
    let active = workspace.activePaneID
    let zoom = workspace.zoomedPaneID
    let editor = try workspace.prepareFloatingRWorkspace(consoleID: console.id)
    #expect(tab.layout == layout)
    #expect(tab.allPaneIDs == ids)
    #expect(tab.floatingPanes == floating)
    #expect(tab.splitRatios == ratios)
    #expect(workspace.activePaneID == active)
    #expect(workspace.zoomedPaneID == zoom)
    #expect(workspace.panes[console.id] === console)
    #expect(editor.remoteParentSessionID == console.id.uuidString.lowercased())
    #expect(try workspace.prepareFloatingRWorkspace(consoleID: console.id) === editor)
    workspace.closeTab(tab.id)
    #expect(workspace.panes[editor.id] == nil)
}

@MainActor
@Test("Multiple floating R workspaces and extra panels preserve the tab")
func multipleFloatingRWorkspaces() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("multi-r-test"))
    let original = workspace.activePane!
    workspace.splitActive(axis: .horizontal)
    let tab = workspace.selectedTab!
    let layout = tab.layout
    let ids = tab.allPaneIDs
    let active = workspace.activePaneID
    let firstEditor = try workspace.prepareFloatingRWorkspace(consoleID: original.id)
    let secondConsole = try workspace.addFloatingRPanel(consoleID: original.id, contentKind: .terminal)
    let secondEditor = try workspace.prepareFloatingRWorkspace(consoleID: secondConsole.id)
    let extraEditor = try workspace.addFloatingRPanel(consoleID: original.id, contentKind: .editor)
    #expect(firstEditor.id != secondEditor.id)
    #expect(secondEditor.remoteParentSessionID == secondConsole.id.uuidString.lowercased())
    #expect(extraEditor.remoteParentSessionID == original.id.uuidString.lowercased())
    #expect(try workspace.prepareFloatingRWorkspace(consoleID: original.id) === firstEditor)
    #expect(try workspace.prepareFloatingRWorkspace(consoleID: secondConsole.id) === secondEditor)
    #expect(tab.layout == layout)
    #expect(tab.allPaneIDs == ids)
    #expect(workspace.activePaneID == active)
    workspace.closeTab(tab.id)
    #expect(workspace.panes[secondConsole.id] == nil)
    #expect(workspace.panes[secondEditor.id] == nil)
    #expect(workspace.panes[extraEditor.id] == nil)
}

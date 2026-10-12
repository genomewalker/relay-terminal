import Testing
@testable import Relay

@MainActor
@Test("Splitting a zoomed pane reveals both children")
func splittingZoomedPaneRevealsChildren() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let source = workspace.activePaneID!
    workspace.toggleActivePaneZoom()
    workspace.splitActive(axis: .vertical)
    #expect(workspace.zoomedPaneID == nil)
    #expect(workspace.selectedTab?.layout.paneIDs == [source, workspace.activePaneID!])
}

@MainActor
@Test("Splitting a floating remote pane docks it and preserves remote parent")
func splittingFloatingPaneCreatesVisibleRemoteChild() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("split-test-host"))
    let original = workspace.activePaneID!
    workspace.newFloatingPane()
    let source = workspace.activePaneID!
    workspace.toggleActivePaneZoom()
    workspace.splitActive(axis: .horizontal)
    let child = workspace.activePaneID!
    #expect(workspace.zoomedPaneID == nil)
    #expect(workspace.selectedTab?.floatingPanes.isEmpty == true)
    #expect(workspace.selectedTab?.layout.paneIDs == [original, source, child])
    #expect(workspace.activePane?.remoteParentSessionID == source.uuidString.lowercased())
}

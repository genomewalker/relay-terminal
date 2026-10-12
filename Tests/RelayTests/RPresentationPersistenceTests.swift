import Foundation
import Testing
@testable import Relay

@Test func rPresentationRoundTripPreservesGeometryAndBorrowedPaneIdentity() throws {
    let borrowed = UUID()
    let child = RExtraPresentation(id: UUID(), title: "Claude", paneID: borrowed,
        returnsToTab: true, floating: true, minimized: true,
        placement: RPanelPlacement(x: 73, y: 51, width: 620, height: 420))
    let root = RWorkspacePresentation(consoleID: UUID(), editorID: UUID(), tabID: UUID(),
        selected: true, minimized: false, placement: RPanelPlacement(width: 1120, height: 740, maximized: true), extras: [child])
    let snapshot = WorkspaceSnapshot(tabs: [], panes: [], sessionNames: nil, selectedTabID: nil,
        activePaneID: nil, rPresentations: [root], sidebarVisible: true)
    let restored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(restored.rPresentations == [root])
    #expect(restored.rPresentations?.first?.paneIDs.contains(borrowed) == true)
    #expect(restored.sidebarVisible == true)
}

@Test @MainActor func restoredRPresentationReusesOriginalEditor() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let console = try #require(workspace.activePaneID)
    workspace.panes[console]?.directory = "/tmp"
    let editor = try workspace.prepareFloatingRWorkspace(consoleID: console)
    let tab = try #require(workspace.selectedTabID)
    let item = RWorkspacePresentation(consoleID: console, editorID: editor.id, tabID: tab,
        selected: true, minimized: false, placement: nil, extras: [])
    workspace.restoreRPresentationOwnership([item])
    let restored = try workspace.prepareFloatingRWorkspace(consoleID: console)
    #expect(restored === editor)
    #expect(workspace.savedRPresentations == [item])
}

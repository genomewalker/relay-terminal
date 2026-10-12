import Testing
import Foundation
@testable import Relay

@Test @MainActor func rSessionStatusDoesNotAuthorizeOrWriteState() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let console = try #require(workspace.activePaneID)
    let before = UserDefaults.standard.data(forKey: "relay.r-linked-execution.v1")
    let control = RAutomationController()
    let status = try control.sessionStatus(paneID: console, workspace: workspace)
    #expect(status["status"] as? String == "not_authorized")
    #expect(status["paused"] as? Bool == true)
    #expect(status["liveness_verified"] as? Bool == false)
    #expect(status["active_request_id"] is NSNull)
    #expect(UserDefaults.standard.data(forKey: "relay.r-linked-execution.v1") == before)
}

@Test @MainActor func embeddedREditorAppearsOnceInMCPDiscovery() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let console = try #require(workspace.activePaneID)
    workspace.panes[console]?.directory = "/tmp"
    let editor = try workspace.prepareFloatingRWorkspace(consoleID: console)
    let listed = workspace.sidePanelState().sessions.flatMap(\.tabs).flatMap(\.panes)
    #expect(listed.filter { $0.id == editor.id.uuidString.lowercased() }.count == 1)
    #expect(listed.filter { $0.id == console.uuidString.lowercased() }.count == 1)
}

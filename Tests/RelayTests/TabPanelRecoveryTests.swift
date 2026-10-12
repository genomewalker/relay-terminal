import Foundation
import Testing
@testable import Relay

private func retainedPanel(_ id: UUID, session: UUID, tab: UUID) -> RemoteCatalogPane {
    RemoteCatalogPane(paneID: id.uuidString.lowercased(), workspaceID: session.uuidString.lowercased(),
                      tabID: tab.uuidString.lowercased(), parentPaneID: nil, title: "Retained",
                      contentKind: "terminal", command: "codex", directory: "/work",
                      state: "running", workerPID: 42, shellPID: 43, lastSequence: 8,
                      recoverable: true, unfiled: false)
}

@Test("Tab recovery restores every missing retained pane without replacing attached runtimes")
@MainActor
func tabPanelRecoveryPreservesAttachedPanes() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let profile = ConnectionProfile.sshConfigHost("hpc-login")
    workspace.newTab(profile: profile)
    let tab = try #require(workspace.selectedTab)
    let existingID = try #require(workspace.activePaneID)
    let existing = try #require(workspace.panes[existingID])
    let first = UUID(), second = UUID(), elsewhere = UUID()
    let remote = RemoteSessionRecord(id: "workspace:\(tab.sessionID)", workspaceID: tab.sessionID.uuidString,
                                    panes: [retainedPanel(existingID, session: tab.sessionID, tab: tab.id),
                                            retainedPanel(first, session: tab.sessionID, tab: tab.id),
                                            retainedPanel(second, session: tab.sessionID, tab: tab.id),
                                            retainedPanel(elsewhere, session: tab.sessionID, tab: UUID())], workspaceSnapshot: nil)
    let restored = workspace.recoverRemoteTab(profile: profile, remote: remote, tabID: tab.id)
    #expect(Set(restored) == Set([first, second]))
    #expect(workspace.panes[existingID] === existing)
    #expect(workspace.panes[first]?.requiresExistingWorker == true)
    #expect(workspace.panes[second]?.requiresExistingWorker == true)
    #expect(Set(tab.allPaneIDs) == Set([existingID, first, second]))
    #expect(workspace.panes[elsewhere] == nil)
    tab.floatingPanes[0].minimized = true
    workspace.zoomedPaneID = existingID
    #expect(workspace.recoverRemoteTab(profile: profile, remote: remote, tabID: tab.id).isEmpty)
    #expect(tab.floatingPanes.count == 2 && tab.floatingPanes.allSatisfy { !$0.isMinimized })
    #expect(workspace.zoomedPaneID == nil)
    #expect(workspace.activePaneID == existingID)
}

@Test("Tab recovery rejects different host or session identities before changing panes")
@MainActor
func tabPanelRecoveryRejectsForeignIdentity() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let profile = ConnectionProfile.sshConfigHost("hpc-login")
    workspace.newTab(profile: profile)
    let tab = try #require(workspace.selectedTab)
    let existingID = try #require(workspace.activePaneID)
    let missing = UUID()
    let remote = RemoteSessionRecord(id: "workspace:\(tab.sessionID)", workspaceID: tab.sessionID.uuidString,
                                    panes: [retainedPanel(existingID, session: tab.sessionID, tab: tab.id),
                                            retainedPanel(missing, session: tab.sessionID, tab: tab.id)], workspaceSnapshot: nil)
    #expect(workspace.recoverRemoteTab(profile: .sshConfigHost("other-host"), remote: remote, tabID: tab.id).isEmpty)
    #expect(workspace.panes[missing] == nil && tab.allPaneIDs == [existingID])
    let foreign = UUID()
    let otherSession = RemoteSessionRecord(id: "workspace:\(foreign)", workspaceID: foreign.uuidString,
                                         panes: [retainedPanel(missing, session: foreign, tab: tab.id)], workspaceSnapshot: nil)
    #expect(workspace.recoverRemoteTab(profile: profile, remote: otherSession, tabID: tab.id).isEmpty)
    #expect(workspace.panes[missing] == nil && tab.allPaneIDs == [existingID])
}

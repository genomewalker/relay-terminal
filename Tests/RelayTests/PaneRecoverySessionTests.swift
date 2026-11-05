import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Recovered panes keep their tab's session; silent removals are logged")
struct PaneRecoverySessionTests {
    private func catalogPane(_ id: UUID, tabID: UUID?, workspaceID: UUID?) -> RemoteCatalogPane {
        RemoteCatalogPane(paneID: id.uuidString.lowercased(), workspaceID: workspaceID?.uuidString.lowercased(),
                          tabID: tabID?.uuidString.lowercased(), parentPaneID: nil, title: "Codex",
                          contentKind: "terminal", command: nil, directory: "/work", state: "running",
                          workerPID: 42, shellPID: 43, lastSequence: 0, recoverable: true, unfiled: false)
    }

    private func silentRemovals(of paneID: UUID) -> [RelayDiagnosticEvent] {
        RelayDiagnostics.shared.snapshot().events.filter {
            $0.name == "pane-removed-silently" && $0.details["pane_id"] == paneID.uuidString.lowercased()
        }
    }

    /// Two tabs in different sessions; the second is selected.
    private func twoSessions() throws -> (WorkspaceModel, target: TabModel, selected: TabModel) {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.newTab(profile: .sshConfigHost("recover-session.invalid"))
        let target = try #require(workspace.selectedTab)
        workspace.newTab(profile: .sshConfigHost("recover-session.invalid"))
        let selected = try #require(workspace.selectedTab)
        #expect(target.sessionID != selected.sessionID)
        return (workspace, target, selected)
    }

    @Test func aPaneRecoveredIntoAnOpenTabTakesThatTabsSession() throws {
        let (workspace, target, selected) = try twoSessions()
        defer { workspace.shutdown() }
        let paneID = UUID()
        // The MCP route passes the selected tab's session.
        #expect(workspace.attachRemotePane(profile: .sshConfigHost("recover-session.invalid"),
            remotePane: catalogPane(paneID, tabID: target.id, workspaceID: selected.sessionID),
            workspaceID: selected.sessionID.uuidString.lowercased(), sessionLabel: "dandy-07",
            intoSessionID: selected.sessionID))
        let pane = try #require(workspace.panes[paneID])
        #expect(target.floatingPanes.contains { $0.paneID == paneID })
        #expect(pane.remoteWorkspaceSessionID == target.sessionID.uuidString.lowercased())
        #expect(pane.remoteTabID == target.id.uuidString.lowercased())
    }

    @Test func aPaneRecoveredWithoutAnOpenTabKeepsTheRequestedSession() throws {
        let (workspace, _, selected) = try twoSessions()
        defer { workspace.shutdown() }
        let paneID = UUID(), tabID = UUID()
        #expect(workspace.attachRemotePane(profile: .sshConfigHost("recover-session.invalid"),
            remotePane: catalogPane(paneID, tabID: tabID, workspaceID: nil),
            workspaceID: nil, sessionLabel: "dandy-07", intoSessionID: selected.sessionID))
        let tab = try #require(workspace.tabs.first { $0.id == tabID })
        #expect(tab.sessionID == selected.sessionID)
        #expect(workspace.panes[paneID]?.remoteWorkspaceSessionID == selected.sessionID.uuidString.lowercased())
    }

    @Test func aPaneThatSilentlyLeavesEveryTabIsLoggedWithItsPath() throws {
        let (workspace, target, _) = try twoSessions()
        let paneID = UUID()
        workspace.attachRemotePane(profile: .sshConfigHost("recover-session.invalid"),
            remotePane: catalogPane(paneID, tabID: target.id, workspaceID: target.sessionID),
            workspaceID: target.sessionID.uuidString.lowercased(), sessionLabel: "dandy-07")
        target.floatingPanes.removeAll { $0.paneID == paneID }
        workspace.shutdown()

        let event = try #require(silentRemovals(of: paneID).last)
        #expect(event.category == "pane")
        #expect(event.details["tab_id"] == target.id.uuidString.lowercased())
        #expect(event.details["tab_session"] == target.sessionID.uuidString.lowercased())
        #expect(event.details["birth_session"] == target.sessionID.uuidString.lowercased())
        #expect(event.details["left_via"] == "floatingPanes")
        #expect(event.details["pane_loaded"] == "true")
        #expect(event.details["tab_open"] == "true")
        // The code path names this test, the caller that removed the pane.
        let removedBy = try #require(event.details["removed_by"])
        #expect(removedBy.hasPrefix("$s5Relay8TabModelC13floatingPanes"))
        #expect(removedBy.contains("ThatSilentlyLeavesEveryTabIsLogged"))
        #expect(removedBy.components(separatedBy: " < ").allSatisfy { $0.contains(" @0x") })
    }

    @Test func aPaneSilentlyDetachedFromTheLayoutIsLogged() throws {
        let (workspace, target, _) = try twoSessions()
        let paneID = UUID()
        workspace.attachRemotePane(profile: .sshConfigHost("recover-session.invalid"),
            remotePane: catalogPane(paneID, tabID: target.id, workspaceID: target.sessionID),
            workspaceID: target.sessionID.uuidString.lowercased(), sessionLabel: "dandy-07")
        workspace.selectTab(target.id)
        workspace.dockFloatingPane(paneID)
        #expect(target.detachTiledPane(paneID))
        workspace.shutdown()
        let event = try #require(silentRemovals(of: paneID).last)
        #expect(event.details["left_via"] == "layout")
    }

    @Test func aSilentlyDroppedTabLogsItsPanes() throws {
        let (workspace, target, _) = try twoSessions()
        let paneID = try #require(target.allPaneIDs.first)
        workspace.tabs.removeAll { $0.id == target.id }
        workspace.shutdown()
        let event = try #require(silentRemovals(of: paneID).last)
        #expect(event.details["left_via"] == "tabs")
        #expect(event.details["tab_open"] == "false")
    }

    @Test func closesAndMovesAreNotLogged() throws {
        let (workspace, target, _) = try twoSessions()
        let closed = UUID(), moved = UUID(), docked = UUID()
        for paneID in [closed, moved, docked] {
            workspace.attachRemotePane(profile: .sshConfigHost("recover-session.invalid"),
                remotePane: catalogPane(paneID, tabID: target.id, workspaceID: target.sessionID),
                workspaceID: target.sessionID.uuidString.lowercased(), sessionLabel: "dandy-07")
        }
        workspace.selectTab(target.id)
        workspace.selectPane(closed)
        workspace.closeActivePane()
        _ = try workspace.movePaneToNewTab(moved)
        // Docking leaves floatingPanes before the layout takes the pane.
        workspace.selectTab(target.id)
        workspace.dockFloatingPane(docked)
        #expect(target.layout.paneIDs.contains(docked))
        workspace.shutdown()
        #expect(workspace.panes[closed] == nil)
        #expect(silentRemovals(of: closed).isEmpty)
        #expect(silentRemovals(of: moved).isEmpty)
        #expect(silentRemovals(of: docked).isEmpty)
    }

    @Test func theRemovalPathKeepsRelayFramesWithoutTheObserver() {
        let symbols = [
            "0   Relay   0x0000000100001000 $s5Relay14WorkspaceModelC13noteDeparture_4from3viayys + 40",
            "1   Relay   0x0000000100002000 $s5Relay8TabModelC13notePanesLeft_3viayys + 12",
            "2   Relay   0x0000000100003000 $s5Relay14WorkspaceModelC14settleMigrationyys + 300",
            "3   libswiftCore.dylib   0x0000000190000000 swift_task_switch + 20",
            "4   Relay   0x0000000100004000 $s5Relay14WorkspaceModelC22applyWorkspaceMigrationyys + 88",
        ]
        #expect(WorkspaceModel.removalPath(symbols)
            == "$s5Relay14WorkspaceModelC14settleMigrationyys + 300 < $s5Relay14WorkspaceModelC22applyWorkspaceMigrationyys + 88")
        #expect(WorkspaceModel.removalPath(symbols, imageOffsets: [0x1028, 0x200c, 0x312c, 0x14, 0x4058])
            == "$s5Relay14WorkspaceModelC14settleMigrationyys + 300 @0x312c < $s5Relay14WorkspaceModelC22applyWorkspaceMigrationyys + 88 @0x4058")
    }

    /// A release build may not name its frames; the offsets still locate them.
    @Test func unnamedFramesKeepTheirOffsetsAndReachTheCaller() {
        let symbols = (0..<20).map { "\($0)   Relay   0x00000001000\($0 + 10)000 0x100000000 + \($0 * 16)" }
        let path = WorkspaceModel.removalPath(symbols, imageOffsets: (0..<20).map { UInt($0 * 16) })
        let frames = path.components(separatedBy: " < ")
        #expect(frames.count == 16)
        #expect(frames.last == "0x100000000 + 240 @0xf0")
    }

    @Test func aLiveRemovalRecordsBinaryOffsets() throws {
        #expect(WorkspaceModel.imageOffsets(Thread.callStackReturnAddresses).contains { $0 > 0 })
        #expect(WorkspaceModel.imageOffsets([NSNumber(value: UInt(1))]) == [0])
    }
}

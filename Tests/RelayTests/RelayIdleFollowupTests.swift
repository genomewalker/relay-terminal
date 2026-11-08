import AppKit
import Foundation
import Testing
@testable import Relay

private func temporaryJournalURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json")
}

@MainActor @Test("A pane-health sync bumps revision only when published state changed")
func paneHealthSyncRevisionOnlyOnChange() async throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePane)
    pane.connected()
    let coordinator = RelayPaneHealthCoordinator(url: temporaryJournalURL())
    let start = coordinator.revision

    await coordinator.bumpingRevisionIfPublishedStateChanges {}
    #expect(coordinator.revision == start)

    // heartbeat itself does not publish; it adds a host entry the snapshot shows.
    await coordinator.bumpingRevisionIfPublishedStateChanges { coordinator.heartbeat(workspace) }
    #expect(coordinator.revision == start &+ 1)
    #expect(coordinator.snapshot().hosts.count == 1)

    // A repeat heartbeat only refreshes internal bookkeeping.
    await coordinator.bumpingRevisionIfPublishedStateChanges { coordinator.heartbeat(workspace) }
    #expect(coordinator.revision == start &+ 1)
    workspace.shutdown()
}

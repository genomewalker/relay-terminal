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

private func journalHost(_ url: URL, _ key: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return try #require((object?["hosts"] as? [String: Any])?[key] as? [String: Any])
}

/// The explicit-check operation ID must be durable before the check is
/// dispatched, also when the loaded journal was otherwise unchanged.
@MainActor @Test("Pre-dispatch check fence is written even after an unchanged load")
func paneHealthPreDispatchSaveIsWritten() async throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePane)
    pane.connected()
    let key = pane.profile.connectionKey
    let url = temporaryJournalURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try Data(#"{"hosts":{},"tools":{}}"#.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let coordinator = RelayPaneHealthCoordinator(url: url)
    let oldHealth = RelayPreferences.shared.haikuPaneHealth
    RelayPreferences.shared.haikuPaneHealth = true
    defer { RelayPreferences.shared.haikuPaneHealth = oldHealth; workspace.shutdown() }
    try #require(!RelayPreferences.shared.shepherd.enabled)

    await coordinator.checkNow(workspace, profile: pane.profile)
    let host = try journalHost(url, key)
    let operation = try #require(host["daemonCheckOperationID"] as? String)
    #expect(!operation.isEmpty)
    #expect(host["daemonCheckSubmitted"] as? Bool == false)
}

@MainActor @Test("An unchanged pane-health journal is not rewritten, and a missing file is restored")
func paneHealthUnchangedJournalSkipsWrite() throws {
    _ = NSApplication.shared
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try #require(workspace.activePane)
    pane.connected()
    defer { workspace.shutdown() }
    let key = pane.profile.connectionKey
    let url = temporaryJournalURL()
    let coordinator = RelayPaneHealthCoordinator(url: url)
    coordinator.heartbeat(workspace)

    coordinator.accountConfigurationChanged(profile: pane.profile)
    #expect(try journalHost(url, key)["state"] as? String == "Account settings changed; waiting for a fresh check")
    let past = Date(timeIntervalSince1970: 1_000_000_000)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
    let bytes = try Data(contentsOf: url)
    let revision = coordinator.revision

    // Same journal: no encode, no write, no extra save revision.
    coordinator.accountConfigurationChanged(profile: pane.profile)
    let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    #expect(modified == past)
    #expect(try Data(contentsOf: url) == bytes)
    #expect(coordinator.revision == revision &+ 1) // the method's own bump only

    // A deleted file is written again even though the journal is unchanged.
    try FileManager.default.removeItem(at: url)
    coordinator.accountConfigurationChanged(profile: pane.profile)
    #expect(try Data(contentsOf: url) == bytes)
}

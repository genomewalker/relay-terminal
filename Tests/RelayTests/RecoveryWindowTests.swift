import AppKit
import Foundation
import Testing
@testable import Relay

@Test func recoverySnapshotAcceptsOldCatalog() throws {
    let data = Data(#"{"tabs":[],"panes":[],"selectedTabID":null,"activePaneID":null}"#.utf8)
    let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    #expect(snapshot.recoveryWindow == nil)
}

@Test @MainActor func recoveryWindowOwnershipSurvivesReloadAndRequiresExplicitTransfer() throws {
    let suite = "relay.tests.recovery.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let registry = RecoveryWindowRegistry(defaults: defaults)
    let first = NSWindow()
    let second = NSWindow()
    first.identifier = .relayWorkspaceWindow
    second.identifier = .relayWorkspaceWindow
    let sessionID = UUID()
    registry.record(sessionID: sessionID, window: first)
    let origin = try #require(registry.origin(for: sessionID))
    registry.record(sessionID: sessionID, window: second)
    #expect(registry.origin(for: sessionID)?.id == origin.id)
    #expect(RecoveryWindowRegistry(defaults: defaults).origin(for: sessionID)?.id == origin.id)
    registry.record(sessionID: sessionID, replacing: true, window: second)
    #expect(registry.origin(for: sessionID)?.id != origin.id)
}

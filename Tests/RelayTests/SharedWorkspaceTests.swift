import Foundation
import Testing
@testable import Relay

private func sharedSnapshot(_ name: String = "First", tab: UUID = UUID(), pane: UUID = UUID()) -> WorkspaceSnapshot {
    WorkspaceSnapshot(tabs: [TabSnapshot(id: tab, sessionID: tab, name: name,
        layout: .pane(pane), floatingPanes: [], splitRatios: [:])],
        panes: [PaneSnapshot(id: pane, profile: .local, contentKind: .terminal,
            remoteParentSessionID: nil, editorRequest: nil, customName: nil)],
        sessionNames: [:], selectedTabID: tab, activePaneID: pane)
}

private func sharedUnion(_ a: WorkspaceSnapshot, _ b: WorkspaceSnapshot) -> WorkspaceSnapshot {
    WorkspaceSnapshot(tabs: a.tabs + b.tabs, panes: a.panes + b.panes,
        sessionNames: [:], selectedTabID: a.selectedTabID, activePaneID: a.activePaneID)
}

@Test func sharedWorkspaceIndependentInstancesRetainBothAdditions() throws {
    let base = sharedSnapshot(), a = sharedSnapshot("A"), b = sharedSnapshot("B")
    let merged = try RelaySharedWorkspaceStore.merge(local: sharedUnion(base, b),
        baseline: base, current: sharedUnion(base, a))
    #expect(Set(merged.tabs.map(\.id)) == Set([base.tabs[0].id, a.tabs[0].id, b.tabs[0].id]))
    #expect(merged.panes.count == 3)
    // A later unchanged save must preserve the other renderer's addition.
    let again = try RelaySharedWorkspaceStore.merge(local: sharedUnion(base, b),
        baseline: sharedUnion(base, b), current: merged)
    #expect(again.panes.count == 3)
}

@Test func sharedWorkspaceConflictingRenameAndStaleDeleteFailClosed() throws {
    let base = sharedSnapshot(), id = base.tabs[0].id, pane = base.panes[0].id
    let a = sharedSnapshot("A", tab: id, pane: pane)
    let b = sharedSnapshot("B", tab: id, pane: pane)
    #expect(throws: RelaySharedWorkspaceError.self) {
        try RelaySharedWorkspaceStore.merge(local: a, baseline: base, current: b)
    }
    let empty = WorkspaceSnapshot(tabs: [], panes: [], sessionNames: [:], selectedTabID: nil, activePaneID: nil)
    #expect(throws: RelaySharedWorkspaceError.self) {
        try RelaySharedWorkspaceStore.merge(local: empty, baseline: base, current: b)
    }
}

@Test func sharedWorkspaceStaleUnchangedPaneDoesNotResurrectDeletion() throws {
    let base = sharedSnapshot(), other = sharedSnapshot("Other")
    let combined = sharedUnion(base, other)
    let merged = try RelaySharedWorkspaceStore.merge(local: combined, baseline: combined, current: other)
    #expect(merged.tabs.map(\.id) == other.tabs.map(\.id))
    #expect(merged.panes.map(\.id) == other.panes.map(\.id))
}

@Test func sharedWorkspaceTwoStoresMergeUnderDurableLock() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-shared-proof-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = RelaySharedWorkspaceStore(directory: directory), second = RelaySharedWorkspaceStore(directory: directory)
    let base = sharedSnapshot(), a = sharedSnapshot("A"), b = sharedSnapshot("B")
    _ = try first.restore(legacy: JSONEncoder().encode(base))
    #expect(try second.restore(legacy: nil)?.panes.count == 1)
    _ = try first.commit(sharedUnion(base, a), baseline: base)
    let merged = try second.commit(sharedUnion(base, b), baseline: base)
    #expect(merged.panes.count == 3)
    #expect(try RelaySharedWorkspaceStore(directory: directory).restore(legacy: nil)?.panes.count == 3)
    // A corrupt saved file is not replaced by the older compatibility snapshot.
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("workspace-v1.json"))
    #expect(throws: (any Error).self) { try first.restore(legacy: JSONEncoder().encode(base)) }
    #expect(try Data(contentsOf: directory.appendingPathComponent("workspace-v1.json")) == Data("invalid".utf8))
}

@Test func sharedWorkspaceRejectsAliasedStateDirectoryAndDuplicatePane() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-shared-alias-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target"), alias = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    #expect(throws: (any Error).self) { try RelaySharedWorkspaceStore(directory: alias).restore(legacy: JSONEncoder().encode(sharedSnapshot())) }
    let base = sharedSnapshot()
    #expect(throws: RelaySharedWorkspaceError.self) { try RelaySharedWorkspaceStore.validate(sharedUnion(base, base)) }
}

@Test func processScopedInputSequencesDoNotWriteSharedPreferences() throws {
    let suite = "relay.tests.input-process.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let allocator = RelayInputSequenceAllocator(defaults: defaults, key: "high-water", blockSize: 2, persistReservations: false)
    #expect(allocator.next() == 1)
    #expect(allocator.next() == 2)
    #expect(allocator.next() == 3)
    #expect(defaults.object(forKey: "high-water") == nil)
}

@Test func sharedWorkspaceConflictsHaveDurableSeparateRecoveryDrafts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-shared-pending-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = RelaySharedWorkspaceStore(directory: directory), second = RelaySharedWorkspaceStore(directory: directory)
    let base = sharedSnapshot(), id = base.tabs[0].id, pane = base.panes[0].id
    let a = sharedSnapshot("A", tab: id, pane: pane), b = sharedSnapshot("B", tab: id, pane: pane)
    _ = try first.restore(legacy: JSONEncoder().encode(base))
    _ = try first.commit(a, baseline: base)
    #expect(throws: RelaySharedWorkspaceError.self) { try second.commit(b, baseline: base) }
    try second.preservePending(b)
    #expect(try RelaySharedWorkspaceStore(directory: directory).pendingCount() == 1)
    #expect(try first.restore(legacy: nil)?.tabs[0].name == "A")
    _ = try second.commit(a, baseline: base)
    #expect(try first.pendingCount() == 0)
}

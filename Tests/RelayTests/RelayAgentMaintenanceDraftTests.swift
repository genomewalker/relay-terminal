import Foundation
import Testing
@testable import Relay

private func draftOwner(_ pane: UUID) -> RelayPromptOwnerBinding {
    RelayPromptOwnerBinding(version: 1, paneId: pane.uuidString.lowercased(),
        nodeBootId: "owned-kernel", workerPid: 101, workerStart: 102, shellPid: 103, shellStart: 104,
        provider: "claude", processId: 105, processStart: 106, sessionId: "owned-session",
        transcriptIdentity: "owned-transcript")
}

private func draftDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-draft-tests-\(UUID().uuidString)/drafts")
}

@Test @MainActor func maintenanceDraftRoundTripsExactBytesPrivately() throws {
    let pane = UUID(), id = String(repeating: "a", count: 64)
    let text = Data("first line 🧬\n\tsecond  line with trailing spaces  \n[Pasted text #1 +40 lines]\nλ→∑".utf8)
    let draft = try RelayAgentMaintenanceDraft(actionID: id, paneID: pane, host: "this-mac",
        sessionID: "owned-session", originalOwner: draftOwner(pane), text: text)
    let directory = draftDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let store = RelayAgentMaintenanceDraftStore(directory: directory)
    try store.save(draft)
    let loaded = try store.load(id)
    #expect(loaded == draft)
    #expect(loaded.text == text)
    #expect(loaded.valid(actionID: id, paneID: pane, host: "this-mac", sessionID: "owned-session", digest: draft.digest))
    let file = directory.appendingPathComponent(id + ".json").path
    let fileMode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber
    let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(fileMode?.intValue == 0o600)
    #expect(directoryMode?.intValue == 0o700)
    // No temporary file is left behind.
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [id + ".json"])
}

@Test @MainActor func maintenanceDraftBackupIsImmutableAndRemovable() throws {
    let pane = UUID(), id = String(repeating: "b", count: 64)
    let first = try RelayAgentMaintenanceDraft(actionID: id, paneID: pane, host: "this-mac",
        sessionID: "owned-session", originalOwner: draftOwner(pane), text: Data("original".utf8))
    let second = try RelayAgentMaintenanceDraft(actionID: id, paneID: pane, host: "this-mac",
        sessionID: "owned-session", originalOwner: draftOwner(pane), text: Data("replacement".utf8))
    let directory = draftDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let store = RelayAgentMaintenanceDraftStore(directory: directory)
    try store.save(first)
    try store.save(first)
    #expect(throws: (any Error).self) { try store.save(second) }
    #expect(try store.load(id).text == Data("original".utf8))
    try store.remove(id)
    try store.remove(id)
    #expect(throws: (any Error).self) { try store.load(id) }
}

@Test @MainActor func maintenanceDraftRejectsUnsafeFilesAndChangedIdentity() throws {
    let pane = UUID(), id = String(repeating: "c", count: 64)
    let draft = try RelayAgentMaintenanceDraft(actionID: id, paneID: pane, host: "this-mac",
        sessionID: "owned-session", originalOwner: draftOwner(pane), text: Data("keep".utf8))
    #expect(!draft.valid(actionID: id, paneID: UUID(), host: "this-mac", sessionID: "owned-session", digest: draft.digest))
    #expect(!draft.valid(actionID: id, paneID: pane, host: "dandy-07", sessionID: "owned-session", digest: draft.digest))
    #expect(!draft.valid(actionID: id, paneID: pane, host: "this-mac", sessionID: "other-session", digest: draft.digest))
    #expect(!draft.valid(actionID: id, paneID: pane, host: "this-mac", sessionID: "owned-session",
        digest: RelayPromptEditorRPC.digest(Data("other".utf8))))
    #expect(throws: (any Error).self) {
        try RelayAgentMaintenanceDraft(actionID: id, paneID: pane, host: "this-mac", sessionID: "other-session",
            originalOwner: draftOwner(pane), text: Data("keep".utf8))
    }
    #expect(throws: (any Error).self) {
        try RelayAgentMaintenanceDraft(actionID: id, paneID: pane, host: "this-mac", sessionID: "owned-session",
            originalOwner: draftOwner(pane), text: Data([0x61, 0x00]))
    }
    let directory = draftDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let store = RelayAgentMaintenanceDraftStore(directory: directory)
    #expect(throws: (any Error).self) { try store.load("../" + String(repeating: "d", count: 61)) }
    try store.save(draft)
    let file = directory.appendingPathComponent(id + ".json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: (any Error).self) { try store.load(id) }
    // A symlinked backup is refused even when it points at a private file.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let other = String(repeating: "e", count: 64)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(other + ".json"),
        withDestinationURL: file)
    #expect(throws: (any Error).self) { try store.load(other) }
}

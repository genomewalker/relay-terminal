import Foundation
import Testing
@testable import Relay

@Test("Recovery isolates hosts and panes and preserves unsaved source preconditions")
func editorRecoveryRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorRecoveryStore(root: root)
    let profile = UUID(), owner = UUID(), otherOwner = UUID()
    let draft = EditorRecoveryRecord(ownerID: owner, profileID: profile, path: "/tmp/example.R",
        content: "plot(2)", savedContent: "plot(1)", modificationNS: 42, updated: Date())
    try store.save(draft)
    #expect(try store.load(profile: profile, path: draft.path, owner: owner) == draft)
    #expect(try store.load(profile: UUID(), path: draft.path, owner: owner) == nil)
    try store.save(EditorRecoveryRecord(ownerID: otherOwner, profileID: profile, path: draft.path,
        content: "plot(3)", savedContent: "plot(1)", modificationNS: 42, updated: Date()))
    #expect(store.recent(profile: profile).count == 2)
    #expect(try store.load(profile: profile, path: draft.path, owner: owner)?.content == "plot(2)")
    #expect(try store.load(profile: profile, path: draft.path, owner: owner)?.modificationNS == 42)
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

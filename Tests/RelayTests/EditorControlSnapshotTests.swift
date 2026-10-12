import Foundation
import Testing
@testable import Relay

@Test func editorControlSnapshotBoundsUnicodeAndRevision() throws {
    let text = String(repeating: "🌱", count: 20000)
    let snapshot = EditorControlSnapshot(documentID: "doc", revision: UInt64.max,
        path: "/test.R", dirty: true, diff: false, busy: false, text: text)
    #expect(snapshot.truncated)
    #expect(snapshot.content?.utf8.count == 65536)
    #expect(snapshot.content == String(repeating: "🌱", count: 16384))
    #expect(snapshot.revision == "18446744073709551615")
    #expect(try JSONEncoder().encode(snapshot).count < 1 << 20)
    let empty = EditorControlSnapshot(documentID: "empty", revision: 0, path: nil,
        dirty: false, diff: false, busy: true, text: nil)
    #expect(empty.content == nil)
    #expect(!empty.truncated)
}

import Foundation

/// A bounded native mirror, not a synchronous read of Monaco or the disk.
struct EditorControlSnapshot: Encodable, Sendable {
    let documentID: String
    let revision: String
    let path: String?
    let dirty: Bool
    let diff: Bool
    let busy: Bool
    let content: String?
    let truncated: Bool
    var rConsoleID: String? = nil
    var rSessionID: String? = nil
    let source = "native_editor_mirror"
    let consistency = "Last content received from editor; may lag pending UI edits. Not a write precondition."

    init(documentID: String, revision: UInt64, path: String?, dirty: Bool,
         diff: Bool, busy: Bool, text: String?) {
        self.documentID = documentID
        self.revision = String(revision)
        self.path = path
        self.dirty = dirty
        self.diff = diff
        self.busy = busy
        // UTF-8 JSON escaping can expand this at most sixfold: below the MCP
        // adapter's 1 MiB response cap. Do not split a Unicode scalar.
        let limit = 65536
        self.truncated = text.map { $0.utf8.count > limit } ?? false
        if let text, truncated {
            var end = text.utf8.index(text.utf8.startIndex, offsetBy: limit)
            while end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
            self.content = String(text[..<end])
        } else { self.content = text }
    }
}

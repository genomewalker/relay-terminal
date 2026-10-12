import Foundation

enum RelayProviderPromptRowMatch {
    struct PaintedRow {
        let row: Int
        let prefix: String
        let rendered: [Character]
    }

    struct LogicalRow {
        let row: Int
        let start: Int
        let prefix: String
        let body: [Character]
        var end: Int { start + body.count }
    }

    struct MappedDraft {
        let rows: [LogicalRow]
        let cursor: Int
    }

    struct Frame {
        let caretRow: Int
        let caretColumn: Int
        let columns: Int
        let beforeCaret: String
        let candidates: [[PaintedRow]]
    }

    /// Multiple possible composer starts are ambiguous, even when their
    /// recovered caret offsets happen to coincide.
    static func map(draft: [Character], frame: Frame) -> MappedDraft? {
        guard frame.columns > 0, frame.caretRow >= 0,
              frame.caretColumn >= 0, frame.caretColumn < frame.columns,
              !frame.candidates.isEmpty, frame.candidates.count <= 33 else { return nil }
        var result: MappedDraft?
        for candidate in frame.candidates {
            guard let mapped = map(draft: draft, paintedRows: candidate,
                caretRow: frame.caretRow, beforeCaret: frame.beforeCaret) else { continue }
            guard result == nil else { return nil }
            result = mapped
        }
        return result
    }

    /// Recover the logical caret from exact draft bytes and the original
    /// renderer's read-before-caret text. No cell-count or end-of-draft guess.
    static func map(draft: [Character], paintedRows: [PaintedRow],
                    caretRow: Int, beforeCaret: String) -> MappedDraft? {
        guard draft.count <= 4_096, !draft.contains("\t"),
              !draft.contains("\r"), !paintedRows.isEmpty, paintedRows.count <= 33 else { return nil }
        if draft.isEmpty {
            // The known empty draft still needs a visible composer boundary
            // and its caret. Suggestions/placeholders are not blank evidence.
            guard let first = paintedRows.first, first.row == caretRow,
                  !first.prefix.isEmpty, beforeCaret == first.prefix,
                  first.rendered.allSatisfy({ $0 == " " }) else { return nil }
            return MappedDraft(rows: [.init(row: first.row, start: 0,
                prefix: first.prefix, body: [])], cursor: 0)
        }
        var rows: [LogicalRow] = []
        var logical = 0
        for painted in paintedRows {
            guard rows.last.map({ painted.row == $0.row + 1 }) ?? true else { return nil }
            var body = painted.rendered
            while body.last == " " { body.removeLast() }
            if !rows.isEmpty {
                guard let start = continuationStart(body, draft: draft, from: logical) else { return nil }
                logical = start
            }
            guard let matched = retainingKnownTrailingSpaces(body, rendered: painted.rendered,
                draft: draft, start: logical) else { return nil }
            rows.append(LogicalRow(row: painted.row, start: logical, prefix: painted.prefix, body: matched))
            logical += matched.count
            if logical == draft.count { break }
        }
        guard logical == draft.count,
              let row = rows.first(where: { $0.row == caretRow }),
              beforeCaret.hasPrefix(row.prefix) else { return nil }
        let before = Array(beforeCaret.dropFirst(row.prefix.count))
        guard before.count <= row.body.count, row.body.starts(with: before) else { return nil }
        return MappedDraft(rows: rows, cursor: row.start + before.count)
    }

    /// Screen padding alone is not draft evidence. Restore only trailing spaces
    /// already present in the exact logical draft, and only into painted cells.
    static func retainingKnownTrailingSpaces(_ body: [Character], rendered: [Character],
        draft: [Character], start: Int) -> [Character]? {
        guard start >= 0, start <= draft.count,
              body.count <= rendered.count, rendered.starts(with: body),
              start + body.count <= draft.count,
              Array(draft[start..<(start + body.count)]) == body else { return nil }
        let remaining = draft.dropFirst(start + body.count).prefix(while: { $0 == " " })
        guard !remaining.isEmpty else { return body }
        let padding = rendered.dropFirst(body.count)
        guard padding.allSatisfy({ $0 == " " }) else { return nil }
        return body + Array(remaining.prefix(padding.count))
    }

    /// One painted continuation row can cross one explicit newline. Empty
    /// draft rows must consume their own newline, rather than matching any
    /// position through an empty-prefix comparison.
    static func continuationStart(_ body: [Character], draft: [Character], from start: Int) -> Int? {
        guard start >= 0, start <= draft.count else { return nil }
        var candidate = start
        if body.isEmpty {
            if candidate < draft.count, draft[candidate] == "\n" { candidate += 1 }
            return candidate == draft.count || draft[candidate] == " " || draft[candidate] == "\n" ? candidate : nil
        }
        var crossedNewline = false
        while candidate <= draft.count {
            if candidate + body.count <= draft.count,
               Array(draft[candidate..<(candidate + body.count)]) == body { return candidate }
            guard candidate < draft.count else { return nil }
            if draft[candidate] == "\n" {
                guard !crossedNewline else { return nil }
                crossedNewline = true
            } else if draft[candidate] != " " { return nil }
            candidate += 1
        }
        return nil
    }
}

import Foundation

/// Bounded pipe tables; escaped pipes and pipes inside backtick spans stay in cells.
struct RelayAgentMarkdownTable: Hashable {
    enum ColumnAlignment: Hashable { case left, center, right }
    let header: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]

    static func cells(_ source: String) -> [String]? {
        let text = Array(source.trimmingCharacters(in: .whitespaces))
        var cells: [String] = [], cell = "", codeRun = 0, index = 0, separators = 0
        var firstSeparator = false, lastSeparator = false
        while index < text.count {
            let char = text[index]
            if char == "\\", index + 1 < text.count {
                // Preserve Markdown escapes for the inline parser.
                cell.append(char); cell.append(text[index + 1]); index += 2; lastSeparator = false; continue
            }
            if char == "`" {
                var end = index + 1
                while end < text.count && text[end] == "`" { end += 1 }
                let run = end - index
                if codeRun == 0 {
                    // An unmatched backtick does not hide subsequent separators.
                    var cursor = end, matched = false
                    while cursor < text.count {
                        if text[cursor] != "`" { cursor += 1; continue }
                        var stop = cursor + 1
                        while stop < text.count && text[stop] == "`" { stop += 1 }
                        if stop - cursor == run { matched = true; break }
                        cursor = stop
                    }
                    if matched { codeRun = run }
                } else if codeRun == run { codeRun = 0 }
                cell += String(repeating: "`", count: run); index = end; lastSeparator = false; continue
            }
            if char == "|", codeRun == 0 {
                if index == 0 { firstSeparator = true }
                cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""
                separators += 1; lastSeparator = true
            } else { cell.append(char); lastSeparator = false }
            index += 1
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if firstSeparator { cells.removeFirst() }
        if lastSeparator { cells.removeLast() }
        guard separators > 0, !cells.isEmpty, cells.count <= 32 else { return nil }
        return cells
    }

    static func parse(_ lines: [String], at index: Int) -> (RelayAgentMarkdownTable, Int)? {
        guard index + 1 < lines.count,
              let header = cells(lines[index]), let delimiters = cells(lines[index + 1]),
              header.count == delimiters.count else { return nil }
        var alignments: [ColumnAlignment] = []
        for delimiter in delimiters {
            let value = delimiter.trimmingCharacters(in: .whitespaces)
            let body = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard body.count >= 3, body.allSatisfy({ $0 == "-" }),
                  value == body || value == ":" + body || value == body + ":" || value == ":" + body + ":" else { return nil }
            alignments.append(value.hasSuffix(":") ? (value.hasPrefix(":") ? .center : .right) : .left)
        }
        var rows: [[String]] = [], next = index + 2
        while next < lines.count, let row = cells(lines[next]) {
            // Large tables remain literal rather than silently omitting rows.
            guard rows.count < 512 else { return nil }
            rows.append(Array((row + Array(repeating: "", count: header.count)).prefix(header.count)))
            next += 1
        }
        return (RelayAgentMarkdownTable(header: header, alignments: alignments, rows: rows), next)
    }
}

import Foundation

/// Bounded, inert previews. Never instantiate a web view for repository content.
enum PluginArtifactPreview: Sendable {
    case text(String, partial: Bool)
    case markdown(source: String, formatted: AttributedString, partial: Bool)
    case table([[String]], partial: Bool)
    case binary

    static func decode(_ bytes: Data, path: String) -> Self {
        let limit = 128 * 1024
        let prefix = bytes.prefix(limit)
        guard !prefix.contains(0) else { return .binary }
        // A byte limit may split a UTF-8 scalar. Trim at most three trailing bytes.
        var bounded = Data(prefix)
        var text = String(data: bounded, encoding: .utf8)
        if bytes.count > limit {
            for _ in 0..<3 where text == nil {
                bounded.removeLast()
                text = String(data: bounded, encoding: .utf8)
            }
        }
        guard let text else { return .binary }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "csv" || ext == "tsv", let rows = table(text, separator: ext == "csv" ? "," : "\t") {
            return .table(Array(rows.prefix(100)), partial: bytes.count > limit || rows.count > 100)
        }
        if ext == "md" || ext == "markdown",
           var formatted = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) {
            // Native attributed text, not HTML. File content cannot launch URLs;
            // source is always available for copying links or inspecting markup.
            let ranges = formatted.runs.filter { $0.link != nil }.map(\.range)
            for range in ranges { formatted[range].link = nil }
            // SwiftUI Text does not lay out Foundation's block presentation
            // intents. Restore block boundaries instead of joining paragraphs.
            var displayed = AttributedString()
            var previous: PresentationIntent?
            for run in formatted.runs {
                if !displayed.characters.isEmpty && run.presentationIntent != previous {
                    displayed.append(AttributedString("\n\n"))
                }
                displayed.append(AttributedString(formatted[run.range]))
                previous = run.presentationIntent
            }
            return .markdown(source: text, formatted: displayed, partial: bytes.count > limit)
        }
        // HTML remains source; never load scripts or external resources.
        return .text(text, partial: bytes.count > limit)
    }

    static func table(_ text: String, separator: Character) -> [[String]]? {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == separator {
                row.append(field); field = ""; closed = false
                if row.count >= 32 { return nil }
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""; closed = false
                if rows.count > 100 { return rows }
            } else if c == "\"" && field.isEmpty && !closed { quoted = true }
            else {
                if closed || c == "\"" { return nil }
                field.append(c)
            }
            if field.utf8.count > 4096 { return nil }
            i += 1
        }
        guard !quoted else { return nil }
        if !field.isEmpty || !row.isEmpty || closed { row.append(field); rows.append(row) }
        return rows
    }
}

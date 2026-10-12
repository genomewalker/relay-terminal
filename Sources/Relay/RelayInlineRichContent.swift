import SwiftUI

/// Geometry belongs to the existing terminal rows. Never insert synthetic PTY
/// bytes or shift the TUI cursor to make room for a preview.
struct RelayInlineRichRegion: Equatable, Identifiable {
    let startRow: Int
    let rowCount: Int
    let content: RelaySurfaceContent
    let cellSize: CGSize
    let columns: Int
    var id: String { "\(startRow):\(content.kind.rawValue):\(content.text)" }

    static func detect(rows: [String], cellSize: CGSize, columns: Int) -> [Self] {
        guard cellSize.width > 0, cellSize.height > 0, columns > 0,
              rows.count <= 512 else { return [] }
        let lines = rows.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result: [Self] = []
        var index = 0
        while index < lines.count, result.count < 8 {
            let line = lines[index]
            var end = index
            var source: String?
            var kind = RelaySurfaceContent.Kind.equation
            if line == "```mermaid" || ["graph ", "flowchart ", "sequenceDiagram", "classDiagram", "stateDiagram", "erDiagram"].contains(where: line.hasPrefix) {
                kind = .diagram
                let fenced = line == "```mermaid"
                let first = index + (fenced ? 1 : 0)
                end = first
                while end < lines.count, !lines[end].isEmpty, lines[end] != "```", !lines[end].hasPrefix("›") { end += 1 }
                if end > first { source = lines[first..<end].joined(separator: "\n") }
                if fenced, end < lines.count, lines[end] == "```" { end += 1 }
            } else {
                for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)")] {
                    guard let start = line.range(of: open) else { continue }
                    var body = String(line[start.upperBound...])
                    end = index + 1
                    while !body.contains(close), end < lines.count, end - index < 32 {
                        body += "\n" + lines[end]; end += 1
                    }
                    if let stop = body.range(of: close) { source = String(body[..<stop.lowerBound]) }
                    break
                }
            }
            if let source {
                let content = RelaySurfaceContent(kind: kind, text: source)
                if !source.isEmpty, (try? content.validate()) != nil {
                    result.append(.init(startRow: index, rowCount: max(1, end-index),
                                        content: content, cellSize: cellSize, columns: columns))
                    index = max(index+1, end); continue
                }
            }
            index += 1
        }
        return result
    }
}

struct RelayInlineRichLayer: View {
    let regions: [RelayInlineRichRegion]
    var padding: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
            ForEach(regions) { region in
                let width = min(max(0, geometry.size.width - 2 * padding), CGFloat(region.columns) * region.cellSize.width)
                let height = CGFloat(region.rowCount) * region.cellSize.height
                RelayRichContentView(kind: region.content.kind, source: region.content.text, inline: true)
                    .frame(width: width, height: height)
                    .position(x: padding + width / 2, y: padding + CGFloat(region.startRow) * region.cellSize.height + height / 2)
                    .clipped()
            }
        }.clipped()
    }
}

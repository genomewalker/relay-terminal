import SwiftUI
import AppKit

/// Native renderer for portable, bounded surface content. Specialized producers
/// retain their own controls and supply declarative content to this shared view.
struct RelaySurfaceView: View {
    let content: RelaySurfaceContent
    var body: some View {
        if (try? content.validate()) == nil {
            Text("Surface exceeds supported limits. Use the source artifact to inspect the complete result.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            switch content.kind {
            case .table:
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Text("").frame(width: 38)
                        ForEach(content.columns.indices, id: \.self) { j in cell(content.columns[j], heading: true) }
                    }.background(Color.primary.opacity(0.10))
                    ForEach(content.rows.indices, id: \.self) { i in
                        GridRow {
                            Text(String(i + 1)).foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing).padding(RelayTheme.spacing(6))
                            ForEach(content.rows[i].indices, id: \.self) { j in cell(content.rows[i][j]) }
                        }.background(Color.primary.opacity(i.isMultiple(of: 2) ? 0 : 0.035))
                    }
                }
            case .status:
                HStack {
                    Text(content.title).font(RelayTheme.font(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(content.status).font(RelayTheme.font(size: 10)).foregroundStyle(.secondary)
                }.padding(.vertical, RelayTheme.spacing(5))
            case .image:
                if let data = content.imageData(), let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .accessibilityLabel(content.title.isEmpty ? "Published image" : content.title)
                }
            case .markdown:
                Text((try? AttributedString(markdown: content.text)) ?? AttributedString(content.text))
                    .textSelection(.enabled)
            case .equation, .diagram:
                VStack(alignment: .leading) {
                    RelayRichContentView(kind: content.kind, source: content.text).frame(minHeight: 280)
                    DisclosureGroup("Source") {
                        Text(content.text).font(RelayTheme.font(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            case .text, .diff:
                Text(content.text).font(content.kind == .diff ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
            }
        }
    }
    private func cell(_ value: String, heading: Bool = false) -> some View {
        Text(value).textSelection(.enabled).fontWeight(heading ? .semibold : .regular)
            .lineLimit(1).frame(width: 130, alignment: .leading).padding(RelayTheme.spacing(8))
    }
}

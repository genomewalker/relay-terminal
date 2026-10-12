import AppKit
import ImageIO
import SwiftUI
import WebKit

// Message presentation for the native agent conversation. Layout patterns adapted
// from Monocode (MIT, Copyright (c) 2026 Nick); see RelayAgentDesign.swift.

/// One provider item rendered by role. Content is provider source text; nothing is
/// reconstructed from terminal output.
struct RelayAgentMessageView: View {
    @ObservedObject var pane: PaneModel
    let item: RelayAgentConversationItem
    var artifactBaseDirectory: String? = nil

    var body: some View {
        switch item.role {
        case .user:
            VStack(alignment: .trailing, spacing: RelayAgentDesign.blockSpacing) {
                RelayAgentUserMessage(axID: Self.axID(item.id), text: Self.plainText(item.blocks))
                attachments
            }
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: RelayAgentDesign.blockSpacing) { blocks }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) { blocks }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            Text(Self.plainText(item.blocks))
                .font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.tertiaryInk)
                .textSelection(.enabled).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var blocks: some View {
        ForEach(Array(item.blocks.enumerated()), id: \.offset) { index, block in
            let axID = Self.axID(item.id, block: index)
            switch block {
            case .markdown(let text):
                if item.role == .tool {
                    RelayAgentToolRow(axID: axID, name: "Output", status: "completed", summary: text)
                } else {
                    RelayAgentProse(axID: axID, source: text)
                    ForEach(Array(RelayAgentArtifactReferences.paths(in: text).enumerated()), id: \.element) { artifact, path in
                        RelayAgentArtifactView(axID: axID + ".artifact." + String(artifact), pane: pane, path: path, baseDirectory: artifactBaseDirectory)
                    }
                }
            case .tool(let name, let status, let summary):
                RelayAgentToolRow(axID: axID, name: name, status: status, summary: summary)
            case .code(let language, let source):
                RelayAgentCodeBlock(axID: axID, language: language, source: source)
            case .equation(let source):
                RelayAgentRichProse(source: "$$\n" + source + "\n$$")
            case .diagram(let source):
                RelayAgentRichProse(source: "```mermaid\n" + source + "\n```")
            case .providerImage(let reference):
                RelayAgentProviderImageView(pane: pane, reference: reference)
            case .artifact(let id, _):
                RelayAgentArtifactView(axID: axID + ".artifact", pane: pane, path: id, baseDirectory: artifactBaseDirectory)
            }
        }
    }

    @ViewBuilder private var attachments: some View {
        ForEach(Array(item.blocks.enumerated()), id: \.offset) { index, block in
            switch block {
            case .providerImage(let reference): RelayAgentProviderImageView(pane: pane, reference: reference)
            case .artifact(let id, _):
                RelayAgentArtifactView(axID: Self.axID(item.id, block: index), pane: pane, path: id, baseDirectory: artifactBaseDirectory)
            default: EmptyView()
            }
        }
    }

    /// Identifiers are keyed by provider item ID and block index, so repeated labels
    /// such as several "Bash" tools stay individually addressable.
    static func axID(_ itemID: String, block: Int? = nil) -> String {
        "relay.agent.item." + itemID + (block.map { "." + String($0) } ?? "")
    }

    static func plainText(_ blocks: [RelayAgentConversationItem.Block]) -> String {
        blocks.compactMap { block -> String? in
            switch block {
            case .markdown(let text), .equation(let text), .diagram(let text): return text
            case .code(_, let source): return source
            case .tool(let name, _, let summary): return name + "\n" + summary
            case .providerImage: return nil
            case .artifact(let id, _): return id
            }
        }.joined(separator: "\n\n")
    }
}

// MARK: - User

/// The user's prompt as a quiet bubble. Long prompts clamp to four lines.
struct RelayAgentUserMessage: View {
    let axID: String
    let text: String
    @State private var expanded = false
    @State private var hovering = false
    private var long: Bool {
        text.count > 320 || text.split(separator: "\n", omittingEmptySubsequences: false).count > RelayAgentDesign.userLineClamp
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: RelayTheme.spacing(2)) {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
                Text(text)
                    .font(RelayAgentDesign.prose).lineSpacing(RelayAgentDesign.proseLineSpacing)
                    .lineLimit(expanded ? nil : RelayAgentDesign.userLineClamp)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if long {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                        .buttonStyle(RelayAgentQuietButtonStyle())
                        .accessibilityIdentifier(axID + ".show-more")
                }
            }
            .padding(.horizontal, RelayTheme.spacing(12)).padding(.vertical, RelayTheme.spacing(8))
            .background(RelayAgentDesign.bubble, in: RoundedRectangle(cornerRadius: RelayAgentDesign.radius))
            .overlay(RoundedRectangle(cornerRadius: RelayAgentDesign.radius).strokeBorder(RelayAgentDesign.stroke))
            .frame(maxWidth: 560, alignment: .trailing)
            HStack(spacing: RelayTheme.spacing(2)) {
                Button("Copy", systemImage: "doc.on.doc") { RelayAgentClipboard.copy(text) }
                    .buttonStyle(RelayAgentQuietButtonStyle()).labelStyle(.iconOnly).help("Copy prompt")
                    .accessibilityIdentifier(axID + ".copy")
            }
            .opacity(hovering ? 1 : 0)
            .accessibilityHidden(!hovering)
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your message")
    }
}

// MARK: - Assistant prose

/// Native Markdown for ordinary messages; the sandboxed web renderer only when the
/// source actually contains math or a diagram.
struct RelayAgentProse: View {
    let axID: String
    let source: String
    var body: some View {
        if RelayAgentRichDetection.needsRenderer(source) {
            RelayAgentRichProse(source: source)
        } else {
            VStack(alignment: .leading, spacing: RelayAgentDesign.blockSpacing) {
                ForEach(Array(RelayAgentMarkdownBlocks.split(source).enumerated()), id: \.offset) { part, block in
                    switch block {
                    case .markdown(let text): RelayAgentMarkdownText(source: text)
                    case .code(let language, let code):
                        RelayAgentCodeBlock(axID: axID + ".code." + String(part), language: language, source: code)
                    default: EmptyView()
                    }
                }
            }
        }
    }
}

enum RelayAgentRichDetection {
    static func needsRenderer(_ source: String) -> Bool {
        let lower = source.lowercased()
        if lower.contains("```mermaid") || lower.contains("```math") || lower.contains("```latex") || lower.contains("```tex") ||
            source.contains("$$") || source.contains("\\[") || source.contains("\\(") { return true }
        guard source.contains("$"), let inlineMath = try? NSRegularExpression(
            pattern: #"(?<![\\$\w])\$(?=\S)[^$\n]{1,400}(?<=\S)\$(?![\w$])"#) else { return false }
        return inlineMath.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
    }
}

/// Block-level Markdown (headings, lists, quotes, rules, paragraphs) with inline
/// Markdown inside each block. SwiftUI's own parser drops block structure.
struct RelayAgentMarkdownText: View {
    let source: String
    private enum Line: Hashable {
        case heading(Int, String), bullet(Int, String), ordered(Int, String, String), quote(String), rule, paragraph(String), table(RelayAgentMarkdownTable)
    }
    private var lines: [Line] {
        var result: [Line] = []
        var paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph.removeAll() } }
        let sourceLines = source.components(separatedBy: "\n")
        var index = 0
        while index < sourceLines.count {
            if let (table, next) = RelayAgentMarkdownTable.parse(sourceLines, at: index) {
                flush(); result.append(.table(table)); index = next; continue
            }
            let raw = sourceLines[index]
            index += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indent = (raw.prefix { $0 == " " || $0 == "\t" }.count) / 2
            if trimmed.isEmpty { flush(); continue }
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
               trimmed[hashes] == " ", trimmed.distance(from: trimmed.startIndex, to: hashes) <= 6 {
                flush(); result.append(.heading(trimmed.distance(from: trimmed.startIndex, to: hashes), String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush(); result.append(.rule)
            } else if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) {
                flush(); result.append(.bullet(min(indent, 4), String(trimmed.dropFirst(2))))
            } else if let marker = trimmed.firstMatch(of: /^(\d{1,4})[.)]\s+/) {
                flush(); result.append(.ordered(min(indent, 4), String(marker.1), String(trimmed[marker.range.upperBound...])))
            } else if trimmed.hasPrefix(">") {
                flush(); result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else { paragraph.append(raw) }
        }
        flush()
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .heading(let level, let text):
                    Self.inline(text).font(RelayTheme.font(size: level <= 1 ? 16 : level == 2 ? 14.5 : 13, weight: .semibold))
                        .padding(.top, level <= 2 ? 6 : 2)
                case .bullet(let indent, let text):
                    listRow(marker: "•", indent: indent, text: text)
                case .ordered(let indent, let number, let text):
                    listRow(marker: number + ".", indent: indent, text: text)
                case .quote(let text):
                    HStack(alignment: .top, spacing: RelayTheme.spacing(8)) {
                        RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(1)).fill(RelayAgentDesign.tertiaryInk).frame(width: 2)
                        Self.inline(text).font(RelayAgentDesign.prose).foregroundStyle(RelayAgentDesign.secondaryInk)
                    }.fixedSize(horizontal: false, vertical: true)
                case .rule:
                    Rectangle().fill(RelayAgentDesign.stroke).frame(height: 1).padding(.vertical, RelayTheme.spacing(4))
                case .table(let table):
                    RelayAgentTableView(table: table)
                case .paragraph(let text):
                    Self.inline(text).font(RelayAgentDesign.prose).lineSpacing(RelayAgentDesign.proseLineSpacing)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func listRow(marker: String, indent: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RelayTheme.spacing(6)) {
            Text(marker).font(RelayAgentDesign.prose).foregroundStyle(RelayAgentDesign.secondaryInk)
                .frame(minWidth: 14, alignment: .trailing)
            Self.inline(text).font(RelayAgentDesign.prose).lineSpacing(RelayAgentDesign.proseLineSpacing)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }
    static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

/// Native selectable cells with a horizontal scroller for wide tables.
struct RelayAgentTableView: View {
    let table: RelayAgentMarkdownTable
    private func alignment(_ column: Int) -> Alignment {
        switch table.alignments[column] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(([table.header] + table.rows).enumerated()), id: \.offset) { row, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                            RelayAgentMarkdownText.inline(cell)
                                .font(RelayTheme.font(size: 12, weight: row == 0 ? .semibold : .regular))
                                .frame(width: column == 0 ? 100 : 260, alignment: alignment(column))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .gridCellAnchor(.topLeading)
                                .background(row == 0 ? RelayAgentDesign.codeFill : Color.clear)
                                .overlay(alignment: .bottom) { Rectangle().fill(RelayAgentDesign.stroke).frame(height: 1) }
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(RoundedRectangle(cornerRadius: RelayAgentDesign.radius).strokeBorder(RelayAgentDesign.stroke))
        .accessibilityLabel("Table, \(table.header.count) columns, \(table.rows.count) rows")
    }
}

// MARK: - Code

struct RelayAgentCodeBlock: View {
    let axID: String
    let language: String
    let source: String
    @State private var expanded = false
    private var lineCount: Int { source.split(separator: "\n", omittingEmptySubsequences: false).count }
    private var collapsible: Bool { lineCount > RelayAgentDesign.codeCollapseLines }
    private var shown: String {
        guard collapsible, !expanded else { return source }
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(RelayAgentDesign.codeCollapseLines).joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(0)) {
            HStack(spacing: RelayTheme.spacing(6)) {
                Text(language.isEmpty ? "code" : language)
                    .font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.tertiaryInk)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { RelayAgentClipboard.copy(source) }
                    .buttonStyle(RelayAgentQuietButtonStyle()).help("Copy code")
                    .accessibilityIdentifier(axID + ".copy")
            }
            .padding(.leading, RelayTheme.spacing(10)).padding(.trailing, RelayTheme.spacing(4)).padding(.top, RelayTheme.spacing(4))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(shown).font(RelayAgentDesign.mono).lineSpacing(RelayAgentDesign.monoLineSpacing)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, RelayTheme.spacing(10)).padding(.bottom, collapsible ? 4 : 10).padding(.top, RelayTheme.spacing(2))
            }
            if collapsible {
                Button(expanded ? "Show fewer lines" : "Show all \(lineCount) lines") { expanded.toggle() }
                    .buttonStyle(RelayAgentQuietButtonStyle()).padding(.horizontal, RelayTheme.spacing(4)).padding(.bottom, RelayTheme.spacing(4))
                    .accessibilityIdentifier(axID + ".expand")
            }
        }
        .background(RelayAgentDesign.codeFill, in: RoundedRectangle(cornerRadius: RelayAgentDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: RelayAgentDesign.radius).strokeBorder(RelayAgentDesign.stroke))
    }
}

// MARK: - Tools

/// A tool call as one quiet row; its output opens below in a bounded scroller.
struct RelayAgentToolRow: View {
    let axID: String
    let name: String
    let status: String
    let summary: String
    @State private var open = false
    private var failed: Bool { ["error", "failed", "failure", "rejected", "denied"].contains(status.lowercased()) }
    private var running: Bool { ["started", "running", "in_progress", "inprogress", "pending"].contains(status.lowercased()) }
    private var headline: String {
        let first = summary.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return String(first.trimmingCharacters(in: .whitespaces).prefix(120))
    }
    var body: some View {
        RelayAgentDisclosureRow(axID: axID, open: $open) {
            HStack(spacing: RelayTheme.spacing(6)) {
                if running { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
                else {
                    Image(systemName: failed ? "xmark.circle" : "wrench.and.screwdriver")
                        .font(RelayTheme.font(size: 10)).frame(width: 12)
                        .foregroundStyle(failed ? RelayAgentDesign.failureInk : RelayAgentDesign.tertiaryInk)
                }
                Text(name).font(RelayAgentDesign.label).foregroundStyle(Color.primary.opacity(0.8)).lineLimit(1)
                Text(status == "inProgress" ? "Running" : status.capitalized)
                    .font(RelayAgentDesign.meta).foregroundStyle(failed ? RelayAgentDesign.failureInk : RelayAgentDesign.tertiaryInk)
                    .lineLimit(1)
                if !headline.isEmpty {
                    Text(headline).font(RelayAgentDesign.mono).foregroundStyle(RelayAgentDesign.tertiaryInk).lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        } detail: {
            ScrollView {
                Text(summary.isEmpty ? "No output recorded." : summary)
                    .font(RelayAgentDesign.mono).lineSpacing(RelayAgentDesign.monoLineSpacing)
                    .foregroundStyle(failed ? RelayAgentDesign.failureInk : RelayAgentDesign.secondaryInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(RelayTheme.spacing(10))
            }
            .frame(maxHeight: 288)
            .fixedSize(horizontal: false, vertical: true)
            .background(RelayAgentDesign.codeFill, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
        }
        .accessibilityLabel(headline.isEmpty ? "Tool \(name), \(status)" : "Tool \(name), \(status): \(headline)")
    }
}

// MARK: - Rich (math and diagrams)

/// Sized web rendering for one message that contains math or Mermaid.
struct RelayAgentRichProse: View {
    let source: String
    @State private var height: CGFloat = 120
    var body: some View {
        RelayAgentRichMessage(source: source, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

/// One web view per visible rich message; ordinary conversation text stays native.
/// Source enters as JSON, and the renderer has no network, HTML or script input.
struct RelayAgentRichMessage: NSViewRepresentable {
    let source: String
    @Binding var height: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "agentHeight")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.underPageBackgroundColor = NSColor(calibratedWhite: 0.106, alpha: 1)
        web.navigationDelegate = context.coordinator; context.coordinator.source = source
        if let root = RelayResources.bundle?.url(forResource: "RichContent", withExtension: nil) {
            let page = root.appendingPathComponent("viewer/index.html"); context.coordinator.page = page
            web.loadFileURL(page, allowingReadAccessTo: root)
        }
        return web
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.source != source else { return }
        context.coordinator.source = source; context.coordinator.render(view)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "agentHeight")
        view.stopLoading(); view.navigationDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var source = ""
        var page: URL?
        var ready = false
        let height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }
        func render(_ web: WKWebView) {
            guard ready, source.utf8.count <= 131_072,
                  let data = try? JSONSerialization.data(withJSONObject: ["source": source]),
                  let json = String(data: data, encoding: .utf8) else { return }
            web.evaluateJavaScript("window.renderRelayAgentMessage(\(json)); void 0", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(webView) }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.request.url == page && navigationAction.navigationType == .other { return .allow }
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, ["https", "http"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            return .cancel
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? Double, value.isFinite else { return }
            let next = min(4000, max(32, value))
            if abs(height.wrappedValue - next) > 1 { height.wrappedValue = next }
        }
    }
}

// MARK: - Artifacts

/// Source references are lexical only. No file is read until Preview is chosen.
enum RelayAgentArtifactReferences {
    static func paths(in source: String) -> [String] {
        var paths: [String] = []
        for block in RelayAgentMarkdownBlocks.split(source) {
            guard case .markdown(let text) = block else { continue }
            guard let expression = try? NSRegularExpression(pattern: #"!?\[[^\]\n]{0,256}\]\(([^\s()]{1,4096})\)"#) else { continue }
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let raw = String(text[range])
                guard !raw.contains("://"), !raw.hasPrefix("data:"), !raw.contains("\u{0000}") else { continue }
                let path = raw.removingPercentEncoding ?? raw
                guard ["png", "jpg", "jpeg", "svg", "pdf"].contains(TerminalPathSyntax.pathExtension(path)),
                      !paths.contains(path), paths.count < 16 else { continue }
                paths.append(path)
            }
        }
        return paths
    }
}

/// Lazy host-bound preview: bytes are fetched only on request and released when hidden.
struct RelayAgentArtifactView: View {
    let axID: String
    @ObservedObject var pane: PaneModel
    let path: String
    var baseDirectory: String? = nil
    @State private var artifact: PaneArtifact?
    @State private var busy = false
    @State private var failure: String?
    @State private var request = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
            HStack(spacing: RelayTheme.spacing(8)) {
                Image(systemName: TerminalPathSyntax.pathExtension(path) == "pdf" ? "doc.richtext" : "photo")
                    .font(RelayTheme.font(size: 11)).foregroundStyle(RelayAgentDesign.tertiaryInk)
                Text(TerminalPathSyntax.lastComponent(path))
                    .font(RelayAgentDesign.label).lineLimit(1).truncationMode(.middle).help(path)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if artifact != nil {
                    Button("Close") { request = UUID(); artifact = nil }.buttonStyle(RelayAgentQuietButtonStyle())
                        .accessibilityIdentifier(axID + ".close")
                } else {
                    Button("Preview") { load() }.buttonStyle(RelayAgentQuietButtonStyle()).disabled(busy)
                        .accessibilityIdentifier(axID + ".preview")
                }
            }
            if let artifact {
                if artifact.isPDF { RelayPDFPreview(data: artifact.data).frame(height: 440) }
                else if let image = artifact.image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 440)
                } else { Text("This file cannot be previewed.").font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.secondaryInk) }
            }
            if let failure { Text(failure).font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.failureInk) }
        }
        .padding(.horizontal, RelayTheme.spacing(10)).padding(.vertical, RelayTheme.spacing(6))
        .background(RelayAgentDesign.codeFill, in: RoundedRectangle(cornerRadius: RelayAgentDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: RelayAgentDesign.radius).strokeBorder(RelayAgentDesign.stroke))
        .onDisappear { request = UUID(); artifact = nil }
    }
    private func load() {
        let token = UUID(); request = token; busy = true; failure = nil
        let profile = pane.profile
        let resolved = TerminalPathSyntax.resolving(path, against: baseDirectory ?? pane.directory ?? "/")
        Task { @MainActor in
            defer { busy = false }
            do {
                let data = try await RemoteArtifactLoader.load(path: resolved, profile: profile)
                guard request == token else { return }
                artifact = PaneArtifact(remotePath: resolved, data: data)
            } catch {
                guard request == token else { return }
                failure = error.localizedDescription
            }
        }
    }
}


/// Loads only a visible provider attachment. References bind the image to an exact
/// process, transcript inode, row offset and content digest on its original host.
struct RelayAgentProviderImageView: View {
    @ObservedObject var pane: PaneModel
    let reference: String
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var generation = UUID()
    private struct Response: Decodable {
        let version: Int
        let mime: String?
        let data: Data?
        let unbound: String?
    }
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 560, maxHeight: 360)
                    .accessibilityLabel("Provider image attachment")
            } else if let failure {
                Text(failure).font(RelayAgentDesign.meta).foregroundStyle(RelayAgentDesign.secondaryInk)
            } else {
                ProgressView("Loading image attachment").controlSize(.small)
            }
        }
        .task(id: reference) { await load() }
        .onDisappear { generation = UUID(); image = nil }
    }
    @MainActor private func load() async {
        let token = UUID(); generation = token; image = nil; failure = nil
        do {
            guard reference.utf8.count <= 4096, Data(base64Encoded: reference) != nil,
                  let root = RelayResources.bundle?.url(forResource: "Rotation", withExtension: nil) else { throw RemoteCatalogError.invalidResponse }
            let script = try Data(contentsOf: root.appendingPathComponent("agent_conversation.py"))
            guard script.count <= 64 << 10 else { throw RemoteCatalogError.invalidResponse }
            let rootPID = pane.profile.kind == .local ? Int(pane.networkForegroundPID ?? 0) : 0
            let daemon = RelayHostExecution.daemonCommand(profile: pane.profile, arguments: [])
            // Base64 is restricted to an alphabet with no shell quotes or expansions.
            let command = "python3 - --binding-daemon " + daemon + " --pane '" + pane.id.uuidString.lowercased() +
                "' --root-pid " + String(rootPID) + " --attachment '" + reference + "'"
            let result = try await RelayHostExecution.capture(profile: pane.profile, command: command,
                input: script, timeout: 20, maximumBytes: 12 << 20)
            try Task.checkCancellation()
            guard generation == token else { return }
            guard result.exitCode == 0 else { throw RemoteCatalogError.failed("Image reader could not complete on this host.") }
            let response = try JSONDecoder().decode(Response.self, from: result.stdout)
            if let reason = response.unbound { throw RemoteCatalogError.failed(reason) }
            guard response.version == 1, let data = response.data, !data.isEmpty, data.count <= 8 << 20,
                  ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(response.mime ?? ""),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0, height.intValue > 0, width.intValue <= 16384, height.intValue <= 16384,
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1120,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw RemoteCatalogError.failed("Image attachment could not be decoded within preview limits.") }
            image = NSImage(cgImage: thumbnail, size: .zero)
        } catch is CancellationError { }
        catch {
            guard generation == token else { return }
            failure = error.localizedDescription
        }
    }
}

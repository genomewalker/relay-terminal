import SwiftUI
import PDFKit

/// Reads the rendered viewport, never the raw TUI repaint stream.
enum RelayRichContentDetector {
    static func detect(_ viewport: String) -> [RelaySurfaceContent] {
        let text = String(viewport.prefix(32_768))
        var result: [RelaySurfaceContent] = []
        func append(_ kind: RelaySurfaceContent.Kind, _ source: String) {
            let content = RelaySurfaceContent(kind: kind, text: source.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !content.text.isEmpty, (try? content.validate()) != nil,
                  !result.contains(content), result.count < 16 else { return }
            result.append(content)
        }
        func matches(_ pattern: String, kind: RelaySurfaceContent.Kind) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let range = Range(match.range(at: 1), in: text) { append(kind, String(text[range])) }
            }
        }
        matches("(?s)```(?:mermaid)\\s*\\n(.*?)```", kind: .diagram)
        matches("(?s)```(?:latex|tex|math)\\s*\\n(.*?)```", kind: .equation)
        matches(#"(?s)\$\$(.*?)\$\$"#, kind: .equation)
        matches(#"(?s)\\\[(.*?)\\\]"#, kind: .equation)
        matches(#"(?s)\\\((.*?)\\\)"#, kind: .equation)
        // Codex may remove Markdown fences when displaying code blocks.
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var graph: [String] = []
        for line in lines + [""] {
            let start = ["graph ", "flowchart ", "sequenceDiagram", "classDiagram", "stateDiagram", "erDiagram", "gantt", "pie ", "mindmap", "timeline"].contains { line.hasPrefix($0) }
            if start {
                if !graph.isEmpty { append(.diagram, graph.joined(separator: "\n")) }
                graph = [line]
            } else if !graph.isEmpty {
                if line.isEmpty || line.hasPrefix("›") || line == "```" {
                    append(.diagram, graph.joined(separator: "\n")); graph = []
                } else { graph.append(line) }
            }
        }
        return result
    }
}

/// Page and zoom commands for a mounted `RelayPDFPreview`; state is read back from PDFKit.
@MainActor final class RelayPDFController: ObservableObject {
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    fileprivate weak var view: PDFView?
    var canGoBack: Bool { pageIndex > 0 }
    var canGoForward: Bool { pageIndex + 1 < pageCount }
    func previous() { view?.goToPreviousPage(nil) }
    func next() { view?.goToNextPage(nil) }
    func zoomIn() { zoom(by: 1.25) }
    func zoomOut() { zoom(by: 0.8) }
    func fit() { view?.autoScales = true }
    private func zoom(by factor: CGFloat) {
        guard let view else { return }
        let current = view.scaleFactor
        view.autoScales = false
        view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, current * factor))
    }
    fileprivate func sync() {
        guard let view, let document = view.document else { pageIndex = 0; pageCount = 0; return }
        pageCount = document.pageCount
        pageIndex = view.currentPage.map { document.index(for: $0) } ?? 0
    }
}

struct RelayPDFPreview: NSViewRepresentable {
    let data: Data
    var controller: RelayPDFController? = nil
    @MainActor final class Coordinator: NSObject {
        var data = Data()
        weak var controller: RelayPDFController?
        @objc func pageChanged(_ note: Notification) {
            Task { @MainActor [weak controller] in controller?.sync() }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true
        view.minScaleFactor = 0.1; view.maxScaleFactor = 8
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged, object: view)
        attach(view, context: context)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.data != data {
            context.coordinator.data = data; view.document = PDFDocument(data: data)
            Task { @MainActor [weak controller] in controller?.sync() }
        }
        if let controller, context.coordinator.controller !== controller || controller.view !== view { attach(view, context: context) }
    }
    private func attach(_ view: PDFView, context: Context) {
        context.coordinator.controller = controller
        controller?.view = view
        Task { @MainActor [weak controller] in controller?.sync() }
    }
}

struct RelayPaneRichContentView: View {
    @ObservedObject var pane: PaneModel
    @State private var source = ""
    @State private var kind: RelaySurfaceContent.Kind = .diagram
    @State private var path = ""
    @State private var failure: String?
    @State private var preview: RelaySurfaceContent?
    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
            HStack {
                Text("Rich content · \(pane.displayName)").font(.headline)
                Spacer()
                Button("Refresh saved content") { RelaySurfacePublication.shared.refresh(pane) }
                Button("Read pane output") {
                    pane.richContentExplicit = false
                    if let text = pane.runtime.sidePanelViewportText() {
                        pane.richContents = RelayRichContentDetector.detect(text)
                    }
                }
            }
            if let error = pane.durableSurfaceError {
                Text(error).foregroundStyle(.secondary).font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(16)) {
                    ForEach(pane.presentedRichContents.indices, id: \.self) { i in
                        RelaySurfaceView(content: pane.presentedRichContents[i])
                        Divider()
                    }
                    if let artifact = pane.artifacts.last {
                        Text(artifact.filename).font(.headline)
                        if artifact.isPDF { RelayPDFPreview(data: artifact.data).frame(height: 420) }
                        else if let image = artifact.image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 420) }
                    }
                    if let preview { RelaySurfaceView(content: preview) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Render source") {
                Picker("Format", selection: $kind) {
                    Text("Mermaid").tag(RelaySurfaceContent.Kind.diagram)
                    Text("LaTeX").tag(RelaySurfaceContent.Kind.equation)
                    Text("Markdown").tag(RelaySurfaceContent.Kind.markdown)
                }
                TextEditor(text: $source).font(RelayTheme.font(.body, design: .monospaced)).frame(height: 110)
                Button("Render") {
                    let candidate = RelaySurfaceContent(kind: kind, text: source)
                    do { try candidate.validate(); preview = candidate; failure = nil }
                    catch { failure = "Source exceeds limits or contains unsupported directives." }
                }
            }
            HStack {
                TextField("PNG, JPEG, SVG or PDF path on this pane’s host", text: $path)
                Button("Open artifact") {
                    let resolved = TerminalPathSyntax.resolving(path, against: pane.directory ?? "/")
                    guard TerminalLinkResolver.imageExtensions.contains(TerminalPathSyntax.pathExtension(resolved)) else {
                        failure = "Choose PNG, JPEG, SVG or PDF."; return
                    }
                    Task { @MainActor in
                        do {
                            let bytes = try await RemoteArtifactLoader.load(path: resolved, profile: pane.profile)
                            pane.receivedArtifact(path: resolved, data: bytes); failure = nil
                        } catch { failure = error.localizedDescription }
                    }
                }.disabled(path.isEmpty)
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            Text("Detects Mermaid blocks and LaTeX delimited by $$, \\[ … \\], or \\( … \\). Source remains available.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(RelayTheme.spacing(20)).frame(minWidth: 680, minHeight: 600)
    }
}

@MainActor
final class RelayRichContentWindow {
    static let shared = RelayRichContentWindow()
    private var windows: [UUID: NSWindow] = [:]
    func show(pane: PaneModel) {
        if let window = windows[pane.id] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Rich content · " + pane.displayName
        RelayToolSurface.configure(window)
        window.minSize = NSSize(width: 680, height: 600)
        window.contentView = NSHostingView(rootView: RelayPaneRichContentView(pane: pane)
            .relaySurface())
        windows[pane.id] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

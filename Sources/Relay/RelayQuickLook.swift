import AppKit
import Quartz
import SwiftUI
import WebKit

/// A link or path seen in a terminal pane, before it is resolved for preview.
enum RelayQuickLookTarget: Equatable, Sendable {
    case web(URL)
    case path(String)
}

/// Finds URLs and file paths in a pane's visible text. Pure: no file system
/// access, so a path is offered whether or not it exists.
enum RelayQuickLookLinks {
    static let defaultLimit = 50

    /// Every target in `text`, in reading order, without duplicates.
    static func extract(text: String, limit: Int = defaultLimit) -> [RelayQuickLookTarget] {
        var found: [RelayQuickLookTarget] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            for token in tokens(in: String(line)) {
                guard let target = classify(token.text) else { continue }
                guard seen.insert(key(target)).inserted else { continue }
                found.append(target)
                if found.count >= limit { return found }
            }
        }
        return found
    }

    /// The viewport cell under a point measured from the top-left corner.
    static func cell(at point: CGPoint, origin: CGPoint, cellSize: CGSize) -> (row: Int, column: Int)? {
        guard cellSize.width > 0, cellSize.height > 0, point.x.isFinite, point.y.isFinite,
              point.x >= origin.x, point.y >= origin.y else { return nil }
        return (Int(floor((point.y - origin.y) / cellSize.height)), Int(floor((point.x - origin.x) / cellSize.width)))
    }

    /// The target whose text covers `column` (0-based, one per character).
    static func target(in line: String, column: Int) -> RelayQuickLookTarget? {
        tokens(in: line).first { $0.columns.contains(column) }.flatMap { classify($0.text) }
    }

    /// A target from a link Ghostty reported under the pointer: a URL, a
    /// Relay-encoded file link or a plain path.
    static func target(fromLink link: String) -> RelayQuickLookTarget? {
        switch TerminalLinkResolver.target(from: link) {
        case .web(let url): return ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .web(url) : nil
        case .image(let path), .file(let path): return .path(path)
        case nil: return classify(link)
        }
    }

    struct Token: Equatable {
        let text: String
        let columns: Range<Int>
    }

    /// Whitespace-separated words of one line. A provider command row
    /// ("/review - review changes") contributes nothing: its first word
    /// is a command, not a file.
    static func tokens(in line: String) -> [Token] {
        if line.trimmingCharacters(in: .whitespaces)
            .range(of: #"^/[A-Za-z][A-Za-z0-9_-]*\s+[-–—]\s+\S"#, options: .regularExpression) != nil {
            return []
        }
        var tokens: [Token] = []
        var start: Int?
        var current = ""
        for (index, character) in line.enumerated() {
            if character.isWhitespace {
                if let begin = start { tokens.append(Token(text: current, columns: begin..<index)) }
                start = nil
                current = ""
            } else {
                if start == nil { start = index }
                current.append(character)
            }
        }
        if let begin = start { tokens.append(Token(text: current, columns: begin..<(begin + current.count))) }
        return tokens
    }

    private static let opening = CharacterSet(charactersIn: "([{<\"'`")
    private static let closing = CharacterSet(charactersIn: ")]}>\"'`.,;:!?")
    private static let pathCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+@~/%=,")

    static func classify(_ raw: String) -> RelayQuickLookTarget? {
        var text = Substring(raw)
        // Markdown "[label](https://...)" and "see:https://..." put the URL
        // inside a longer word.
        if let scheme = text.range(of: "https://") ?? text.range(of: "http://") {
            text = text[scheme.lowerBound...]
        }
        while let first = text.unicodeScalars.first, opening.contains(first) { text = text.dropFirst() }
        while let last = text.unicodeScalars.last, closing.contains(last) { text = text.dropLast() }
        guard !text.isEmpty, text.count <= 4096 else { return nil }
        let word = String(text)

        if word.hasPrefix("http://") || word.hasPrefix("https://") {
            guard let url = URL(string: word), let host = url.host, !host.isEmpty else { return nil }
            return .web(url)
        }
        let path = word.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
        guard !path.isEmpty, path.unicodeScalars.allSatisfy(pathCharacters.contains),
              !path.contains("//") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let hasExtension = components.last.map { last in
            last.range(of: #"^[^.].*\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
        } ?? false
        if path.hasPrefix("/") {
            // "/review" is far more often a slash command than a file.
            return components.count >= 2 || hasExtension ? .path(path) : nil
        }
        if path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../") {
            return components.count >= 2 ? .path(path) : nil
        }
        // A bare relative path needs a folder and an extension, so that
        // "and/or", "km/h" and dates are not offered.
        if components.count >= 2, hasExtension, !path.hasPrefix("~"),
           components.first.map({ !$0.contains(".") || $0.hasPrefix(".") }) == true {
            return .path(path)
        }
        return nil
    }

    private static func key(_ target: RelayQuickLookTarget) -> String {
        switch target {
        case .web(let url): "web:" + url.absoluteString
        case .path(let path): "path:" + path
        }
    }
}

/// Where a pane's files live.
enum RelayQuickLookLocation: Equatable, Sendable {
    /// This Mac's file system.
    case local(cwd: String?)
    /// A relayd host; the host resolves "~/" and relative paths against cwd.
    case remote(ConnectionProfile, cwd: String?)
    /// A host Relay cannot read files from: only URLs are previewed.
    case unreadable
}

struct RelayQuickLookItem: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case web(URL)
        case localFile(String)
        case remoteFile(ConnectionProfile, path: String, cwd: String?)
    }

    let source: Source
    /// What a plain click on the same link would open.
    let openLink: String

    var title: String {
        switch source {
        case .web(let url):
            let path = url.path == "/" ? "" : url.path
            return (url.host ?? url.absoluteString) + path
        case .localFile(let path), .remoteFile(_, let path, _):
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        }
    }

    var subtitle: String {
        switch source {
        case .web(let url): url.absoluteString
        case .localFile(let path): "This Mac · " + path
        case .remoteFile(let profile, let path, _): profile.host + " · " + path
        }
    }

    /// Resolves a target for `location`; nil when it cannot be previewed
    /// there (a relative path without a known folder, or a file on a host
    /// Relay cannot read).
    static func resolve(_ target: RelayQuickLookTarget, location: RelayQuickLookLocation,
                        home: String = NSHomeDirectory()) -> RelayQuickLookItem? {
        switch target {
        case .web(let url):
            return RelayQuickLookItem(source: .web(url), openLink: url.absoluteString)
        case .path(let path):
            switch location {
            case .unreadable:
                return nil
            case .local(let cwd):
                guard let absolute = absolutePath(path, cwd: cwd, home: home) else { return nil }
                return RelayQuickLookItem(source: .localFile(absolute), openLink: absolute)
            case .remote(let profile, let cwd):
                let isRelative = !path.hasPrefix("/") && !path.hasPrefix("~/")
                let directory = cwd.flatMap { $0.hasPrefix("/") ? $0 : nil }
                if isRelative && directory == nil { return nil }
                let link = isRelative ? TerminalPathSyntax.resolving(path, against: directory!) : path
                return RelayQuickLookItem(source: .remoteFile(profile, path: path, cwd: directory), openLink: link)
            }
        }
    }

    static func absolutePath(_ path: String, cwd: String?, home: String) -> String? {
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        if path.hasPrefix("~/") { return ((home as NSString).appendingPathComponent(String(path.dropFirst(2))) as NSString).standardizingPath }
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        return ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }
}

/// The items one Quick Look panel steps through.
struct RelayQuickLookBrowser: Equatable {
    private(set) var items: [RelayQuickLookItem]
    private(set) var index: Int

    init?(items: [RelayQuickLookItem], start: Int = 0) {
        guard !items.isEmpty else { return nil }
        self.items = items
        index = min(max(start, 0), items.count - 1)
    }

    var current: RelayQuickLookItem { items[index] }
    var position: String { items.count == 1 ? "" : "\(index + 1) of \(items.count)" }
    mutating func next() { index = (index + 1) % items.count }
    mutating func previous() { index = (index + items.count - 1) % items.count }
}

/// A private folder for copies of remote files, removed with its panel.
final class RelayQuickLookStaging: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var counter = 0

    static let prefix = "relay-quicklook-"

    /// Only one panel exists, so any other staging folder was left by a quit
    /// or restart while a panel was open; it is removed first.
    init(parent: URL = FileManager.default.temporaryDirectory) throws {
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in leftovers where name.hasPrefix(Self.prefix) {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
        directory = parent.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    /// Writes `data` under the remote file's own name, so Quick Look picks
    /// the viewer from its extension. Each copy gets its own subfolder.
    func write(_ data: Data, remotePath: String) throws -> URL {
        lock.lock(); counter += 1; let slot = counter; lock.unlock()
        let folder = directory.appendingPathComponent(String(slot), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(Self.sanitizedName(remotePath))
        try data.write(to: url, options: [.withoutOverwriting])
        return url
    }

    static func sanitizedName(_ path: String) -> String {
        var name = String((path as NSString).lastPathComponent.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7F && $0 != "/" && $0 != ":" }
            .map(Character.init))
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 {
            let ext = (name as NSString).pathExtension
            let stem = String((name as NSString).deletingPathExtension.prefix(ext.isEmpty ? 120 : 110))
            name = ext.isEmpty ? stem : stem + "." + ext
        }
        return name.isEmpty ? "file" : name
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// What the panel shows for the current item.
enum RelayQuickLookContent: Equatable {
    case loading
    case file(URL)
    case web(URL)
    case failed(String)
}

/// One floating panel at a time, shared by every pane.
@MainActor
final class RelayQuickLookController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = RelayQuickLookController()

    @Published private(set) var browser: RelayQuickLookBrowser?
    @Published private(set) var content: RelayQuickLookContent = .loading
    private var panel: RelayQuickLookPanel?
    private var staging: RelayQuickLookStaging?
    private var staged: [Int: URL] = [:]
    private var load: Task<Void, Never>?
    private var keyMonitor: Any?
    private weak var returnFocus: NSView?
    private var open: ((String) -> Void)?

    func present(_ items: [RelayQuickLookItem], start: Int, returnFocus: NSView?, open: @escaping (String) -> Void) {
        guard let browser = RelayQuickLookBrowser(items: items, start: start) else { NSSound.beep(); return }
        closeContent()
        self.browser = browser
        self.returnFocus = returnFocus
        self.open = open
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            if let window = returnFocus?.window {
                let frame = window.frame
                panel.setFrame(NSRect(x: frame.midX - 360, y: frame.midY - 260, width: 720, height: 560), display: false)
            } else {
                panel.center()
            }
        }
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        showCurrent()
    }

    func next() { browser?.next(); showCurrent() }
    func previous() { browser?.previous(); showCurrent() }

    func openCurrent() {
        guard let item = browser?.current else { return }
        let open = self.open
        close()
        open?(item.openLink)
    }

    func close() {
        panel?.orderOut(nil)
        closeContent()
        browser = nil
        if let view = returnFocus { view.window?.makeFirstResponder(view) }
        returnFocus = nil
        open = nil
    }

    func windowWillClose(_ notification: Notification) {
        closeContent()
        browser = nil
        open = nil
        if let view = returnFocus { view.window?.makeFirstResponder(view) }
        returnFocus = nil
    }

    private func closeContent() {
        load?.cancel(); load = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        staging?.remove(); staging = nil
        staged = [:]
        content = .loading
    }

    private func showCurrent() {
        guard let browser else { return }
        load?.cancel()
        let index = browser.index
        switch browser.current.source {
        case .web(let url):
            content = .web(url)
        case .localFile(let path):
            var directory: ObjCBool = false
            content = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                ? .file(URL(fileURLWithPath: path, isDirectory: directory.boolValue))
                : .failed("No such file on this Mac: " + path)
        case .remoteFile(let profile, let path, let cwd):
            if let url = staged[index] { content = .file(url); return }
            content = .loading
            load = Task { @MainActor [weak self] in
                do {
                    let data = try await RelayHostFiles.file(path: path, cwd: cwd, profile: profile)
                    guard let self, !Task.isCancelled, self.browser?.index == index else { return }
                    if self.staging == nil { self.staging = try RelayQuickLookStaging() }
                    let url = try self.staging!.write(data, remotePath: path)
                    self.staged[index] = url
                    self.content = .file(url)
                } catch {
                    guard let self, !Task.isCancelled, self.browser?.index == index else { return }
                    self.content = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Left/Right step through the items; Escape and Space close; Return
    /// opens the item as a plain click would. Up/Down scroll the content.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers.isEmpty else { return event }
            switch event.keyCode {
            case 123: self.previous(); return nil
            case 124: self.next(); return nil
            case 53, 49: self.close(); return nil
            case 36, 76: self.openCurrent(); return nil
            default: return event
            }
        }
    }

    private func makePanel() -> RelayQuickLookPanel {
        let panel = RelayQuickLookPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: true)
        panel.title = "Quick Look"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 240)
        panel.delegate = self
        RelayTheme.configureAppearance(panel)
        panel.contentView = NSHostingView(rootView: RelayQuickLookView(controller: self))
        return panel
    }
}

final class RelayQuickLookPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct RelayQuickLookView: View {
    @ObservedObject var controller: RelayQuickLookController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(RelayTheme.line)
            ZStack {
                RelayTheme.canvas
                switch controller.content {
                case .loading:
                    ProgressView().controlSize(.small)
                case .file(let url):
                    RelayQuickLookFileView(url: url)
                case .web(let url):
                    RelayQuickLookWebView(url: url)
                case .failed(let message):
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(RelayTheme.warning)
                        Text("Can't preview this item").foregroundStyle(RelayTheme.text)
                        Text(message).font(.caption).foregroundStyle(RelayTheme.textMuted)
                            .multilineTextAlignment(.center).textSelection(.enabled)
                    }
                    .padding(24)
                }
            }
        }
        .background(RelayTheme.canvas)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.browser?.current.title ?? "")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(RelayTheme.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(controller.browser?.current.subtitle ?? "")
                    .font(.system(size: 10)).foregroundStyle(RelayTheme.textFaint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let position = controller.browser?.position, !position.isEmpty {
                Text(position).font(.system(size: 11).monospacedDigit()).foregroundStyle(RelayTheme.textMuted)
                Button { controller.previous() } label: { Image(systemName: "chevron.left") }
                    .help("Previous (←)")
                Button { controller.next() } label: { Image(systemName: "chevron.right") }
                    .help("Next (→)")
            }
            Button("Open") { controller.openCurrent() }.help("Open as a click would (Return)")
            Button { controller.close() } label: { Image(systemName: "xmark") }.help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(RelayTheme.textMuted)
        .padding(.leading, 76).padding(.trailing, 12).padding(.vertical, 8)
        .background(RelayTheme.surface)
    }
}

/// macOS Quick Look for any file type it knows (text, code, images, PDF,
/// media, documents, folders).
struct RelayQuickLookFileView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

/// A web page, loaded only on request, with no cookies or storage kept.
struct RelayQuickLookWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != url {
            context.coordinator.loaded = url
            view.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(loaded: url) }
    final class Coordinator { var loaded: URL; init(loaded: URL) { self.loaded = loaded } }
}

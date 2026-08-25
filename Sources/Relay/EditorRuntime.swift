import AppKit
import Foundation
import SwiftUI
import WebKit

struct RemoteFileEntry: Decodable, Identifiable, Sendable {
    let name: String
    let path: String
    let directory: Bool
    let symbolicLink: Bool
    let size: Int64
    let modificationNS: Int64

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path, directory, size
        case symbolicLink = "symbolic_link"
        case modificationNS = "modification_ns"
    }
}

private struct RemoteWorkspaceInfo: Decodable, Sendable { let path: String }

private struct RemoteFileDocument: Decodable, Sendable {
    let path: String
    let contentBase64: String
    let modificationNS: Int64
    let mode: UInt32

    var text: String? {
        guard let data = Data(base64Encoded: contentBase64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    enum CodingKeys: String, CodingKey {
        case path, mode
        case contentBase64 = "content_base64"
        case modificationNS = "modification_ns"
    }
}

private struct RemoteGitDiff: Decodable, Sendable {
    let originalLabel: String
    let originalBase64: String
    let modified: RemoteFileDocument

    var originalText: String? {
        guard let data = Data(base64Encoded: originalBase64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    enum CodingKeys: String, CodingKey {
        case modified
        case originalLabel = "original_label"
        case originalBase64 = "original_base64"
    }
}

private enum RemoteFileError: LocalizedError {
    case unavailable(String)
    case invalidResponse
    case missingResources

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .invalidResponse: "The remote file service returned an invalid response"
        case .missingResources: "Relay's editor resources are missing"
        }
    }
}

struct EditorTypography: Equatable, Sendable {
    let fontFamily: String
    let fontSize: Double

    init(fontFamily: String, fontSize: Double) {
        let family = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fontFamily = family.isEmpty ? "Menlo" : family
        self.fontSize = min(max(fontSize, 9), 32)
    }

    var javascriptArgument: String? {
        let payload: [String: Any] = ["fontFamily": fontFamily, "fontSize": fontSize]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
final class RemoteEditorRuntime: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published private(set) var workspacePath = ""
    @Published private(set) var directoryPath = ""
    @Published private(set) var entries: [RemoteFileEntry] = []
    @Published private(set) var currentPath: String?
    @Published private(set) var isDirty = false
    @Published private(set) var isDiff = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Starting editor…"
    @Published private(set) var operationError: String?
    @Published var navigatorVisible = true

    private weak var pane: PaneModel?
    private var started = false
    private var generation = 0
    private var webReady = false
    private var currentModificationNS: Int64 = 0
    private var savedContent = ""
    private var diffOriginalContent: String?
    private var diffOriginalLabel: String?
    private var appliedTypography: EditorTypography?
    private var workTask: Task<Void, Never>?
    private lazy var scriptHandler = WeakEditorScriptHandler(owner: self)
    private(set) lazy var webView = makeWebView()

    init(pane: PaneModel) {
        self.pane = pane
        super.init()
    }

    func startIfNeeded() {
        guard !started, let pane else { return }
        guard pane.profile.kind == .ssh, pane.profile.backend == .relay else {
            pane.disconnected("The quick editor requires a Relay-managed remote pane")
            return
        }
        started = true
        generation += 1
        let currentGeneration = generation
        pane.reconnecting()
        loadEditorPageIfNeeded()
        let profile = pane.profile
        let parentSessionID = pane.remoteParentSessionID
        isBusy = true
        status = "Finding remote workspace…"
        workTask = Task { [weak self] in
            do {
                let workspace = try await Task.detached(priority: .userInitiated) {
                    try Self.remoteJSON(
                        RemoteWorkspaceInfo.self,
                        profile: profile,
                        arguments: ["files", "workspace"] + (parentSessionID.map { ["--parent-session", $0] } ?? [])
                    )
                }.value
                guard let self, self.started, self.generation == currentGeneration else { return }
                self.workspacePath = workspace.path
                self.directoryPath = workspace.path
                self.pane?.directory = workspace.path
                self.pane?.connected()
                self.isBusy = false
                self.status = workspace.path
                self.loadDirectory(workspace.path)
                if let request = self.pane?.editorRequest { self.open(request) }
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.isBusy = false
                self.started = false
                self.pane?.disconnected(error.localizedDescription)
            }
        }
    }

    func stop() {
        generation += 1
        started = false
        workTask?.cancel()
        workTask = nil
        webView.stopLoading()
    }

    func restart() {
        stop()
        operationError = nil
        pane?.reconnecting()
        startIfNeeded()
    }

    func focus() {
        if let pane { NotificationCenter.default.post(name: .relaySelectPane, object: pane.id) }
        webView.window?.makeFirstResponder(webView)
    }

    func loadDirectory(_ path: String) {
        guard let pane else { return }
        let profile = pane.profile
        let currentGeneration = generation
        isBusy = true
        status = "Loading \(URL(fileURLWithPath: path).lastPathComponent)…"
        operationError = nil
        workTask = Task { [weak self] in
            do {
                let listed = try await Task.detached(priority: .userInitiated) {
                    try Self.remoteJSON(
                        [RemoteFileEntry].self,
                        profile: profile,
                        arguments: ["files", "list", "--path-b64", Self.pathArgument(path)]
                    )
                }.value
                guard let self, self.started, self.generation == currentGeneration else { return }
                self.directoryPath = path
                self.entries = listed
                self.isBusy = false
                self.status = path
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.isBusy = false
                self.operationError = error.localizedDescription
                self.status = "Could not list folder"
            }
        }
    }

    func openEntry(_ entry: RemoteFileEntry) {
        if entry.directory {
            loadDirectory(entry.path)
        } else {
            let request = EditorOpenRequest(paths: [entry.path], diff: false)
            pane?.editorRequest = request
            open(request)
        }
    }

    func goUp() {
        guard !directoryPath.isEmpty, directoryPath != workspacePath else { return }
        let parent = URL(fileURLWithPath: directoryPath).deletingLastPathComponent().path
        guard parent == workspacePath || parent.hasPrefix(workspacePath + "/") else { return }
        loadDirectory(parent)
    }

    func open(_ request: EditorOpenRequest) {
        pane?.editorRequest = request
        guard started, let pane else {
            startIfNeeded()
            return
        }
        guard !request.paths.isEmpty else { return }
        let profile = pane.profile
        let currentGeneration = generation
        isBusy = true
        operationError = nil
        status = request.diff ? "Loading diff…" : "Opening file…"
        workTask = Task { [weak self] in
            do {
                if request.diff && request.paths.count == 1 {
                    let diff = try await Task.detached(priority: .userInitiated) {
                        try Self.remoteJSON(
                            RemoteGitDiff.self,
                            profile: profile,
                            arguments: ["files", "git-diff", "--path-b64", Self.pathArgument(request.paths[0])]
                        )
                    }.value
                    guard let self, self.generation == currentGeneration,
                          let original = diff.originalText, let modified = diff.modified.text else {
                        throw RemoteFileError.invalidResponse
                    }
                    self.showDiff(original: original, originalLabel: diff.originalLabel, modified: modified, document: diff.modified)
                } else if request.diff && request.paths.count == 2 {
                    let documents = try await Task.detached(priority: .userInitiated) {
                        try request.paths.map { path in
                            try Self.remoteJSON(
                                RemoteFileDocument.self,
                                profile: profile,
                                arguments: ["files", "read", "--path-b64", Self.pathArgument(path)]
                            )
                        }
                    }.value
                    guard let self, self.generation == currentGeneration,
                          let original = documents[0].text, let modified = documents[1].text else {
                        throw RemoteFileError.invalidResponse
                    }
                    self.showDiff(original: original, originalLabel: documents[0].path, modified: modified, document: documents[1])
                } else {
                    let document = try await Task.detached(priority: .userInitiated) {
                        try Self.remoteJSON(
                            RemoteFileDocument.self,
                            profile: profile,
                            arguments: ["files", "read", "--path-b64", Self.pathArgument(request.paths[0])]
                        )
                    }.value
                    guard let self, self.generation == currentGeneration, let text = document.text else {
                        throw RemoteFileError.invalidResponse
                    }
                    self.showDocument(document, text: text)
                }
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.isBusy = false
                self.operationError = error.localizedDescription
                self.status = "Open failed"
            }
        }
    }

    func requestSave() {
        webView.evaluateJavaScript("window.relayRequestSave && window.relayRequestSave()")
    }

    func toggleDiff() {
        webView.evaluateJavaScript("window.relayToggleLocalDiff && window.relayToggleLocalDiff()")
    }

    func applyTypography(_ typography: EditorTypography, force: Bool = false) {
        guard webReady, force || typography != appliedTypography,
              let json = typography.javascriptArgument else { return }
        appliedTypography = typography
        webView.evaluateJavaScript("window.relaySetTypography && window.relaySetTypography(\(json))")
    }

    private func applyCurrentTypography(force: Bool = false) {
        let preferences = RelayPreferences.shared
        applyTypography(
            EditorTypography(fontFamily: preferences.fontFamily, fontSize: preferences.fontSize),
            force: force
        )
    }

    private func save(content: String) {
        guard let pane, let path = currentPath else { return }
        let profile = pane.profile
        let expectedModificationNS = currentModificationNS
        let currentGeneration = generation
        isBusy = true
        status = "Saving…"
        operationError = nil
        workTask = Task { [weak self] in
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try Self.remoteJSON(
                        RemoteFileDocument.self,
                        profile: profile,
                        arguments: [
                            "files", "write", "--path-b64", Self.pathArgument(path),
                            "--expected-modification-ns", String(expectedModificationNS)
                        ],
                        input: Data(content.utf8)
                    )
                }.value
                guard let self, self.generation == currentGeneration else { return }
                self.currentModificationNS = document.modificationNS
                self.savedContent = content
                self.isDirty = false
                self.isBusy = false
                self.status = "Saved"
                _ = try? await self.webView.evaluateJavaScript("window.relayMarkSaved && window.relayMarkSaved()")
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.isBusy = false
                self.operationError = error.localizedDescription
                self.status = "Save failed"
            }
        }
    }

    private func showDocument(_ document: RemoteFileDocument, text: String) {
        currentPath = document.path
        currentModificationNS = document.modificationNS
        savedContent = text
        diffOriginalContent = nil
        diffOriginalLabel = nil
        isDirty = false
        isDiff = false
        isBusy = false
        status = document.path
        pane?.title = URL(fileURLWithPath: document.path).lastPathComponent
        deliverCurrentDocument()
    }

    private func showDiff(original: String, originalLabel: String, modified: String, document: RemoteFileDocument) {
        currentPath = document.path
        currentModificationNS = document.modificationNS
        savedContent = modified
        diffOriginalContent = original
        diffOriginalLabel = originalLabel
        isDirty = false
        isDiff = true
        isBusy = false
        status = "Comparing changes"
        pane?.title = URL(fileURLWithPath: document.path).lastPathComponent
        deliverCurrentDocument()
    }

    private func deliverCurrentDocument() {
        guard webReady, let path = currentPath else { return }
        var payload: [String: Any] = [
            "path": path, "language": Self.language(for: path), "content": savedContent, "diff": isDiff
        ]
        if let diffOriginalContent { payload["original"] = diffOriginalContent }
        if let diffOriginalLabel { payload["originalLabel"] = diffOriginalLabel }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.relayOpenDocument(\(json))")
    }

    private func loadEditorPageIfNeeded() {
        guard webView.url == nil else { return }
        guard let indexURL = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Editor") else {
            pane?.disconnected(RemoteFileError.missingResources.localizedDescription)
            return
        }
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    }

    private func makeWebView() -> RelayEditorWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(scriptHandler, name: "relay")
        let view = RelayEditorWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.owner = self
        view.allowsMagnification = true
        view.underPageBackgroundColor = NSColor(red: 0.094, green: 0.094, blue: 0.094, alpha: 1)
        view.setAccessibilityLabel("Remote file editor")
        return view
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            webReady = true
            appliedTypography = nil
            applyCurrentTypography(force: true)
            deliverCurrentDocument()
        case "dirty":
            let dirty = body["dirty"] as? Bool ?? true
            if isDirty != dirty { isDirty = dirty }
        case "save":
            if let content = body["content"] as? String { save(content: content) }
        case "mode": isDiff = body["diff"] as? Bool ?? false
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        operationError = error.localizedDescription
    }

    nonisolated private static func pathArgument(_ path: String) -> String {
        Data(path.utf8).base64EncodedString()
    }

    nonisolated private static func remoteJSON<T: Decodable>(
        _ type: T.Type,
        profile: ConnectionProfile,
        arguments commandArguments: [String],
        input: Data? = nil
    ) throws -> T {
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = ["-T", "-o", "ControlMaster=no", "-o", "ControlPath=~/.ssh/relay-%C"]
        arguments += profile.sshConnectionArguments
        arguments += ["~/.local/bin/relayd"] + commandArguments
        ssh.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        ssh.standardOutput = output
        ssh.standardError = errors
        if input != nil {
            let writer = Pipe()
            ssh.standardInput = writer
        } else {
            ssh.standardInput = FileHandle.nullDevice
        }
        let captured = try ProcessCapture.run(ssh, output: output, errors: errors, input: input)
        let outputData = captured.standardOutput
        let errorData = captured.standardError
        guard ssh.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.split(separator: "\n").last.map(String.init)
                ?? "Remote file operation failed"
            throw RemoteFileError.unavailable(message)
        }
        guard let decoded = try? JSONDecoder().decode(type, from: outputData) else {
            throw RemoteFileError.invalidResponse
        }
        return decoded
    }

    nonisolated private static func language(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": "swift"
        case "go": "go"
        case "rs": "rust"
        case "py", "pyw": "python"
        case "r", "rmd": "r"
        case "js", "mjs", "cjs", "jsx": "javascript"
        case "ts", "mts", "cts", "tsx": "typescript"
        case "json", "jsonl": "json"
        case "md", "markdown": "markdown"
        case "sh", "bash", "zsh": "shell"
        case "yaml", "yml": "yaml"
        case "toml": "ini"
        case "html", "htm": "html"
        case "css": "css"
        case "scss": "scss"
        case "sql": "sql"
        case "c", "h": "c"
        case "cc", "cpp", "cxx", "hpp": "cpp"
        case "java": "java"
        case "xml": "xml"
        default: "plaintext"
        }
    }
}

@MainActor
private final class WeakEditorScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: RemoteEditorRuntime?

    init(owner: RemoteEditorRuntime) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class RelayEditorWebView: WKWebView {
    weak var owner: RemoteEditorRuntime?

    override func mouseDown(with event: NSEvent) {
        owner?.focus()
        super.mouseDown(with: event)
    }
}

struct MonacoEditorSurface: NSViewRepresentable {
    @ObservedObject var runtime: RemoteEditorRuntime
    let typography: EditorTypography

    func makeNSView(context: Context) -> RelayEditorWebView {
        let view = runtime.webView
        Task { @MainActor in
            await Task.yield()
            runtime.startIfNeeded()
            runtime.applyTypography(typography)
        }
        return view
    }

    func updateNSView(_ nsView: RelayEditorWebView, context: Context) {
        Task { @MainActor in
            await Task.yield()
            runtime.startIfNeeded()
            runtime.applyTypography(typography)
        }
    }
}

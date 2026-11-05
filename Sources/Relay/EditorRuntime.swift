import AppKit
import Foundation
import CryptoKit
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
private struct RemoteFileSearchPage: Decodable, Sendable {
    let entries: [RemoteFileEntry]
    let truncated: Bool
    let warning: String?
}

private struct RemoteFileDocument: Decodable, Sendable {
    let path: String
    let contentBase64: String
    let modificationNS: Int64
    let mode: UInt32
    let directory: Bool?

    var text: String? {
        guard let data = Data(base64Encoded: contentBase64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    enum CodingKeys: String, CodingKey {
        case path, mode, directory
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

enum RemoteFileError: LocalizedError {
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
    @Published var searchQuery = ""
    @Published var includeUntrackedFiles = false
    @Published private(set) var searchResults: [RemoteFileEntry] = []
    @Published private(set) var searchStatus = ""
    private var searchRequestID = UUID()
    private var searchInFlight = false

    private weak var pane: PaneModel?
    var requestRunCode: ((String) throws -> Void)?
    // Native editor gestures only. MCP/agent submissions retain their approval path.
    var requestInterruptR: (() -> Bool)?
    @Published private(set) var rExecutedSource: String?
    var requestUserRCode: ((String) throws -> Void)?
    /// User-initiated setup only; never exposed as generic agent input.
    var prepareRSetup: (() throws -> ((String) throws -> Void))?
    var canAutomaticallyConnectR: (() -> Bool)?
    private var automaticRSetupTask: Task<Void, Never>?

    func connectRWorkspaceWhenReady() {
        automaticRSetupTask?.cancel()
        automaticRSetupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshRSession()
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                if self.rSession != nil { return }
                if self.canAutomaticallyConnectR?() == true {
                    self.requestRSetup(automatically: true)
                    return
                }
            }
            self.rSessionStatus = "Start radian in the linked console, then choose Connect R."
        }
    }
    @Published private(set) var rSetupInFlight = false
    @Published private(set) var rSession: RWorkspaceSession?
    @Published private(set) var rLastRequest: String?
    @Published var showsRResults = false
    @Published var rHelpTopic = ""
    @Published var rHelpRequestID = UUID()
    @Published var externalRResults = false
    @Published var rLivePlotsEnabled = true
    @Published private(set) var rSessionStatus = "R companion not connected"
    private var rSessionScopeRoot: String?
    private var stagedCompanionSession: String?
    var rArtifactRelative: String { "relay-results/" + (pane?.remoteParentSessionID ?? "editor") }
    private var rArtifactRoot: String? { rResultsScope.map { ($0.root as NSString).appendingPathComponent(rArtifactRelative) } }

    func requestRSetup(automatically: Bool = false) {
        guard !rSetupInFlight else { return }
        if automatically && canAutomaticallyConnectR?() != true { return }
        do {
            guard let root = rArtifactRoot, let scope = rResultsScope, let prepareRSetup else { throw PluginError.invalid("No linked R console") }
            let send = try prepareRSetup()
            let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/R/relay-r.R")
            let source = try Data(contentsOf: url)
            guard source.count <= 32768 else { throw PluginError.invalid("R companion exceeds setup limit") }
            rSetupInFlight = true
            rSessionStatus = "Installing R companion…"
            Task { @MainActor [weak self] in
                defer { self?.rSetupInFlight = false }
                do {
                    let path = try await Task.detached(priority: .userInitiated) {
                        try await Self.installRCompanion(source, scope: scope)
                    }.value
                    guard let self, self.rResultsScope == scope, self.rArtifactRoot == root else { return }
                    let digest = Insecure.MD5.hash(data: source).map { String(format: "%02x", $0) }.joined()
                    if automatically && self.canAutomaticallyConnectR?() != true {
                        throw PluginError.invalid("R console changed; connect again when its input is empty")
                    }
                    try send(RWorkspaceCommand.setupFile(path: path, md5: digest, root: root))
                    self.rSession = nil
                    self.rSessionScopeRoot = nil
                    self.rLivePlotsEnabled = true
                    self.rSessionStatus = "Connecting R; waiting for its session handshake"
                    // Explicit setup must complete even if the user returns to
                    // their agent app. Bounded metadata reads, never a resend.
                    for _ in 0..<10 {
                        try await Task.sleep(for: .milliseconds(500))
                        guard self.rResultsScope == scope, self.rArtifactRoot == root else { return }
                        self.refreshRSession()
                        if self.rSession != nil { break }
                    }
                } catch {
                    self?.operationError = error.localizedDescription
                    self?.rSessionStatus = "R setup failed: \(error.localizedDescription)"
                }
            }
        } catch { operationError = error.localizedDescription }
    }

    nonisolated private static func installRCompanion(_ source: Data, scope: PluginScope) async throws -> String {
        let hash = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let name = ".relay-r-\(hash).R"
        let expected = (scope.root as NSString).appendingPathComponent(name)
        if let existing = try? await remoteJSON(RemoteFileDocument.self, profile: scope.profile,
            arguments: ["files", "read", "--path-b64", pathArgument(expected)]),
           Data(base64Encoded: existing.contentBase64) == source { return existing.path }
        // Import never overwrites an existing file, including a tampered namesake.
        let entry = try await remoteJSON(RemoteFileEntry.self, profile: scope.profile,
            arguments: ["files", "import", "--path-b64", pathArgument(scope.root),
                        "--name-b64", pathArgument(name)], input: source)
        let verified = try await remoteJSON(RemoteFileDocument.self, profile: scope.profile,
            arguments: ["files", "read", "--path-b64", pathArgument(entry.path)])
        guard Data(base64Encoded: verified.contentBase64) == source else { throw PluginError.invalid("R companion verification failed") }
        return verified.path
    }

    func refreshRSession() {
        guard !rSessionRefreshInFlight, let scope = rResultsScope, let root = rArtifactRoot else { return }
        rSessionRefreshInFlight = true
        let requestID = UUID()
        rSessionRefreshID = requestID
        Task { @MainActor [weak self] in
            defer { self?.rSessionRefreshInFlight = false }
            do {
                let response = try await PluginOperationRunner.run(.artifacts, scope: scope, path: self?.rArtifactRelative.appending("/session.json") ?? "")
                guard let self, self.rSessionRefreshID == requestID,
                      self.rArtifactRoot == root, let bytes = response.verifiedBytes else { return }
                let session = try JSONDecoder().decode(RWorkspaceSession.self, from: bytes)
                let canonicalRoot = (response.root as NSString).appendingPathComponent(self.rArtifactRelative)
                try session.validate(root: canonicalRoot)
                let sameSession = self.rSession?.session_id == session.session_id
                self.rSession = session
                if !sameSession {
                    let record = UserDefaults.standard.dictionary(forKey: "relay.execution.presentation." + session.session_id)
                    self.rExecutedSource = record?["source"] as? String
                    self.rLastRequest = record?["request"] as? String
                }
                self.rSessionScopeRoot = root
                if !sameSession || self.rLastRequest == nil {
                    self.rSessionStatus = "R PID \(session.pid) on \(session.host) · saved handshake, not a liveness check"
                }
                if (session.companion_version ?? 0) < 3,
                   session.capabilities.contains("companion_updates"),
                   self.stagedCompanionSession != session.session_id {
                    self.stagedCompanionSession = session.session_id
                    self.stageCompanionUpdate(session: session, scope: scope)
                }
            } catch {
                guard let self, self.rSessionRefreshID == requestID,
                      self.rArtifactRoot == root else { return }
                // Local admission pressure says nothing about the remote handshake.
                // Keep the validated session; the next refresh will retry the read.
                if error is PluginOperationBudget.Failure { return }
                self.rSession = nil
                self.rSessionScopeRoot = nil
                self.rSessionStatus = "R handshake unavailable: \(error.localizedDescription)"
            }
        }
    }

    private var rSessionRefreshID = UUID()
    private func stageCompanionUpdate(session: RWorkspaceSession, scope: PluginScope) {
        Task { @MainActor [weak self] in
            do {
                let source = try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/R/relay-r.R"))
                try await Task.detached(priority: .utility) {
                    let path = try await Self.installRCompanion(source, scope: scope)
                    let digest = Insecure.MD5.hash(data: source).map { String(format: "%02x", $0) }.joined()
                    let data = try JSONSerialization.data(withJSONObject: ["session_id": session.session_id, "path": path, "md5": digest])
                    let destination = (session.artifact_root as NSString).appendingPathComponent("companion-update.json")
                    if let existing = try? await Self.remoteJSON(RemoteFileDocument.self, profile: scope.profile,
                        arguments: ["files", "read", "--path-b64", Self.pathArgument(destination)]) {
                        let _: RemoteFileDocument = try await Self.remoteJSON(RemoteFileDocument.self, profile: scope.profile,
                            arguments: ["files", "write", "--path-b64", Self.pathArgument(destination),
                                        "--expected-modification-ns", String(existing.modificationNS)], input: data)
                    } else {
                        let _: RemoteFileEntry = try await Self.remoteJSON(RemoteFileEntry.self, profile: scope.profile,
                            arguments: ["files", "import", "--path-b64", Self.pathArgument(session.artifact_root),
                                        "--name-b64", Self.pathArgument("companion-update.json")], input: data)
                    }
                }.value
                self?.rSessionStatus = "R companion update staged; applies after the current command"
            } catch { self?.operationError = "R companion update failed: " + error.localizedDescription }
        }
    }
    private var rSessionRefreshInFlight = false
    let rPlotConnection = RHttpgdConnection()
    let rPlotWindow = RPlotWindow()
    @Published private(set) var rEditorToolBusy = false
    private var rCompletionBusy = false

    private func requestRCompletion(_ request: Int, document: String) {
        guard !rCompletionBusy, document == documentID,
              let scope = rResultsScope, let identity = rSession?.session_id else {
            webView.evaluateJavaScript("window.relayComplete(\(request), null); void 0;")
            return
        }
        rCompletionBusy = true
        let path = rArtifactRelative + "/environment.json"
        Task { @MainActor in
            defer { rCompletionBusy = false }
            var payload = "null"
            if let response = try? await PluginOperationRunner.run(.artifacts, scope: scope, path: path),
               let bytes = response.verifiedBytes, bytes.count <= 2 * 1024 * 1024,
               let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               value["session_id"] as? String == identity,
               self.rSession?.session_id == identity, self.documentID == document,
               self.rResultsScope == scope {
                payload = String(decoding: bytes, as: UTF8.self)
            }
            _ = try? await webView.evaluateJavaScript("window.relayComplete(\(request), \(payload)); void 0;")
        }
    }

    func requestREditorTool(_ method: String, code: String, topic: String = "", completion: @escaping (Result<String, Error>) -> Void) {
        guard !rEditorToolBusy, ["format", "lint", "help"].contains(method),
              code.utf8.count <= 262144, topic.utf8.count <= 800,
              let scope = rResultsScope, let session = rSession,
              let executable = session.rscript, executable.hasPrefix("/"),
              executable.hasSuffix("/bin/Rscript"), !executable.contains("\0") else {
            completion(.failure(PluginError.invalid("Reconnect R to enable editor tools; wait for any current tool request")))
            return
        }
        rEditorToolBusy = true
        let identity = session.session_id
        Task { @MainActor in
            defer { rEditorToolBusy = false }
            do {
                let libraries = session.library_paths ?? []
                let payload = try JSONSerialization.data(withJSONObject: ["method": method, "code": code, "topic": topic, "libraries": libraries])
                let script = try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/R/editor-tools.R"))
                let result = try await Task.detached(priority: .userInitiated) {
                    let path = try await Self.installRCompanion(script, scope: scope)
                    let libs = libraries.joined(separator: ":")
                    let command = ["env", "R_LIBS=" + libs, executable, "--vanilla", path]
                        .map(ShellQuoting.quote).joined(separator: " ")
                    let captured = try await RelayHostExecution.capture(profile: scope.profile,
                        command: command, input: payload, timeout: 20, maximumBytes: 1 << 20)
                    guard captured.exitCode == 0 else { throw PluginError.invalid(String(decoding: captured.stderr.prefix(2048), as: UTF8.self)) }
                    let json = try JSONSerialization.jsonObject(with: captured.stdout) as? [String: Any]
                    if let error = json?["error"] as? String { throw PluginError.invalid(error) }
                    return String(decoding: captured.stdout, as: UTF8.self)
                }.value
                guard self.rSession?.session_id == identity, self.rResultsScope == scope else { throw PluginError.invalid("R session changed during editor operation") }
                completion(.success(result))
            } catch { completion(.failure(error)) }
        }
    }

    func requestREvaluation(_ code: String) throws {
        guard let session = rSession, let root = rArtifactRoot, root == rSessionScopeRoot, let requestRunCode else {
            throw PluginError.invalid("Set up the R companion and refresh its session before running code")
        }
        let id = UUID()
        try requestRunCode(RWorkspaceCommand.evaluate(code: code, id: id, root: session.artifact_root, session: session))
        rLastRequest = id.uuidString.lowercased()
        rSessionStatus = "Request \(id.uuidString.prefix(8)) proposed. Waiting for approval and R completion; results update automatically."
    }
    var rResultsScope: PluginScope? {
        guard let pane else { return nil }
        return try? PluginScope.captured(paneID: pane.id, profile: pane.profile,
                                         directory: pane.directory, operation: .artifacts)
    }
    private var started = false
    /// Test seams for the start path: a stand-in for relayd's workspace lookup
    /// and for the pause between its tries. Production leaves both alone.
    var workspaceLookupOverride: (@Sendable () async throws -> String)?
    var workspaceLookupSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    private var generation = 0
    private var webReady = false
    private var currentModificationNS: Int64 = 0
    private var documentID = UUID().uuidString
    private var editRevision: UInt64 = 0
    private var openRequestID = UUID()
    private var directoryRequestID = UUID()
    private var savingDocumentID: String?
    private var savedContent = ""
    private var recoveryContent: String?
    func controlSnapshot() -> EditorControlSnapshot {
        var snapshot = EditorControlSnapshot(documentID: documentID, revision: editRevision,
            path: currentPath, dirty: isDirty, diff: isDiff, busy: isBusy,
            text: recoveryContent)
        snapshot.rConsoleID = pane?.remoteParentSessionID
        snapshot.rSessionID = rSession?.session_id
        return snapshot
    }

    func pauseMCPAnalysis() {
        if let id = pane?.remoteParentSessionID.flatMap(UUID.init(uuidString:)) {
            _ = RAutomationController.shared.pause(id)
            rSessionStatus = "MCP analysis paused"
        }
    }

    func interruptRRun() {
        pauseMCPAnalysis()
        rSessionStatus = requestInterruptR?() == true ? "Interrupt requested; waiting for R acknowledgement" : "R interrupt could not be delivered"
    }

    func noteRExecutionError(_ error: Error) { operationError = error.localizedDescription }

    func fullDocumentRange() -> [String: Int]? {
        let snapshot = controlSnapshot()
        guard !snapshot.truncated, let content = snapshot.content else { return nil }
        let lines = content.components(separatedBy: "\n")
        return ["startLineNumber": 1, "startColumn": 1,
                "endLineNumber": lines.count, "endColumn": (lines.last?.utf16.count ?? 0) + 1]
    }

    func selectForMCP(document: String, revision: String, range: [String: Int], verifyDisk: Bool = false) async throws -> [String: Any] {
        let snapshot = controlSnapshot()
        guard snapshot.documentID == document, snapshot.revision == revision,
              !snapshot.busy, !snapshot.diff, !snapshot.truncated,
              let content = snapshot.content else {
            throw PluginError.invalid("Read the current editor document and revision before selecting code")
        }
        let baseline = savedContent
        if verifyDisk {
            guard let pane, let path = currentPath else { throw PluginError.invalid("No project file to verify") }
            let profile = pane.profile
            let disk = try await Task.detached(priority: .userInitiated) {
                try await Self.remoteJSON(RemoteFileDocument.self, profile: profile,
                    arguments: ["files", "read", "--path-b64", Self.pathArgument(path)])
            }.value
            guard disk.text == baseline else {
                throw PluginError.invalid("File changed on disk; refresh or resolve the editor before execution")
            }
            guard documentID == document, String(editRevision) == revision, savedContent == baseline else {
                throw PluginError.invalid("Editor changed during disk verification")
            }
        }
        let request: [String: Any] = ["documentID": document, "expectedContent": content, "range": range]
        let data = try JSONSerialization.data(withJSONObject: request)
        let result = try await webView.evaluateJavaScript("window.relaySelectForMCP(\(String(decoding: data, as: UTF8.self)))")
        guard documentID == document, String(editRevision) == revision,
              var selection = result as? [String: Any], let code = selection["code"] as? String,
              !code.isEmpty, code.utf8.count <= RWorkspaceCommand.maximumCodeBytes else {
            throw PluginError.invalid("Editor changed during selection")
        }
        let source = RExecutionSource(kind: content == baseline ? "editor" : "unsaved_editor",
            path: snapshot.path, documentID: document, revision: revision, range: range,
            documentSHA256: RExecutionSource.digest(content), codeSHA256: RExecutionSource.digest(code))
        selection["source"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))
        return selection
    }

    let mcpEdits = EditorMCPControl()

    func proposeMCPEdit(id: UUID, document: String, revision: String,
                        range: [String: Int]?, text: String?, saving: Bool) throws -> [String: Any] {
        let snapshot = controlSnapshot()
        guard snapshot.documentID == document, snapshot.revision == revision,
              !snapshot.busy, !snapshot.diff, !snapshot.truncated,
              let content = snapshot.content, let path = snapshot.path,
              saving || (range?.count == 4 && text != nil && text!.utf8.count <= 65536) else {
            throw PluginError.invalid("Read the current editable document and revision first")
        }
        var request: [String: Any] = ["documentID": document, "expectedContent": content, "save": saving]
        if !saving { request["range"] = range; request["text"] = text }
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let script = "window.relayEditForMCP(\(String(decoding: data, as: UTF8.self)))"
        let fingerprint = String(revision) + ":" + String(decoding: data, as: UTF8.self)
        let requestedGeneration = generation
        return try mcpEdits.propose(id: id, fingerprint: fingerprint, path: path,
                                    preview: saving ? content : (text ?? ""), saving: saving) { [weak self] in
            guard let self, self.generation == requestedGeneration,
                  self.documentID == document, String(self.editRevision) == revision,
                  self.currentPath == path, !self.isBusy, !self.isDiff else {
                throw PluginError.invalid("Editor changed while awaiting approval")
            }
            guard let result = try await self.webView.evaluateJavaScript(script) as? String else {
                throw PluginError.invalid("Editor did not confirm the operation")
            }
            if saving {
                self.save(content: result, documentID: document)
                await self.workTask?.value
                guard self.documentID == document, self.currentPath == path,
                      self.savedContent == result, self.operationError == nil else {
                    throw PluginError.invalid(self.operationError ?? "Save did not complete for this document")
                }
            }
            return ["status": saving ? "saved" : "edited", "documentID": document,
                    "path": path, "content": result]
        }
    }

    func noteMCPExecution(_ id: UUID, source: RExecutionSource? = nil, human: Bool = false) {
        rExecutedSource = source.map { source in
            let name = source.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Provided code"
            return "Executed source: " + name + " · " + source.kind + " · " + source.codeSHA256.prefix(10)
        }
        rLastRequest = id.uuidString.lowercased()
        rSessionStatus = human ? "Code sent to R console · agent execution paused" : "R execution \(id.uuidString.prefix(8)) submitted; waiting for completion"
        if let session = rSession?.session_id {
            UserDefaults.standard.set(["source": rExecutedSource ?? "", "request": rLastRequest ?? ""],
                                      forKey: "relay.execution.presentation." + session)
        }
    }
    func noteRCompletion(_ id: UUID, status: String) {
        guard rLastRequest == id.uuidString.lowercased() else { return }
        if let parent = pane?.remoteParentSessionID.flatMap(UUID.init(uuidString:)),
           let session = rSession?.session_id {
            try? RAutomationController.shared.observeCompletion(paneID: parent, id: id, sessionID: session, status: status)
        }
        let partial = ["error", "interrupted", "unknown"].contains(status) ? " · R state may have changed" : ""
        rSessionStatus = "R execution \(id.uuidString.prefix(8)) · \(status)" + partial
    }

    private var recoveryTask: Task<Void, Never>?
    @Published private(set) var recentDocuments: [EditorRecoveryRecord] = []
    private var requestedRecovery: EditorRecoveryRecord?

    func reopenRecovered(_ record: EditorRecoveryRecord) {
        guard record.profileID == pane?.profile.id else { return }
        guard preserveRecovery() else { return }
        // Menu rows may predate the latest autosave or Undo. Never restore their
        // captured content; read the current durable version at selection time.
        do {
            requestedRecovery = try EditorRecoveryStore.shared.load(profile: record.profileID,
                path: record.path, owner: record.ownerID)
        } catch { operationError = "Draft recovery failed: " + error.localizedDescription; return }
        open(EditorOpenRequest(paths: [record.path], diff: false))
    }

    func refreshRecentDocuments() {
        guard let pane else { return }
        recentDocuments = EditorRecoveryStore.shared.recent(profile: pane.profile.id)
    }

    @discardableResult
    private func preserveRecovery() -> Bool {
        guard let pane, let path = currentPath, let content = recoveryContent else { return !isDirty }
        do {
            try EditorRecoveryStore.shared.save(EditorRecoveryRecord(ownerID: pane.id, profileID: pane.profile.id,
                path: path, content: content, savedContent: savedContent,
                modificationNS: currentModificationNS, updated: Date()))
            return true
        } catch {
            operationError = "Could not preserve editor draft: " + error.localizedDescription
            return false
        }
    }
    private var diffOriginalContent: String?
    private var diffOriginalLabel: String?
    private var appliedTypography: EditorTypography?
    private var workTask: Task<Void, Never>?
    private var diskRefreshTask: Task<Void, Never>?
    private var externalDiskConflict = false

    private func monitorDiskChanges() {
        diskRefreshTask?.cancel()
        diskRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                await self.refreshFromDisk()
            }
        }
    }

    private func refreshFromDisk() async {
        guard started, !isBusy, !isDiff, savingDocumentID == nil,
              webView.window != nil, let pane, let path = currentPath else { return }
        let profile = pane.profile
        let id = documentID
        let epoch = generation
        do {
            let disk = try await Task.detached(priority: .utility) {
                try await Self.remoteJSON(RemoteFileDocument.self, profile: profile,
                    arguments: ["files", "read", "--path-b64", Self.pathArgument(path)])
            }.value
            guard !Task.isCancelled, started, generation == epoch, documentID == id,
                  currentPath == path, !isBusy, !isDiff, savingDocumentID == nil,
                  let text = disk.text else { return }
            if text == savedContent {
                currentModificationNS = disk.modificationNS
                if externalDiskConflict {
                    externalDiskConflict = false
                    operationError = nil
                    status = path
                }
                return
            }
            let revision = editRevision
            let payload: [String: Any] = ["documentID": id, "expectedContent": savedContent, "content": text]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let refreshed = try await webView.evaluateJavaScript(
                "window.relayRefreshFromDisk(\(String(decoding: data, as: UTF8.self)))") as? Bool == true
            guard generation == epoch, documentID == id, currentPath == path else { return }
            guard refreshed else {
                externalDiskConflict = true
                operationError = "This file changed on disk. Your unsaved editor changes are preserved. Reopen the file to review the disk version."
                status = "Disk changes conflict with the editor"
                return
            }
            currentModificationNS = disk.modificationNS
            savedContent = text
            if editRevision == revision {
                recoveryContent = text
                editRevision &+= 1
                isDirty = false
            } else {
                isDirty = recoveryContent != text
            }
            if externalDiskConflict { operationError = nil }
            externalDiskConflict = false
            status = "Updated from disk"
            preserveRecovery()
        } catch {
            // A transient read failure never replaces the user's editor buffer.
        }
    }
    private lazy var scriptHandler = WeakEditorScriptHandler(owner: self)
    private(set) lazy var webView = makeWebView()

    init(pane: PaneModel) {
        self.pane = pane
        super.init()
    }

    func startIfNeeded() {
        guard !started, let pane else { return }
        guard pane.profile.kind == .local || pane.profile.backend == .relay else {
            pane.disconnected("The editor requires a local or Relay-managed remote pane")
            return
        }
        started = true
        generation += 1
        let currentGeneration = generation
        pane.reconnecting()
        let profile = pane.profile
        let parentSessionID = pane.remoteParentSessionID
        let initialDirectory = pane.directory
        if profile.kind == .local && initialDirectory == nil {
            started = false
            pane.disconnected("Return to the local shell prompt so Relay can identify its working directory")
            return
        }
        isBusy = true
        status = "Finding remote workspace…"
        let lookupOverride = workspaceLookupOverride
        let lookupSleep = workspaceLookupSleep
        workTask = Task { [weak self] in
            do {
                let workspace = try await Self.retryingWorkspaceLookup(sleep: lookupSleep) {
                    if let lookupOverride { return RemoteWorkspaceInfo(path: try await lookupOverride()) }
                    return try await Task.detached(priority: .userInitiated) {
                        try await Self.remoteJSON(
                            RemoteWorkspaceInfo.self,
                            profile: profile,
                            arguments: ["files", "workspace"] + (profile.kind == .local
                                ? ["--path-b64", Self.pathArgument(initialDirectory!)]
                                : (parentSessionID.map { ["--parent-session", $0] } ?? []))
                        )
                    }.value
                }
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

    /// relayd's definite refusals for a workspace lookup. Anything else, such as
    /// a transport interruption while the host reconnects after launch, may
    /// succeed on a later attempt.
    nonisolated static func workspaceLookupIsFinal(_ error: Error) -> Bool {
        guard let error = error as? RemoteFileError else { return false }
        switch error {
        case .unavailable(let message):
            return ["valid parent session required", "parent session is unavailable", "parent shell is unavailable",
                    "parent shell identity changed", "parent working directory is unavailable"]
                .contains { message.contains($0) }
        case .invalidResponse, .missingResources:
            return true
        }
    }

    /// Three tries with 2 s and 6 s pauses between them: 8 s of waiting
    /// plus each lookup's own time, not a fixed overall deadline.
    static let workspaceLookupDelays: [Duration] = [.seconds(2), .seconds(6)]

    static func retryingWorkspaceLookup<T>(
        delays: [Duration] = workspaceLookupDelays,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ lookup: () async throws -> T
    ) async throws -> T {
        var remaining = delays[...]
        while true {
            do {
                return try await lookup()
            } catch {
                guard !workspaceLookupIsFinal(error), let delay = remaining.popFirst() else { throw error }
                try await sleep(delay)
            }
        }
    }

    /// Records that the editor has been drawn, so a later failure is reported
    /// as a lost connection rather than an editor that never started.
    func markShown() {
        pane?.editorViewShown = true
    }

    func stop() {
        diskRefreshTask?.cancel()
        diskRefreshTask = nil
        automaticRSetupTask?.cancel()
        recoveryTask?.cancel()
        preserveRecovery()
        rPlotWindow.close()
        rPlotConnection.disconnect()
        generation += 1
        started = false
        savingDocumentID = nil
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
        if Self.owner(of: webView.window?.firstResponder) !== self {
            webView.window?.makeFirstResponder(webView)
        }
        webView.evaluateJavaScript("window.relayFocus && window.relayFocus()")
    }

    func selectForInteraction() {
        if let pane { NotificationCenter.default.post(name: .relaySelectPane, object: pane.id) }
    }

    /// WebKit's first responder is usually a private content subview, not WKWebView itself.
    static func owner(of responder: NSResponder?) -> RemoteEditorRuntime? {
        var view = responder as? NSView
        while let current = view {
            if let editor = current as? RelayEditorWebView { return editor.owner }
            view = current.superview
        }
        return nil
    }

    func undo(redo: Bool) {
        webView.evaluateJavaScript("window.relayUndo && window.relayUndo(\(redo ? "true" : "false"))")
    }

    func pasteFromClipboard() {
        // Snapshot before an automation/clipboard manager restores its contents.
        guard let text = NSPasteboard.general.string(forType: .string),
              text.utf8.count <= 4 * 1024 * 1024,
              let quoted = try? RWorkspaceCommand.quote(text),
              let document = try? RWorkspaceCommand.quote(documentID) else { return }
        webView.evaluateJavaScript("window.relayPaste && window.relayPaste(\(quoted), \(document)); void 0;")
    }

    private func canReplaceDocument(since revision: UInt64) -> Bool {
        guard revision == editRevision, savingDocumentID == nil else {
            isBusy = false
            operationError = "The current file changed while opening another file. Save or discard those edits, then try again."
            return false
        }
        return true
    }

    func loadDirectory(_ path: String) {
        guard let pane else { return }
        let profile = pane.profile
        let currentGeneration = generation
        let requestID = UUID()
        directoryRequestID = requestID
        isBusy = true
        status = "Loading \(TerminalPathSyntax.lastComponent(path))…"
        operationError = nil
        workTask = Task { [weak self] in
            do {
                let listed = try await Task.detached(priority: .userInitiated) {
                    try await Self.remoteJSON(
                        [RemoteFileEntry].self,
                        profile: profile,
                        arguments: ["files", "list", "--path-b64", Self.pathArgument(path)]
                    )
                }.value
                guard let self, self.started, self.generation == currentGeneration,
                      self.directoryRequestID == requestID else { return }
                self.directoryPath = path
                self.entries = listed
                self.isBusy = false
                self.status = path
            } catch {
                guard let self, self.generation == currentGeneration,
                      self.directoryRequestID == requestID else { return }
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
            open(request)
        }
    }

    func goUp() {
        guard !directoryPath.isEmpty, directoryPath != workspacePath else { return }
        let parent = TerminalPathSyntax.parentDirectory(directoryPath)
        guard parent == workspacePath || parent.hasPrefix(workspacePath + "/") else { return }
        loadDirectory(parent)
    }

    func searchFiles(_ query: String, includeUntracked: Bool = false) async {
        let requestID = UUID()
        searchRequestID = requestID
        searchResults = []
        searchStatus = ""
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !workspacePath.isEmpty, let pane else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            while searchInFlight {
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            searchInFlight = true
            defer { searchInFlight = false }
            searchStatus = "Searching…"
            let profile = pane.profile
            let root = workspacePath
            let results = try await Task.detached(priority: .utility) {
                try await Self.remoteJSON(RemoteFileSearchPage.self, profile: profile, arguments: [
                    "files", "find-v2", "--path-b64", Self.pathArgument(root),
                    "--query-b64", Self.pathArgument(query),
                    "--include-untracked=\(includeUntracked)"
                ])
            }.value
            guard !Task.isCancelled, searchRequestID == requestID else { return }
            searchResults = results.entries
            searchStatus = results.warning ?? (results.entries.isEmpty ? "No matching \(includeUntracked ? "" : "tracked ")files" : "\(results.entries.count) matches\(includeUntracked ? "" : " in tracked files")")
        } catch {
            guard !Task.isCancelled, searchRequestID == requestID else { return }
            searchStatus = error.localizedDescription
        }
    }

    func open(_ request: EditorOpenRequest) {
        guard started, let pane else {
            pane?.editorRequest = request
            startIfNeeded()
            return
        }
        guard !request.paths.isEmpty else { return }
        guard savingDocumentID == nil else {
            operationError = "Wait for the current save before opening another file."
            return
        }
        guard confirmDiscardChanges() else { return }
        let profile = pane.profile
        let currentGeneration = generation
        let revision = editRevision
        let requestID = UUID()
        openRequestID = requestID
        isBusy = true
        operationError = nil
        status = request.diff ? "Loading diff…" : "Opening file…"
        workTask = Task { [weak self] in
            do {
                if request.diff && request.paths.count == 1 {
                    let diff = try await Task.detached(priority: .userInitiated) {
                        try await Self.remoteJSON(
                            RemoteGitDiff.self,
                            profile: profile,
                            arguments: ["files", "git-diff", "--path-b64", Self.pathArgument(request.paths[0])]
                        )
                    }.value
                    guard let self, self.generation == currentGeneration, self.openRequestID == requestID,
                          let original = diff.originalText, let modified = diff.modified.text else {
                        throw RemoteFileError.invalidResponse
                    }
                    guard self.canReplaceDocument(since: revision) else { return }
                    pane.editorRequest = request
                    self.showDiff(original: original, originalLabel: diff.originalLabel, modified: modified, document: diff.modified)
                } else if request.diff && request.paths.count == 2 {
                    let documents = try await Task.detached(priority: .userInitiated) {
                        var documents: [RemoteFileDocument] = []
                        for path in request.paths {
                            documents.append(try await Self.remoteJSON(
                                RemoteFileDocument.self,
                                profile: profile,
                                arguments: ["files", "read", "--path-b64", Self.pathArgument(path)]
                            ))
                        }
                        return documents
                    }.value
                    guard let self, self.generation == currentGeneration, self.openRequestID == requestID,
                          let original = documents[0].text, let modified = documents[1].text else {
                        throw RemoteFileError.invalidResponse
                    }
                    guard self.canReplaceDocument(since: revision) else { return }
                    pane.editorRequest = request
                    self.showDiff(original: original, originalLabel: documents[0].path, modified: modified, document: documents[1])
                } else {
                    let document = try await Task.detached(priority: .userInitiated) {
                        try await Self.remoteJSON(
                            RemoteFileDocument.self,
                            profile: profile,
                            arguments: ["files", "read", "--path-b64", Self.pathArgument(request.paths[0])]
                        )
                    }.value
                    guard let self, self.generation == currentGeneration, self.openRequestID == requestID else { return }
                    guard self.canReplaceDocument(since: revision) else { return }
                    pane.editorRequest = request
                    if document.directory == true {
                        self.workspacePath = document.path
                        self.loadDirectory(document.path)
                        return
                    }
                    guard let text = document.text else {
                        throw RemoteFileError.invalidResponse
                    }
                    self.showDocument(document, text: text)
                }
            } catch {
                guard let self, self.generation == currentGeneration, self.openRequestID == requestID else { return }
                self.isBusy = false
                self.operationError = error.localizedDescription
                self.status = "Open failed"
            }
        }
    }

    func requestSave() {
        webView.evaluateJavaScript("window.relayRequestSave && window.relayRequestSave()")
    }

    var canRunR: Bool {
        !isDiff && currentPath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() == "r" } == true
    }

    func requestRunFile() {
        guard canRunR else { return }
        webView.evaluateJavaScript("if (editor) { editor.getAction('relay.runRFile').run(); } void 0;") { [weak self] _, error in
            if let error { self?.operationError = error.localizedDescription }
        }
    }

    func requestRunSelection() {
        guard canRunR else { return }
        webView.evaluateJavaScript("if (editor) { editor.getAction('relay.runRSelection').run(); } void 0;") { [weak self] _, error in
            if let error { self?.operationError = error.localizedDescription }
        }
    }

    func requestEditorAction(_ action: String) {
        guard canRunR, ["format", "lint", "help"].contains(action) else { return }
        webView.evaluateJavaScript("if (editor) { editor.getAction('relay.r.\(action)').run(); } void 0;")
    }

    func confirmDiscardChanges() -> Bool {
        guard savingDocumentID == nil else {
            operationError = "Wait for the current save to finish."
            return false
        }
        guard isDirty else { return true }
        if preserveRecovery() { return true }
        let alert = RelayTheme.alert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = currentPath ?? "This editor has unsaved changes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        return alert.runModal() == .alertSecondButtonReturn
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
            EditorTypography(fontFamily: preferences.resolvedFontFamily, fontSize: preferences.fontSize),
            force: force
        )
    }

    private func save(content: String, documentID requestedDocumentID: String) {
        guard requestedDocumentID == documentID, savingDocumentID == nil,
              let pane, let path = currentPath else { return }
        savingDocumentID = requestedDocumentID
        let profile = pane.profile
        let expectedModificationNS = currentModificationNS
        let currentGeneration = generation
        isBusy = true
        status = "Saving…"
        operationError = nil
        workTask = Task { [weak self] in
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try await Self.remoteJSON(
                        RemoteFileDocument.self,
                        profile: profile,
                        arguments: [
                            "files", "write", "--path-b64", Self.pathArgument(path),
                            "--expected-modification-ns", String(expectedModificationNS)
                        ],
                        input: Data(content.utf8)
                    )
                }.value
                // The generation only changes in startIfNeeded/stop, so also
                // require the path to still match: a save of file A racing an
                // open of file B must not stamp B with A's mtime and content.
                guard let self, self.generation == currentGeneration,
                      self.currentPath == path, self.documentID == requestedDocumentID else { return }
                self.savingDocumentID = nil
                self.currentModificationNS = document.modificationNS
                self.savedContent = content
                self.preserveRecovery()
                self.isBusy = false
                self.status = "Saved"
                // The model's dirty event is authoritative. A returned boolean
                // can already be stale if the user types while JS completes.
                _ = try? await self.webView.evaluateJavaScript("window.relayMarkSaved && window.relayMarkSaved('\(requestedDocumentID)')")
            } catch {
                guard let self, self.generation == currentGeneration,
                      self.currentPath == path, self.documentID == requestedDocumentID else { return }
                self.savingDocumentID = nil
                _ = try? await self.webView.evaluateJavaScript("window.relaySaveFailed && window.relaySaveFailed('\(requestedDocumentID)')")
                self.isBusy = false
                self.operationError = error.localizedDescription
                self.status = "Save failed"
            }
        }
    }

    private func showDocument(_ document: RemoteFileDocument, text: String) {
        externalDiskConflict = false
        recoveryTask?.cancel()
        let recovered: EditorRecoveryRecord?
        do {
            if requestedRecovery?.path == document.path { recovered = requestedRecovery }
            else { recovered = try pane.flatMap { try EditorRecoveryStore.shared.load(profile: $0.profile.id, path: document.path, owner: $0.id) } }
        }
        catch { recovered = nil; operationError = "Draft recovery failed: " + error.localizedDescription }
        requestedRecovery = nil
        documentID = UUID().uuidString
        currentPath = document.path
        currentModificationNS = document.modificationNS
        savedContent = text
        recoveryContent = recovered?.dirty == true ? recovered?.content : text
        if let recovered, recovered.dirty {
            // Preserve the old write precondition: an externally changed file must
            // still fail conflict detection instead of being silently overwritten.
            currentModificationNS = recovered.modificationNS
            savedContent = recovered.savedContent
        }
        diffOriginalContent = nil
        diffOriginalLabel = nil
        isDirty = recoveryContent != savedContent
        isDiff = false
        isBusy = false
        status = document.path
        if isDirty { status = "Recovered unsaved draft" }
        preserveRecovery()
        refreshRecentDocuments()
        pane?.title = TerminalPathSyntax.lastComponent(document.path)
        deliverCurrentDocument()
        monitorDiskChanges()
    }

    private func showDiff(original: String, originalLabel: String, modified: String, document: RemoteFileDocument) {
        showDocument(document, text: modified)
        diffOriginalContent = original
        diffOriginalLabel = originalLabel
        isDiff = true
        isBusy = false
        status = "Comparing changes"
        pane?.title = TerminalPathSyntax.lastComponent(document.path)
        deliverCurrentDocument()
    }

    private func deliverCurrentDocument() {
        guard currentPath != nil else { return }
        loadEditorPageIfNeeded()
        guard webReady, let path = currentPath else { return }
        var payload: [String: Any] = [
            "path": path, "language": Self.language(for: path), "content": savedContent, "diff": isDiff,
            "documentID": documentID
        ]
        if let pane, let data = UserDefaults.standard.data(forKey: "relay.editor.view." + pane.profile.id.uuidString + ":" + path),
           let view = try? JSONSerialization.jsonObject(with: data) {
            payload["viewState"] = view
        }
        if recoveryContent != savedContent { payload["recoveredContent"] = recoveryContent }
        if let diffOriginalContent { payload["original"] = diffOriginalContent }
        if let diffOriginalLabel { payload["originalLabel"] = diffOriginalLabel }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.relayOpenDocument(\(json))")
    }

    private func loadEditorPageIfNeeded() {
        guard webView.url == nil else { return }
        guard let indexURL = RelayResources.bundle?.url(forResource: "index", withExtension: "html", subdirectory: "Editor") else {
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
        case "viewState":
            guard body["documentID"] as? String == documentID, let pane, let path = currentPath,
                  let view = body["viewState"] as? [String: Any],
                  JSONSerialization.isValidJSONObject(view),
                  let data = try? JSONSerialization.data(withJSONObject: view), data.count < 262_144 else { return }
            UserDefaults.standard.set(data, forKey: "relay.editor.view." + pane.profile.id.uuidString + ":" + path)
        case "rHelp":
            guard body["documentID"] as? String == documentID, canRunR,
                  let topic = body["topic"] as? String, !topic.isEmpty, topic.utf8.count <= 512 else { return }
            rHelpTopic = topic
            showsRResults = true
            rHelpRequestID = UUID()
        case "rCompletionHelp":
            guard let request = body["request"] as? Int, request >= 0, request < 1_000_000_000,
                  body["documentID"] as? String == documentID,
                  let topic = body["topic"] as? String else { return }
            let document = documentID
            requestREditorTool("help", code: "", topic: topic) { [weak self] result in
                guard let self else { return }
                var payload = "null"
                if self.documentID == document, case .success(let json) = result { payload = json }
                self.webView.evaluateJavaScript("window.relayComplete(\(request), \(payload)); void 0;")
            }
        case "rCompletion":
            guard let request = body["request"] as? Int, request >= 0, request < 1_000_000_000,
                  let document = body["documentID"] as? String else { return }
            requestRCompletion(request, document: document)
        case "rEditorTool":
            guard body["documentID"] as? String == documentID, !isDiff,
                  let method = body["method"] as? String,
                  let code = body["code"] as? String else { return }
            let document = documentID
            let revision = editRevision
            requestREditorTool(method, code: code) { [weak self] result in
                guard let self, self.documentID == document, self.editRevision == revision else { return }
                switch result {
                case .success(let json):
                    self.webView.evaluateJavaScript("window.relayApplyRTool(\(try! RWorkspaceCommand.quote(method)), \(json)); void 0;")
                    self.operationError = nil
                case .failure(let error): self.operationError = error.localizedDescription
                }
            }
        case "runCode":
            guard body["documentID"] as? String == documentID, !isDiff,
                  currentPath.map({ URL(fileURLWithPath: $0).pathExtension.lowercased() == "r" }) == true,
                  let code = body["code"] as? String else { return }
            do {
                guard let requestUserRCode else { throw PluginError.invalid("The linked R console is unavailable") }
                try requestUserRCode(RWorkspaceCommand.userInput(code))
                if let line = body["advanceLine"] as? Int, line > 0 {
                    webView.evaluateJavaScript("if (editor && editor.getSelection().isEmpty() && editor.getPosition().lineNumber === \(line)) { editor.setPosition({lineNumber: Math.min(\(line + 1), editor.getModel().getLineCount()), column: 1}); editor.revealPositionInCenterIfOutsideViewport(editor.getPosition()); } void 0;")
                }
                operationError = nil
            } catch { operationError = error.localizedDescription }
        case "focus": selectForInteraction()
        case "ready":
            webReady = true
            appliedTypography = nil
            applyCurrentTypography(force: true)
            deliverCurrentDocument()
        case "dirty":
            guard body["documentID"] as? String == documentID else { return }
            let dirty = body["dirty"] as? Bool ?? true
            if isDirty != dirty { isDirty = dirty }
        case "edited":
            guard body["documentID"] as? String == documentID else { return }
            editRevision &+= 1
            if let content = body["content"] as? String {
                recoveryContent = content
                recoveryTask?.cancel()
                recoveryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    self?.preserveRecovery()
                }
            }
        case "save":
            if let content = body["content"] as? String, let id = body["documentID"] as? String {
                save(content: content, documentID: id)
            }
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
    ) async throws -> T {
        let captured = try await RelayHostExecution.capture(profile: profile,
            command: RelayHostExecution.daemonCommand(profile: profile, arguments: commandArguments),
            input: input ?? Data(), timeout: 20)
        let outputData = captured.stdout
        guard captured.exitCode == 0 else {
            let message = String(data: captured.stderr, encoding: .utf8)?.split(separator: "\n").last.map(String.init)
                ?? "Remote file operation failed; job \(captured.jobID)"
            throw RemoteFileError.unavailable(message)
        }
        guard let decoded = try? JSONDecoder().decode(type, from: outputData) else {
            throw RemoteFileError.invalidResponse
        }
        return decoded
    }

    nonisolated private static func language(for path: String) -> String {
        switch TerminalPathSyntax.pathExtension(path) {
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
        owner?.selectForInteraction()
        super.mouseDown(with: event)
    }
}

// SwiftUI owns each presentation host; the document owns the persistent WebKit
// view. Never return the same NSView from two representable lifetimes: removing
// the old floating presentation can otherwise remove the new maximized view.
@MainActor
final class RelayEditorHostView: NSView {
    let editor: RelayEditorWebView
    private var committedSize: CGSize?
    private var presentationTask: Task<Void, Never>?

    init(editor: RelayEditorWebView) {
        self.editor = editor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attachEditor() {
        guard editor.superview !== self else { return }
        editor.removeFromSuperview()
        editor.frame = bounds
        editor.autoresizingMask = [.width, .height]
        addSubview(editor)
    }

    func detachEditor() {
        presentationTask?.cancel()
        presentationTask = nil
        guard editor.superview === self else { return }
        editor.removeFromSuperview()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        committedSize = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard editor.superview === self else { return }
        editor.frame = bounds
        guard window != nil, bounds.width > 0, bounds.height > 0,
              committedSize != bounds.size else { return }
        committedSize = bounds.size
        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.window != nil,
                  self.editor.superview === self else { return }
            self.editor.needsDisplay = true
            // Reparenting a WebKit view is not a browser resize event. Commit
            // the visible presentation without reloading its document/model.
            _ = try? await self.editor.evaluateJavaScript("window.relayLayout && window.relayLayout()")
        }
    }
}

struct MonacoEditorSurface: NSViewRepresentable {
    @ObservedObject var runtime: RemoteEditorRuntime
    let typography: EditorTypography

    func makeNSView(context: Context) -> RelayEditorHostView {
        let view = RelayEditorHostView(editor: runtime.webView)
        view.attachEditor()
        runtime.markShown()
        Task { @MainActor in
            await Task.yield()
            runtime.startIfNeeded()
            runtime.applyTypography(typography)
        }
        return view
    }

    func updateNSView(_ nsView: RelayEditorHostView, context: Context) {
        Task { @MainActor in
            await Task.yield()
            runtime.startIfNeeded()
            runtime.applyTypography(typography)
        }
    }

    static func dismantleNSView(_ nsView: RelayEditorHostView, coordinator: ()) {
        nsView.detachEditor()
    }
}

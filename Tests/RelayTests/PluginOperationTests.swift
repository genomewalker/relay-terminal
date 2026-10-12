import Foundation
import Testing
import CryptoKit
@testable import Relay

@Test("Project execution requires explicit bounded command review and its own permission")
func projectCommandReview() throws {
    let valid = #"{"argv":["/usr/bin/true"],"environment":{},"timeout_seconds":60}"#
    try PluginHPCAction(id: UUID(), script: valid).validate(operation: .projectRun, path: "")
    #expect(RelayPluginOperation.projectRun.permissions == [.projectExecute])
    #expect(RelayPluginOperation.projectRun.isMutation)
    for invalid in ["{}", valid.replacingOccurrences(of: "/usr/bin/true", with: "true"), valid.replacingOccurrences(of: "60", with: "61"), valid + " {}", valid.replacingOccurrences(of: "\"environment\":{}", with: "\"environment\":{\"INVALID=NAME\":\"x\"}")] {
        #expect(throws: (any Error).self) {
            try PluginHPCAction(id: UUID(), script: invalid).validate(operation: .projectRun, path: "")
        }
    }
}

@Test("Plugin editor handoff preserves the captured root and rejects traversal")
func pluginEditorPath() throws {
    let scope = try PluginScope(paneID: UUID(), profile: .local, root: "/tmp/project")
    #expect(try scope.editorPath("src/a b.R") == "/tmp/project/src/a b.R")
    for path in ["", "/etc/passwd", "../other", "src/../other", "src//file", "./file", "x\0y"] {
        #expect(throws: (any Error).self) { try scope.editorPath(path) }
    }
}

@Test("Plugin operations have a fixed concurrency budget and no waiting queue")
func pluginOperationBudget() async throws {
    let budget = PluginOperationBudget()
    try await budget.acquire()
    try await budget.acquire()
    await #expect(throws: PluginOperationBudget.Failure.self) { try await budget.acquire() }
    await budget.release()
    try await budget.acquire()
}

@Test("Every native plugin tool requires its exact declared capability set")
func pluginToolsRequirePermissions() throws {
    for operation in RelayPluginOperation.allCases {
        let permissions = operation.permissions.map { RelayPluginPackage.Permission(kind: $0, reason: "User-approved operation") }
        let tool = RelayPluginPackage.Contribution(id: "tool", kind: .tool, title: "Test", text: "", url: nil, operation: operation)
        let package = RelayPluginPackage(schemaVersion: 1, apiVersion: operation.isMutation ? 3 : 2, id: "test.tool", name: "Test", version: "0.1.0", repository: "test/tool", permissions: permissions, contributions: [tool])
        let decoded = try RelayPluginPackage.decode(JSONEncoder().encode(package), repository: "test/tool")
        #expect(decoded.supportsActivation)
        let missing = RelayPluginPackage(schemaVersion: 1, apiVersion: 2, id: "test.tool", name: "Test", version: "0.1.0", repository: "test/tool", permissions: [], contributions: [tool])
        #expect(throws: (any Error).self) { try RelayPluginPackage.decode(JSONEncoder().encode(missing), repository: "test/tool") }
    }
}

@Test("Plugin scope rejects missing directories and file payload integrity fails closed")
func pluginScopeAndIntegrity() throws {
    for path in ["", "relative", "/tmp/\0bad"] {
        #expect(throws: (any Error).self) { try PluginScope(paneID: UUID(), profile: .local, root: path) }
    }
    let result = PluginOperationResult(root: "/tmp", text: "x", entries: [], content: "aGVsbG8=", sha256: "wrong", truncated: false)
    #expect(throws: (any Error).self) { try result.verifiedContent() }
}

@Test("Plugin transfers preserve empty files and reject wrong-path or unsolicited content")
func pluginTransferEnvelope() throws {
    let digest = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
    var result = PluginOperationResult(root: "/tmp", text: "empty", entries: [], content: "", sha256: digest, truncated: false)
    try result.validateEnvelope(operation: .transfers, path: "empty")
    #expect(try result.verifiedContent() == Data())
    #expect(throws: (any Error).self) { try result.validateEnvelope(operation: .transfers, path: "different") }
    #expect(throws: (any Error).self) { try result.validateEnvelope(operation: .gitReview, path: "") }
    result.content = nil
    #expect(throws: (any Error).self) { try result.validateEnvelope(operation: .transfers, path: "empty") }
    result.sha256 = nil; result.entries = Array(repeating: "file", count: 501)
    #expect(throws: (any Error).self) { try result.validateEnvelope(operation: .artifacts, path: "") }
}

@Test("All seven shipped manifests install, enable and revoke in an isolated store")
func officialPluginPackages() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let store = RelayPluginStore(directory: temporary)
    for slug in ["hpc-jobs", "artifacts", "agent-activity", "git-review", "transfers", "project-actions", "radian"] {
        let data = try Data(contentsOf: root.appendingPathComponent("docs/plugins/\(slug)/relay-plugin.json"))
        let package = try RelayPluginPackage.decode(data, repository: "genomewalker/relay-plugin-\(slug)")
        let candidate = try ReviewedPluginCandidate(bytes: data, repository: package.repository, releaseTag: "v" + package.version)
        try await store.install(candidate, approvedDigest: candidate.digest)
        try await store.setEnabled(candidate.package.id, true)
        try await store.setEnabled(candidate.package.id, false)
        #expect(try await store.activePackages().allSatisfy { $0.id != candidate.package.id })
        try await store.setEnabled(candidate.package.id, true)
    }
    #expect(try await store.activePackages().count == 7)
    try await store.setEnabled("relay.agent-activity", false)
    #expect(try await store.activePackages().count == 6)
    let safe = RelayPluginStore(directory: temporary, safeMode: true)
    #expect(try await safe.activePackages().isEmpty)
}

@Test("Cancellable subprocess capture stops a running operation")
func pluginProcessCancellation() async throws {
    await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        let start = Date()
        #expect(throws: (any Error).self) {
            try ProcessCapture.run(process, output: output, errors: errors, timeout: 12, shouldCancel: { true })
        }
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(!process.isRunning)
    }.value
}

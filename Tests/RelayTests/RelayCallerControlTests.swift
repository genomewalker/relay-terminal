import Foundation
import Testing
@testable import Relay

@Test @MainActor func callerManagementPersistsPrivateMetadataAndMigrationState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-callers-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = RelayCallerControl(directory: directory)
    let issued = try await control.register(label: "Fixture client", thread: "claimed-thread")
    let id = try #require(issued["caller_id"]), token = try #require(issued["caller_token"])
    #expect(try control.identity(token: token) == id)
    #expect(control.label(for: id) == "Fixture client")
    #expect(control.summaries.first(where: { $0.id == id })?.thread == "claimed-thread")
    #expect(control.permitted("legacy-unattributed"))
    try await control.setPaused(id: id, paused: true)
    #expect(!control.permitted(id))
    #expect(control.permitted("legacy-unattributed"))
    let disk = directory.appendingPathComponent("caller-control-v1.json")
    let data = try Data(contentsOf: disk)
    #expect(!String(decoding: data, as: UTF8.self).contains(token))
    #expect(!String(decoding: try JSONSerialization.data(withJSONObject: control.listing()), as: UTF8.self).contains(token))
    #expect((try FileManager.default.attributesOfItem(atPath: disk.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let restored = RelayCallerControl(directory: directory)
    #expect(try restored.identity(token: token) == id)
    #expect(!restored.permitted(id))
    try await restored.setPaused(id: "legacy-unattributed", paused: true)
    try await restored.setPaused(id: id, paused: false)
    #expect(!restored.permitted("legacy-unattributed"))
    #expect(restored.permitted(id))
}

@Test @MainActor func callerManagementCorruptStoreDoesNotOverwriteOrAuthorize() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-callers-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("caller-control-v1.json")
    try Data("invalid".utf8).write(to: file)
    let control = RelayCallerControl(directory: directory)
    #expect(!control.available)
    await #expect(throws: (any Error).self) { try await control.register(label: "Fixture", thread: nil) }
    #expect(throws: (any Error).self) { try control.identity(token: nil) }
    await #expect(throws: (any Error).self) { try await control.setPaused(id: "legacy-unattributed", paused: true) }
    #expect(try Data(contentsOf: file) == Data("invalid".utf8))
}

@Test @MainActor func callerAuditExtractsWorkspaceOperationWithoutSecrets() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-audit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = RelayCallerControl(directory: directory)
    let body = try JSONSerialization.data(withJSONObject: [
        "tab_id": "captured-tab", "request_id": "outer-request", "caller": "forged-caller",
        "request": ["operation": "exec", "job_id": "stable-job", "request_id": "inner-request",
                    "pane_id": "operation-pane", "caller_token": "secret-token", "command": "secret-command"]
    ])
    let request = RelaySidePanelHTTPRequest(method: "POST", path: "/api/workspace/host-request", headers: [:], body: body)
    try control.record(caller: "resolved-client", request: request, outcome: "admitted")
    let entry = try #require(control.audit().last)
    #expect(entry.caller == "resolved-client")
    #expect(entry.operation == "exec")
    #expect(entry.jobID == "stable-job")
    #expect(entry.requestID == "outer-request")
    #expect(entry.tabID == "captured-tab")
    #expect(entry.paneID == "operation-pane")
    let serialized = String(decoding: try Data(contentsOf: directory.appendingPathComponent("caller-audit-v1.jsonl")), as: UTF8.self)
    #expect(serialized.contains("resolved-client"))
    #expect(!serialized.contains("secret-token"))
    #expect(!serialized.contains("secret-command"))
    #expect(!serialized.contains("forged-caller"))
}

@Test @MainActor func callerAuditPreservesDirectRequestAndReturnedPane() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-audit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = RelayCallerControl(directory: directory)
    let body = try JSONSerialization.data(withJSONObject: [
        "operation": "exec", "job_id": "direct-job", "request_id": "direct-request", "pane_id": "requested-pane",
        "request": ["operation": "forged-nested-operation", "job_id": "forged-nested-job"]
    ])
    let request = RelaySidePanelHTTPRequest(method: "POST", path: "/api/host/request", headers: [:], body: body)
    let output = try JSONSerialization.data(withJSONObject: ["pane_id": "returned-pane"])
    try control.record(caller: "resolved-client", request: request, outcome: "http-200", responseData: output)
    let entry = try #require(control.audit().last)
    #expect(entry.operation == "exec")
    #expect(entry.jobID == "direct-job")
    #expect(entry.requestID == "direct-request")
    #expect(entry.paneID == "returned-pane")
}

@Test @MainActor func callerAuditUsesNestedRequestIDAndHandlesMissingEnvelope() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-audit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = RelayCallerControl(directory: directory)
    let body = try JSONSerialization.data(withJSONObject: ["tab_id": "tab", "request": ["operation": "status", "request_id": "nested-request", "job_id": "job"]])
    let request = RelaySidePanelHTTPRequest(method: "POST", path: "/api/workspace/host-request", headers: [:], body: body)
    try control.record(caller: "resolved-client", request: request, outcome: "admitted")
    #expect(control.audit().last?.requestID == "nested-request")
    let bad = RelaySidePanelHTTPRequest(method: "POST", path: "/api/workspace/host-request", headers: [:], body: Data("{}".utf8))
    try control.record(caller: "resolved-client", request: bad, outcome: "http-400")
    #expect(control.audit().last?.operation == nil)
    #expect(control.audit().last?.jobID == nil)
}

import AppKit
import Foundation
import Testing
@testable import Relay

#if DEBUG
@MainActor private final class RecoveryEndpointGate {
    var started: CheckedContinuation<Void, Never>?
    var pending: CheckedContinuation<RemoteCatalogSnapshot, Error>?
    var loads = 0
    var attachments = 0
    var duplicateSnapshot: RemoteCatalogSnapshot?

    func load(_ profile: ConnectionProfile) async throws -> RemoteCatalogSnapshot {
        loads += 1
        if pending != nil, let duplicateSnapshot { return duplicateSnapshot }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }
    func waitForLoad() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ snapshot: RemoteCatalogSnapshot) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: snapshot)
    }
}

private func callRecoveryMCP(binary: String, token: String, port: UInt16,
                             instance: UUID, requestID: UUID, paneID: UUID,
                             host: String = "This Mac") async throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": ["name": "relay_recover_pane", "arguments": [
            "instance": instance.uuidString, "request_id": requestID.uuidString,
            "pane_id": paneID.uuidString, "host": host]]])
    let data = try await Task.detached { () throws -> Data in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var environment = ProcessInfo.processInfo.environment
        environment["RELAY_MCP_TOKEN"] = token
        environment["RELAY_MCP_PORT"] = String(port)
        environment.removeValue(forKey: "RELAY_MCP_BACKEND")
        environment.removeValue(forKey: "RELAY_MCP_CALLER_TOKEN")
        let input = Pipe(), output = Pipe()
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(payload + Data([10]))
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "RecoveryMCPFixture", code: Int(process.terminationStatus)) }
        return result
    }.value
    return String(decoding: data, as: UTF8.self)
}

private func recoveryFixtureBinary() async throws -> String {
    if let supplied = ProcessInfo.processInfo.environment["RELAY_RECOVERY_FIXTURE_MCP"] { return supplied }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let output = RelayStateProfile.applicationSupportRoot.appendingPathComponent("recovery-endpoint-fixture/relay-mcp")
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    return try await Task.detached {
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["go", "build", "-o", output.path, "./cmd/relay-mcp"]
        build.currentDirectoryURL = root.appendingPathComponent("remote/relayd")
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else { throw NSError(domain: "RecoveryMCPBuild", code: Int(build.terminationStatus)) }
        return output.path
    }.value
}

@Test("Real MCP adapter and Swift HTTP route preserve recovery receipts and revocation", .timeLimit(.minutes(1)))
@MainActor func recoveryMCPEndpoint() async throws {
    try #require(RelayStateProfile.isIsolated, "Endpoint fixture must use isolated Relay state")
    try #require(RelayStateProfile.configurationError == nil && RelayStateProfile.sidePanelPort >= 1024 &&
                 RelayStateProfile.sidePanelPort != 47_471, "Endpoint fixture needs a valid non-production port")
    let binary = try await recoveryFixtureBinary()
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let pane = try #require(workspace.activePane)
    var complete: ((NSApplication.ModalResponse) -> Void)?
    let grant = MCPWorkspaceGrant { _, callback in complete = callback; return true }
    try grant.request()
    complete?(.alertSecondButtonReturn)
    let server = RelaySidePanelServer(recoveryFixture: workspace)
    let gate = RecoveryEndpointGate()
    server.recoveryFixtureGrant = grant
    server.recoveryFixtureLoad = { try await gate.load($0) }
    server.recoveryFixtureAttach = { _, _, _, _ in gate.attachments += 1; return true }
    let ready = await withCheckedContinuation { continuation in
        server.recoveryFixtureReady = { ready in continuation.resume(returning: ready) }
        server.startRecoveryFixture()
    }
    try #require(ready, "Isolated endpoint did not bind")
    defer { server.stopRecoveryFixture() }
    let token = try #require(server.accessURL.fragment)
    let instance = try #require(server.instance)
    let paneID = pane.id, requestID = UUID()
    let catalogPane = RemoteCatalogPane(paneID: paneID.uuidString.lowercased(), workspaceID: UUID().uuidString.lowercased(),
        tabID: UUID().uuidString.lowercased(), parentPaneID: nil, title: "fixture", contentKind: "terminal",
        command: nil, directory: nil, state: "running", workerPID: 42, shellPID: 43,
        lastSequence: 0, recoverable: true, unfiled: false)
    let snapshot = RemoteCatalogSnapshot(schema: 1, revision: 1, panes: [catalogPane], workspaceStates: nil)
    gate.duplicateSnapshot = snapshot
    let first = Task { try await callRecoveryMCP(binary: binary, token: token, port: RelaySidePanelServer.port.rawValue,
                                                instance: instance, requestID: requestID, paneID: paneID) }
    await gate.waitForLoad()
    let pending = try await callRecoveryMCP(binary: binary, token: token, port: RelaySidePanelServer.port.rawValue,
                                            instance: instance, requestID: requestID, paneID: paneID)
    #expect(pending.contains("pending"))
    let conflict = try await callRecoveryMCP(binary: binary, token: token, port: RelaySidePanelServer.port.rawValue,
                                             instance: instance, requestID: requestID, paneID: UUID())
    #expect(conflict.contains("Conflicting recovery request ID"))
    #expect(gate.loads == 1 && gate.attachments == 0)
    gate.finish(snapshot)
    #expect(try await first.value.contains("attached"))
    let replay = try await callRecoveryMCP(binary: binary, token: token, port: RelaySidePanelServer.port.rawValue,
                                           instance: instance, requestID: requestID, paneID: paneID)
    #expect(replay.contains("attached"))
    #expect(gate.loads == 1 && gate.attachments == 1)

    let revokedRequest = UUID()
    let revoked = Task { try await callRecoveryMCP(binary: binary, token: token, port: RelaySidePanelServer.port.rawValue,
                                                   instance: instance, requestID: revokedRequest, paneID: paneID) }
    await gate.waitForLoad()
    grant.revoke()
    gate.finish(snapshot)
    #expect(try await revoked.value.contains("revoked"))
    #expect(gate.loads == 2 && gate.attachments == 1)

    try grant.request()
    complete?(.alertSecondButtonReturn)
    let paused = Task { try await callRecoveryMCP(binary: binary, token: token, port: RelaySidePanelServer.port.rawValue,
                                                 instance: instance, requestID: UUID(), paneID: paneID) }
    await gate.waitForLoad()
    try await RelayCallerControl.shared.setPaused(id: "legacy-unattributed", paused: true)
    gate.finish(snapshot)
    #expect(try await paused.value.contains("revoked"))
    #expect(gate.loads == 3 && gate.attachments == 1)
    try await RelayCallerControl.shared.setPaused(id: "legacy-unattributed", paused: false)
}
#endif

import Foundation
import CryptoKit
import Testing
@testable import Relay

@Suite struct RelayCodexRemoteRuntimeTests {
    @Test func bindsSocketToExactRetainedSourceIncarnation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-ssh")
        let pane = UUID().uuidString.lowercased()
        let session = UUID().uuidString.lowercased()
        let snapshot = try JSONSerialization.data(withJSONObject: ["schema": 1, "client": "codex",
            "pid": 42, "process_start": "123", "relay_pane_id": pane,
            "cwd": "/home/kbd606", "executable": "/bin/codex", "launch_id": "fixture",
            "effective_args": [String](), "arguments": ["reusable": true]])
        let params = try JSONSerialization.data(withJSONObject: ["cwd": "/project",
            "model": "fixture-model", "approvalPolicy": "never", "sandbox": "readOnly"])
        let enrollment = RelayRetainedRotationEnrollment(sessionID: session,
            client: "codex", hostID: "host", paneID: pane, processID: 42,
            processStart: "123", snapshotPath: "/private/snapshot.json",
            snapshotSHA256: SHA256.hash(data: snapshot).map { String(format: "%02x", $0) }.joined(),
            snapshot: snapshot, enrolledAt: Date(timeIntervalSince1970: 1),
            codexStart: RelayCodexStartConfiguration(sourceThreadID: session,
                sourceTurnID: "turn-1", sourcePID: 42, sourceProcessStart: "123",
                parameters: params, effort: "medium",
                sha256: SHA256.hash(data: params).map { String(format: "%02x", $0) }.joined(),
                capturedAt: Date(timeIntervalSince1970: 0)))
        func install(pid: Int) throws {
            let response = "{\"path\":\"/private/socket\",\"device\":1,\"inode\":2,\"executable\":\"/bin/codex\",\"working_directory\":\"/home/kbd606\",\"source_pid\":\(pid),\"source_start\":\"123\"}"
            try Data(("#!/bin/sh\nprintf '%s' '" + response + "'\n").utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        try install(pid: 42)
        let client = RelayCodexRemoteRuntimeClient(profile: ConnectionProfile(host: "fixture"),
            sshExecutable: script)
        let result = try await client.read(enrollment: enrollment)
        #expect(result.path == "/private/socket")
        #expect(result.inode == 2)
        try install(pid: 43)
        await #expect(throws: RelayRotationAdapterError.self) {
            try await client.read(enrollment: enrollment)
        }
    }
}

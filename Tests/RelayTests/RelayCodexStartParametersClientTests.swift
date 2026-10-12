import Foundation
import CryptoKit
import Testing
@testable import Relay

@Suite struct RelayCodexStartParametersClientTests {
    @Test func capturesEffectiveProjectSettingsSeparateFromProcessDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-ssh")
        let session = UUID().uuidString.lowercased(), pane = UUID().uuidString.lowercased()
        let snapshot = try JSONSerialization.data(withJSONObject: ["schema": 1, "client": "codex",
            "pid": 42, "process_start": "123", "relay_pane_id": pane,
            "cwd": "/home/kbd606", "executable": "/bin/codex", "launch_id": "fixture",
            "effective_args": ["resume", session], "arguments": ["reusable": true]])
        let candidate = RelayRetainedRotationEnrollment(sessionID: session, client: "codex",
            hostID: "host", paneID: pane, processID: 42, processStart: "123",
            snapshotPath: "/private/snapshot.json",
            snapshotSHA256: SHA256.hash(data: snapshot).map { String(format: "%02x", $0) }.joined(),
            snapshot: snapshot, enrolledAt: Date(timeIntervalSince1970: 1))
        #expect(candidate.launchIdentityValid)
        #expect(!candidate.valid)
        func install(thread: String) throws {
            let output = try JSONSerialization.data(withJSONObject: [
                "source_thread_id": thread, "source_turn_id": "turn-1", "effort": "medium",
                "rollout_path": "/private/rollout.jsonl", "start_parameters": [
                    "model": "fixture", "cwd": "/project", "approvalPolicy": "never",
                    "sandbox": "dangerFullAccess", "personality": "pragmatic"]])
            let source = "#!/bin/sh\nprintf '%s' '" + String(decoding: output, as: UTF8.self) + "'\n"
            try Data(source.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        try install(thread: session)
        let client = RelayCodexStartParametersClient(profile: ConnectionProfile(host: "fixture"),
            sshExecutable: script)
        let value = try await client.capture(candidate: candidate, now: Date(timeIntervalSince1970: 2))
        #expect(value.valid)
        #expect(value.codexStart?.effort == "medium")
        let params = try JSONSerialization.jsonObject(with: #require(value.codexStart).parameters) as? [String: Any]
        #expect(params?["cwd"] as? String == "/project")
        try install(thread: UUID().uuidString)
        await #expect(throws: RelayRotationAdapterError.self) {
            try await client.capture(candidate: candidate, now: Date(timeIntervalSince1970: 2))
        }
    }
}

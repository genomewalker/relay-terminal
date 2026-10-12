import Foundation
import CryptoKit
import Testing
@testable import Relay

@Suite struct RelayClaudeStartParametersClientTests {
    @Test func capturesCurrentModelEffortPermissionAndRejectsStaleOrForeignSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-ssh")
        let session = UUID().uuidString.lowercased(), pane = UUID().uuidString.lowercased()
        let snapshot = try JSONSerialization.data(withJSONObject: ["schema": 1, "client": "claude",
            "pid": 42, "process_start": "123", "relay_pane_id": pane,
            "cwd": "/project", "executable": "/bin/claude", "launch_id": "fixture",
            "effective_args": ["--session-id", session], "arguments": ["reusable": true]])
        let candidate = RelayRetainedRotationEnrollment(sessionID: session, client: "claude",
            hostID: "host", paneID: pane, processID: 42, processStart: "123",
            snapshotPath: "/private/snapshot.json",
            snapshotSHA256: SHA256.hash(data: snapshot).map { String(format: "%02x", $0) }.joined(),
            snapshot: snapshot, enrolledAt: Date(timeIntervalSince1970: 1))
        #expect(candidate.launchIdentityValid)
        #expect(!candidate.valid)
        func install(sessionID: String, time: String) throws {
            let output = try JSONSerialization.data(withJSONObject: [
                "session_id": sessionID, "pane_id": pane, "source_pid": 42,
                "source_start": "123", "model": "claude-opus", "effort": "high",
                "permission_mode": "auto", "cwd": "/project",
                "fresh_args": ["--model", "claude-opus", "--permission-mode", "auto"],
                "captured_at": time] as [String: Any])
            let source = "#!/bin/sh\nprintf '%s' '" + String(decoding: output, as: UTF8.self) + "'\n"
            try Data(source.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        try install(sessionID: session, time: "1970-01-01T00:00:01Z")
        let client = RelayClaudeStartParametersClient(profile: ConnectionProfile(host: "fixture"),
            sshExecutable: script)
        let value = try await client.capture(candidate: candidate, now: Date(timeIntervalSince1970: 2))
        #expect(value.valid)
        #expect(value.claudeStart?.sourceSessionID == session)
        try install(sessionID: UUID().uuidString, time: "1970-01-01T00:00:01Z")
        await #expect(throws: RelayRotationAdapterError.self) {
            try await client.capture(candidate: candidate, now: Date(timeIntervalSince1970: 2))
        }
        try install(sessionID: session, time: "1970-01-01T00:00:01Z")
        await #expect(throws: RelayRotationAdapterError.self) {
            try await client.capture(candidate: candidate, now: Date(timeIntervalSince1970: 40))
        }
    }
}

import Foundation
import Testing
@testable import Relay

@Suite struct RelayClaudeAgentsClientTests {
    @Test func selectsOneExactInteractiveSessionFromHeterogeneousList() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-ssh")
        let session = UUID().uuidString.lowercased()
        func install(status: String, duplicate: Bool = false) throws {
            let target: [String: Any] = ["kind": "interactive", "sessionId": session,
                "pid": 42, "startedAt": 1_790_137_904_580 as Int64,
                "cwd": "/fixture", "status": status]
            var rows: [[String: Any]] = [["kind": "background", "sessionId": UUID().uuidString,
                "state": "idle", "cwd": "/other", "startedAt": 1]]
            rows.append(target)
            if duplicate { rows.append(target) }
            let output = try JSONSerialization.data(withJSONObject: rows)
            let source = "#!/bin/sh\nprintf '%s' '" + String(decoding: output, as: UTF8.self) + "'\n"
            try Data(source.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        try install(status: "idle")
        let client = RelayClaudeAgentsClient(profile: ConnectionProfile(host: "fixture"),
            sshExecutable: script)
        let value = try await client.read(sessionID: session, expectedPID: 42, expectedCWD: "/fixture")
        #expect(value.status == "idle")
        await #expect(throws: RelayRotationAdapterError.self) {
            try await client.read(sessionID: session, expectedPID: 43, expectedCWD: "/fixture")
        }
        try install(status: "busy")
        await #expect(throws: RelayRotationAdapterError.self) {
            try await client.read(sessionID: session, expectedPID: 42, expectedCWD: "/fixture")
        }
        try install(status: "idle", duplicate: true)
        await #expect(throws: RelayRotationAdapterError.self) {
            try await client.read(sessionID: session, expectedPID: 42, expectedCWD: "/fixture")
        }
    }
}

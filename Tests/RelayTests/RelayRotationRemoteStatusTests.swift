import Foundation
import Testing
@testable import Relay

@Suite struct RelayRotationRemoteStatusTests {
    @Test func readsExactLiveIncarnationAndRejectsUnknownInputOutcome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-ssh")
        let pane = UUID().uuidString.lowercased(), session = UUID().uuidString.lowercased()
        func install(known: Bool) throws {
            let response = "{\"pane_id\":\"\(pane)\",\"session_id\":\"\(session)\",\"agent_pid\":42,\"agent_start\":123,\"worker_pid\":43,\"worker_start\":124,\"state\":\"ready\",\"input_outcome_known\":\(known)}"
            let source = "#!/bin/sh\nprintf '%s' '\(response)'\n"
            try Data(source.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        try install(known: true)
        let client = RelayRotationRemoteStatusClient(profile: ConnectionProfile(host: "fixture"),
            sshExecutable: script)
        let value = try await client.read(paneID: pane, expectedSessionID: session)
        #expect(value.agentPID == 42)
        #expect(value.agentStart == 123)
        await #expect(throws: RelayRotationAdapterError.self) {
            try await client.read(paneID: pane, expectedSessionID: UUID().uuidString)
        }
        try install(known: false)
        await #expect(throws: RelayRotationAdapterError.self) {
            try await client.read(paneID: pane, expectedSessionID: session)
        }
    }
}

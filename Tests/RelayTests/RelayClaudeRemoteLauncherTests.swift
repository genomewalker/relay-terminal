import Foundation
import Testing
@testable import Relay

@Suite struct RelayClaudeRemoteLauncherTests {
    @Test func launchSendsPrivateArgumentsOnlyOnStandardInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-ssh")
        let argumentsFile = directory.appendingPathComponent("argv")
        let inputFile = directory.appendingPathComponent("stdin")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argumentsFile.path)'\n" +
            "cat > '\(inputFile.path)'\n" +
            "printf '{\"session_id\":\"session\",\"pane_id\":\"pane\"}'\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let launcher = RelayClaudeRemoteLauncher(profile: ConnectionProfile(host: "fixture"),
            sshExecutable: executable)
        let privateValue = "secret-setting-value"
        let sourceSession = UUID().uuidString.lowercased()
        try await launcher.launch(snapshotPath: "/private/launch.json",
            snapshotSHA256: String(repeating: "a", count: 64), intentID: "intent-1",
            sourceSessionID: sourceSession,
            plannedArguments: ["--settings", privateValue], expectedSessionID: "session",
            expectedPaneID: "pane")
        let sentArguments = try String(contentsOf: argumentsFile, encoding: .utf8)
        #expect(!sentArguments.contains(privateValue))
        #expect(sentArguments.contains("--source-session '" + sourceSession + "'"))
        let body = try JSONSerialization.jsonObject(with: Data(contentsOf: inputFile)) as? [String: [String]]
        #expect(body?["arguments"] == ["--settings", privateValue])
    }

    @Test func shellQuotesSnapshotPathAndRejectsMalformedDigest() throws {
        let command = try RelayClaudeRemoteLauncher.command(snapshotPath: "/private/a'b.json",
            snapshotSHA256: String(repeating: "a", count: 64), intentID: "intent-1",
            sourceSessionID: UUID().uuidString.lowercased())
        #expect(command.contains("a'\\''b.json"))
        #expect(throws: RelayRotationAdapterError.self) {
            try RelayClaudeRemoteLauncher.command(snapshotPath: "/private/snapshot",
                snapshotSHA256: "bad", intentID: "intent-1",
                sourceSessionID: UUID().uuidString.lowercased())
        }
    }
}

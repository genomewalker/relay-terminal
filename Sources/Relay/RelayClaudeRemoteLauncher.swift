import Foundation

/// One-shot remote launch ingress. The planned argv is sent only on stdin;
/// a lost reply is an unknown outcome and must be reconciled by pane ID.
struct RelayClaudeRemoteLauncher: Sendable {
    let sshArguments: [String]
    let sshExecutable: URL

    init(profile: ConnectionProfile, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        self.sshArguments = profile.sshConnectionArguments
        self.sshExecutable = sshExecutable
    }

    static func command(snapshotPath: String, snapshotSHA256: String,
                        intentID: String, sourceSessionID: String) throws -> String {
        guard snapshotPath.hasPrefix("/"), snapshotPath.utf8.count <= 4096,
              snapshotSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              intentID.range(of: #"^[A-Za-z0-9._:-]{1,110}$"#, options: .regularExpression) != nil,
              UUID(uuidString: sourceSessionID) != nil
        else { throw RelayRotationAdapterError.mismatchedEvidence }
        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return "$HOME/.local/bin/relayd rotation-launch --snapshot " + quoted(snapshotPath) +
            " --sha " + quoted(snapshotSHA256) + " --intent " + quoted(intentID) +
            " --source-session " + quoted(sourceSessionID)
    }

    func launch(snapshotPath: String, snapshotSHA256: String, intentID: String,
                sourceSessionID: String, plannedArguments: [String], expectedSessionID: String,
                expectedPaneID: String) async throws {
        guard !sshArguments.isEmpty, !plannedArguments.isEmpty,
              plannedArguments.count <= 256,
              plannedArguments.allSatisfy({ !$0.contains("\0") }),
              let input = try? JSONSerialization.data(withJSONObject: ["arguments": plannedArguments]),
              input.count <= 65_536 else { throw RelayRotationAdapterError.mismatchedEvidence }
        let command = try Self.command(snapshotPath: snapshotPath,
            snapshotSHA256: snapshotSHA256, intentID: intentID,
            sourceSessionID: sourceSessionID)
        let output = try await Task.detached {
            let process = Process()
            process.executableURL = sshExecutable
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"] +
                sshArguments + [command]
            process.standardInput = Pipe()
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout; process.standardError = stderr
            let result = try ProcessCapture.run(process, output: stdout, errors: stderr,
                input: input, timeout: 30, maximumBytesPerStream: 65_536)
            guard process.terminationStatus == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            return result.standardOutput
        }.value
        guard let value = try JSONSerialization.jsonObject(with: output) as? [String: String],
              value["session_id"] == expectedSessionID,
              value["pane_id"] == expectedPaneID else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }
}

import Foundation

struct RelayClaudeAgentEvidence: Decodable, Equatable, Sendable {
    let kind: String
    let sessionID: String
    let pid: Int
    let startedAt: Int64
    let cwd: String
    let status: String
    let waitingFor: String?

    private enum CodingKeys: String, CodingKey {
        case kind, pid, startedAt, cwd, status, waitingFor
        case sessionID = "sessionId"
    }
}

/// The CLI list is read only. Keep just the one exact interactive session;
/// an idle label alone never proves prompt readiness or empty input.
struct RelayClaudeAgentsClient: Sendable {
    let sshArguments: [String]
    let sshExecutable: URL

    init(profile: ConnectionProfile, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        sshArguments = profile.sshConnectionArguments
        self.sshExecutable = sshExecutable
    }

    func read(sessionID: String, expectedPID: Int, expectedCWD: String) async throws -> RelayClaudeAgentEvidence {
        guard !sshArguments.isEmpty, UUID(uuidString: sessionID) != nil,
              expectedPID > 0, expectedCWD.hasPrefix("/") else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let output = try await Task.detached {
            let process = Process()
            process.executableURL = sshExecutable
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"] +
                sshArguments + ["claude agents --json"]
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout; process.standardError = stderr
            let result = try ProcessCapture.run(process, output: stdout, errors: stderr,
                timeout: 12, maximumBytesPerStream: 131_072)
            guard process.terminationStatus == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            return result.standardOutput
        }.value
        guard let rows = try JSONSerialization.jsonObject(with: output) as? [[String: Any]],
              rows.count <= 512 else { throw RelayRotationAdapterError.mismatchedEvidence }
        let matches = rows.filter { ($0["sessionId"] as? String) == sessionID }
        guard matches.count == 1,
              let match = try? JSONSerialization.data(withJSONObject: matches[0]),
              let value = try? JSONDecoder().decode(RelayClaudeAgentEvidence.self, from: match),
              value.kind == "interactive", value.sessionID == sessionID,
              value.pid == expectedPID, value.startedAt > 0,
              value.cwd == expectedCWD, value.status == "idle",
              value.waitingFor == nil || value.waitingFor == "" else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return value
    }
}

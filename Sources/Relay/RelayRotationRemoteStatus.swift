import Foundation

struct RelayRotationRemoteStatus: Decodable, Equatable, Sendable {
    let paneID: String
    let sessionID: String
    let agentPID: Int
    let agentStart: UInt64
    let workerPID: Int
    let workerStart: UInt64
    let state: String
    let inputOutcomeKnown: Bool

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", sessionID = "session_id"
        case agentPID = "agent_pid", agentStart = "agent_start"
        case workerPID = "worker_pid", workerStart = "worker_start"
        case state, inputOutcomeKnown = "input_outcome_known"
    }

    var verifiedShape: Bool {
        UUID(uuidString: paneID) != nil && UUID(uuidString: sessionID) != nil &&
        agentPID > 0 && workerPID > 0 && state == "ready" &&
        agentStart > 0 && workerStart > 0
    }
}

/// Read-only daemon evidence. It does not prove idle, prompt readiness, or an
/// empty input line; those must be checked separately at the moment of send.
struct RelayRotationRemoteStatusClient: Sendable {
    let sshArguments: [String]
    let sshExecutable: URL

    init(profile: ConnectionProfile, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        sshArguments = profile.sshConnectionArguments
        self.sshExecutable = sshExecutable
    }

    func read(paneID: String, expectedSessionID: String) async throws -> RelayRotationRemoteStatus {
        guard !sshArguments.isEmpty, let pane = UUID(uuidString: paneID),
              let session = UUID(uuidString: expectedSessionID) else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let command = "$HOME/.local/bin/relayd rotation-status --pane " + pane.uuidString.lowercased()
        let output = try await Task.detached {
            let process = Process()
            process.executableURL = sshExecutable
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"] +
                sshArguments + [command]
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout; process.standardError = stderr
            let result = try ProcessCapture.run(process, output: stdout, errors: stderr,
                timeout: 12, maximumBytesPerStream: 65_536)
            guard process.terminationStatus == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            return result.standardOutput
        }.value
        let value = try JSONDecoder().decode(RelayRotationRemoteStatus.self, from: output)
        guard value.verifiedShape, value.inputOutcomeKnown,
              value.paneID.caseInsensitiveCompare(paneID) == .orderedSame,
              value.sessionID.caseInsensitiveCompare(session.uuidString) == .orderedSame else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return value
    }
}

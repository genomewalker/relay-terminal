import Foundation
import CryptoKit

/// Captures current effective Codex settings without user-entered parameters.
/// The returned record still requires separate Relay ownership and authenticated
/// App Server root/idle verification before it may be persisted as enrollment.
struct RelayCodexStartParametersClient: Sendable {
    let sshArguments: [String]
    let sshExecutable: URL

    init(profile: ConnectionProfile, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        sshArguments = profile.sshConnectionArguments
        self.sshExecutable = sshExecutable
    }

    func capture(candidate: RelayRetainedRotationEnrollment,
                 now: Date = Date()) async throws -> RelayRetainedRotationEnrollment {
        guard candidate.client == "codex", candidate.codexStart == nil,
              candidate.launchIdentityValid, !sshArguments.isEmpty,
              UUID(uuidString: candidate.sessionID) != nil,
              candidate.snapshotPath.range(of: #"^/[A-Za-z0-9_./-]{1,4095}$"#,
                  options: .regularExpression) != nil else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let command = "$HOME/.local/bin/relayd codex-start-parameters --snapshot '" +
            candidate.snapshotPath + "' --sha '" + candidate.snapshotSHA256 +
            "' --thread '" + candidate.sessionID + "'"
        let output = try await Task.detached {
            let process = Process()
            process.executableURL = sshExecutable
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"] +
                sshArguments + [command]
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout; process.standardError = stderr
            let result = try ProcessCapture.run(process, output: stdout, errors: stderr,
                timeout: 15, maximumBytesPerStream: 65_536)
            guard process.terminationStatus == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            return result.standardOutput
        }.value
        guard let value = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              value["source_thread_id"] as? String == candidate.sessionID,
              let turnID = value["source_turn_id"] as? String,
              let effort = value["effort"] as? String,
              let rolloutPath = value["rollout_path"] as? String, rolloutPath.hasPrefix("/"),
              let parameters = value["start_parameters"] as? [String: Any],
              JSONSerialization.isValidJSONObject(parameters) else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let data = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
        let config = RelayCodexStartConfiguration(sourceThreadID: candidate.sessionID,
            sourceTurnID: turnID, sourcePID: candidate.processID,
            sourceProcessStart: candidate.processStart, parameters: data, effort: effort,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            capturedAt: now)
        let enrollment = RelayRetainedRotationEnrollment(sessionID: candidate.sessionID,
            client: candidate.client, hostID: candidate.hostID, paneID: candidate.paneID,
            processID: candidate.processID, processStart: candidate.processStart,
            snapshotPath: candidate.snapshotPath, snapshotSHA256: candidate.snapshotSHA256,
            snapshot: candidate.snapshot, enrolledAt: now, codexStart: config)
        guard enrollment.valid else { throw RelayRotationAdapterError.mismatchedEvidence }
        return enrollment
    }
}

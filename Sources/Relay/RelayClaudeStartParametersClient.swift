import Foundation
import CryptoKit

/// Read-only effective settings capture for a live, exact Claude session.
/// The resulting private candidate still needs Relay ownership and prompt
/// attestation before enrollment is persisted or a lifecycle step is allowed.
struct RelayClaudeStartParametersClient: Sendable {
    let sshArguments: [String]
    let sshExecutable: URL

    init(profile: ConnectionProfile, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        sshArguments = profile.sshConnectionArguments
        self.sshExecutable = sshExecutable
    }

    func capture(candidate: RelayRetainedRotationEnrollment,
                 now: Date = Date()) async throws -> RelayRetainedRotationEnrollment {
        guard candidate.client == "claude", candidate.claudeStart == nil,
              candidate.launchIdentityValid, !sshArguments.isEmpty,
              UUID(uuidString: candidate.sessionID) != nil,
              candidate.snapshotPath.range(of: #"^/[A-Za-z0-9_./-]{1,4095}$"#,
                  options: .regularExpression) != nil else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let command = "$HOME/.local/bin/relayd claude-start-parameters --snapshot '" +
            candidate.snapshotPath + "' --sha '" + candidate.snapshotSHA256 +
            "' --session '" + candidate.sessionID + "'"
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
              value["session_id"] as? String == candidate.sessionID,
              value["pane_id"] as? String == candidate.paneID,
              value["source_pid"] as? Int == candidate.processID,
              value["source_start"] as? String == candidate.processStart,
              let timestamp = value["captured_at"] as? String,
              let capturedAt = Self.parseDate(timestamp),
              now.timeIntervalSince(capturedAt) >= 0,
              now.timeIntervalSince(capturedAt) <= 30 else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let payload = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let config = RelayClaudeStartConfiguration(sourceSessionID: candidate.sessionID,
            sourcePID: candidate.processID, sourceProcessStart: candidate.processStart,
            payload: payload,
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            capturedAt: capturedAt)
        let enrollment = RelayRetainedRotationEnrollment(sessionID: candidate.sessionID,
            client: candidate.client, hostID: candidate.hostID, paneID: candidate.paneID,
            processID: candidate.processID, processStart: candidate.processStart,
            snapshotPath: candidate.snapshotPath, snapshotSHA256: candidate.snapshotSHA256,
            snapshot: candidate.snapshot, enrolledAt: now, claudeStart: config)
        guard enrollment.valid else { throw RelayRotationAdapterError.mismatchedEvidence }
        return enrollment
    }

    private static func parseDate(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = parser.date(from: text) { return value }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }
}

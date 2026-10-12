import Foundation

struct RelayCodexRemoteRuntime: Decodable, Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let executable: String
    let workingDirectory: String
    let sourcePID: Int
    let sourceStart: String

    private enum CodingKeys: String, CodingKey {
        case path, device, inode, executable
        case workingDirectory = "working_directory"
        case sourcePID = "source_pid", sourceStart = "source_start"
    }
}

/// Read-only binding for the live remote Codex control socket. A separate
/// authenticated probe must recheck device/inode before thread creation.
struct RelayCodexRemoteRuntimeClient: Sendable {
    let sshArguments: [String]
    let sshExecutable: URL

    init(profile: ConnectionProfile, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        sshArguments = profile.sshConnectionArguments
        self.sshExecutable = sshExecutable
    }

    func read(enrollment: RelayRetainedRotationEnrollment) async throws -> RelayCodexRemoteRuntime {
        guard enrollment.valid, enrollment.client == "codex", !sshArguments.isEmpty,
              let snapshot = try? JSONSerialization.jsonObject(with: enrollment.snapshot) as? [String: Any],
              let cwd = snapshot["cwd"] as? String,
              let executable = snapshot["executable"] as? String,
              enrollment.snapshotPath.range(of: #"^/[A-Za-z0-9_./-]{1,4095}$"#,
                  options: .regularExpression) != nil else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let command = "$HOME/.local/bin/relayd codex-runtime --snapshot '" + enrollment.snapshotPath +
            "' --sha '" + enrollment.snapshotSHA256 + "'"
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
        let runtime = try JSONDecoder().decode(RelayCodexRemoteRuntime.self, from: output)
        guard runtime.path.hasPrefix("/"), runtime.path.utf8.count <= 4096,
              runtime.device > 0, runtime.inode > 0,
              runtime.executable == executable, runtime.workingDirectory == cwd,
              runtime.sourcePID == enrollment.processID,
              runtime.sourceStart == enrollment.processStart else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return runtime
    }
}

import Foundation
import CryptoKit

/// Unlike the separate dollar-policy interface, this accepts the public nested
/// status and returns rotate/hold/abstain plus v1 rotation_signal arguments.
protocol RelayContextRotationPolicy: Sendable {
    func evaluate(status: Data, now: Date) async throws -> Data
}

struct RelayPinnedContextRotationPolicy: RelayContextRotationPolicy {
    let pythonExecutable: URL
    let policyFile: URL
    let reviewedSHA256: String

    static func bundled(pythonExecutable: URL) -> Self? {
        guard let file = RelayResources.bundle?.url(forResource: "policy", withExtension: "py",
                                                   subdirectory: "Rotation") else { return nil }
        return Self(pythonExecutable: pythonExecutable, policyFile: file,
            reviewedSHA256: "cb6cf0ee65b4d0110354196733f8fedc004e3c64cfb480e10e201e62cbc32d3a")
    }

    func evaluate(status: Data, now: Date) async throws -> Data {
        guard status.count <= 262_144,
              reviewedSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970 >= 0,
              now.timeIntervalSince1970 < Double(Int64.max / 1000) else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let source = try Data(contentsOf: policyFile, options: .mappedIfSafe)
        guard source.count <= 65_536,
              SHA256.hash(data: source).map({ String(format: "%02x", $0) }).joined() == reviewedSHA256,
              let code = String(data: source, encoding: .utf8) else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        // Execute the verified bytes rather than reopen a mutable policy path.
        return try await Task.detached {
            let process = Process()
            process.executableURL = pythonExecutable
            process.arguments = ["-I", "-S", "-c", code, "--now-ms",
                String(Int64(now.timeIntervalSince1970 * 1000))]
            let output = Pipe(), errors = Pipe()
            process.standardInput = Pipe()
            process.standardOutput = output; process.standardError = errors
            let result = try ProcessCapture.run(process, output: output, errors: errors,
                input: status, timeout: 5, maximumBytesPerStream: 65_536)
            guard process.terminationStatus == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            return result.standardOutput
        }.value
    }
}

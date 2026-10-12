import Foundation

/// Chitta owns the usage decision and capsule. Relay only admits an exact,
/// durable handoff before a separate lifecycle executor may act on it.
struct RelayChittaRotationSignal: Decodable, Sendable {
    let schema: Int
    let eventID: String
    let sessionID: String
    let action: String
    let capsuleRequired: Bool
    let rotationRequested: Bool
    let lifecyclePerformed: Bool
}

struct RelayChittaCapsule: Decodable, Sendable {
    let version: Int
    let sessionID: String
    let projectDir: String
    let codeHead: String
    let revision: Int
    let state: String
    let objective: String
    let nextAction: String
}

struct RelayChittaCapsuleRead: Decodable, Sendable {
    let status: String
    let capsule: RelayChittaCapsule
}

enum RelayChittaRotationGate {
    static func admits(
        signal: RelayChittaRotationSignal,
        capsule: RelayChittaCapsuleRead,
        identity: RelaySupervisedSessionID,
        projectDir: String,
        codeHead: String,
        turnIdle: Bool
    ) -> Bool {
        signal.schema == 1 && signal.action == "rotate" &&
            signal.capsuleRequired && signal.rotationRequested && !signal.lifecyclePerformed &&
            !signal.eventID.isEmpty && signal.eventID.utf8.count <= 110 &&
            signal.sessionID == identity.sessionID && turnIdle &&
            capsule.status == "ok" && capsule.capsule.version == 2 &&
            capsule.capsule.sessionID == identity.sessionID &&
            capsule.capsule.projectDir == projectDir &&
            capsule.capsule.codeHead == codeHead &&
            capsule.capsule.revision > 0 && capsule.capsule.state == "in_progress" &&
            !capsule.capsule.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !capsule.capsule.nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum RelayChittaCapsuleGateway {
    private struct Envelope: Decodable { let value: RelayChittaCapsuleRead }

    static func read(sessionID: String, projectDir: String, codeHead: String) throws -> RelayChittaCapsuleRead {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 110,
              projectDir.hasPrefix("/"), codeHead.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let args = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionID, "project_dir": projectDir, "code_head": codeHead
        ])
        let process = Process()
        process.executableURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/bin/chitta")
        process.arguments = ["ledger_op", "--op", "capsule_get", "--args",
                             String(decoding: args, as: UTF8.self), "--json"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        let result = try ProcessCapture.run(process, output: output, errors: errors,
                                            timeout: 15, maximumBytesPerStream: 8_192)
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Envelope.self, from: result.standardOutput).value
    }
}

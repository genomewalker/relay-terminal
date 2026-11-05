import Foundation
import CryptoKit

protocol RelayRotationTransport: Sendable {
    func ledger(_ operation: String, arguments: Data) async throws -> Data
    func backend(_ operation: String, arguments: Data) async throws -> Data
}

struct RelayCodexRotationBinding: Sendable {
    let projectDir: String
    let sourceStartParameters: Data
    let capsule: Data
}

enum RelayRotationAdapterError: Error { case mismatchedEvidence }

/// Concrete public-ledger and app-server wiring. Enrollment supplies the exact
/// original start parameters; the adapter never invents permission defaults.
struct RelayCodexRotationLifecycle: RelayRotationLifecycle {
    let client = "codex"
    let transport: any RelayRotationTransport
    let binding: RelayCodexRotationBinding

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return value
    }
    private func fenced(_ admission: RelayRotationAdmission) -> [String: Any] {
        ["session_id": admission.sourceThreadID, "epoch": admission.epoch,
         "claim_id": admission.claimID, "token": admission.fencingToken]
    }
    private func status(_ admission: RelayRotationAdmission) async throws -> [String: Any] {
        try object(await transport.ledger("rotation_status", arguments: encode([
            "session_id": admission.sourceThreadID, "epoch": admission.epoch])))
    }
    private func verifyCapsule(_ admission: RelayRotationAdmission) async throws {
        let read = try object(await transport.ledger("capsule_get", arguments: encode([
            "session_id": admission.sourceThreadID, "project_dir": binding.projectDir,
            "code_head": admission.codeHead])))
        let expected = try object(binding.capsule)
        guard read["status"] as? String == "ok", let current = read["capsule"] as? [String: Any],
              current["version"] as? Int == 2,
              current["state"] as? String == "in_progress",
              let objective = current["objective"] as? String, !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let nextAction = current["next_action"] as? String, !nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              current["session_id"] as? String == admission.sourceThreadID,
              current["project_dir"] as? String == binding.projectDir,
              current["code_head"] as? String == admission.codeHead,
              current["revision"] as? Int == admission.capsuleRevision,
              current["ledger_seq"] as? Int == admission.completedTurnSequence,
              try encode(current) == encode(expected) else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }
    func validate(_ admission: RelayRotationAdmission) async throws {
        guard admission.admits(now: Date()) else { throw RelayRotationAdapterError.mismatchedEvidence }
        let value = try await status(admission)
        guard value["v"] as? Int == 1, value["session_id"] as? String == admission.sourceThreadID,
              value["epoch"] as? String == admission.epoch, value["owner"] as? String == "relay",
              value["client"] as? String == "codex", value["cwd"] as? String == binding.projectDir,
              value["turn_seq"] as? Int == admission.completedTurnSequence,
              let signal = value["signal"] as? [String: Any],
              signal["action"] as? String == "rotate",
              signal["seq"] as? Int == admission.signalSequence,
              value["live"] as? Bool == true,
              let claim = value["claim"] as? [String: Any],
              claim["claim_id"] as? String == admission.claimID,
              claim["token"] as? Int == admission.fencingToken,
              claim["expected_seq"] as? Int == admission.completedTurnSequence,
              let capsule = value["capsule"] as? [String: Any],
              capsule["token"] as? Int == admission.fencingToken,
              capsule["revision"] as? Int == admission.capsuleRevision,
              capsule["code_head"] as? String == admission.codeHead,
              capsule["ledger_seq"] as? Int == admission.completedTurnSequence else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        try await verifyCapsule(admission)
        let source = try object(await transport.backend("inspect", arguments: encode([
            "thread_id": admission.sourceThreadID, "cwd": binding.projectDir, "code_head": admission.codeHead])))
        guard source["idle"] as? Bool == true, source["root"] as? Bool == true,
              source["no_descendants"] as? Bool == true else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }
    func persistIntent(_ admission: RelayRotationAdmission, intentID: String) async throws {
        try await validate(admission)
        var args = fenced(admission); args["intent_id"] = intentID
        let result = try object(await transport.ledger("rotation_intent", arguments: encode(args)))
        guard result["intent_id"] as? String == intentID,
              result["token"] as? Int == admission.fencingToken,
              result["state"] as? String == "ambiguous" else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }
    func startFreshThread(_ admission: RelayRotationAdmission, intentID: String) async throws -> String {
        try await validate(admission)
        let params = try object(binding.sourceStartParameters)
        guard params["cwd"] as? String == binding.projectDir,
              params["model"] as? String != nil,
              params["approvalPolicy"] != nil,
              (params["sandbox"] != nil) != (params["permissions"] != nil) else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let result = try object(await transport.backend("start", arguments: encode([
            "source_thread_id": admission.sourceThreadID, "cwd": binding.projectDir, "code_head": admission.codeHead,
            "start_parameters": params, "intent_id": intentID])))
        guard let thread = result["thread_id"] as? String,
              result["session_id"] as? String == thread else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return thread
    }
    func bind(_ admission: RelayRotationAdmission, intentID: String, freshThreadID: String) async throws {
        try await validate(admission)
        var args = fenced(admission); args["intent_id"] = intentID; args["new_session_id"] = freshThreadID
        let result = try object(await transport.ledger("rotation_bind", arguments: encode(args)))
        guard result["state"] as? String == "bound", result["new_session_id"] as? String == freshThreadID else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }
    func loadCapsuleAndCompleteFirstTurn(_ admission: RelayRotationAdmission, freshThreadID: String) async throws {
        try await validate(admission)
        let state = try await status(admission)
        guard let intent = state["intent"] as? [String: Any],
              intent["state"] as? String == "bound",
              intent["claim_id"] as? String == admission.claimID,
              intent["token"] as? Int == admission.fencingToken,
              intent["new_session_id"] as? String == freshThreadID else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let capsule = try encode(object(binding.capsule))
        let digest = SHA256.hash(data: capsule).map { String(format: "%02x", $0) }.joined()
        let result = try object(await transport.backend("load", arguments: encode([
            "thread_id": freshThreadID, "cwd": binding.projectDir,
            "capsule": String(decoding: capsule, as: UTF8.self), "sha256": digest])))
        guard result["thread_id"] as? String == freshThreadID,
              result["completed"] as? Bool == true, result["sha256"] as? String == digest else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }
    func acknowledge(_ admission: RelayRotationAdmission, intentID: String, freshThreadID: String) async throws {
        try await validate(admission)
        var args = fenced(admission); args["intent_id"] = intentID
        args["new_session_id"] = freshThreadID; args["capsule_revision"] = admission.capsuleRevision
        let ack = try object(await transport.ledger("rotation_ack", arguments: encode(args)))
        guard ack["new_session_id"] as? String == freshThreadID, ack["lifecycle_performed"] as? Bool == true else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }
    func retire(_ admission: RelayRotationAdmission, freshThreadID: String) async throws {
        let value = try await status(admission)
        guard value["session_id"] as? String == admission.sourceThreadID,
              value["epoch"] as? String == admission.epoch,
              value["owner"] as? String == "relay",
              let ack = value["ack"] as? [String: Any],
              ack["claim_id"] as? String == admission.claimID,
              ack["token"] as? Int == admission.fencingToken,
              ack["capsule_revision"] as? Int == admission.capsuleRevision,
              ack["new_session_id"] as? String == freshThreadID,
              ack["lifecycle_performed"] as? Bool == true else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let archived = try object(await transport.backend("archive", arguments: encode([
            "thread_id": admission.sourceThreadID, "cwd": binding.projectDir, "code_head": admission.codeHead])))
        guard archived["thread_id"] as? String == admission.sourceThreadID,
              archived["archived"] as? Bool == true else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }
}

/// Ledger calls use the existing installed Chitta executable; lifecycle calls
/// use the native app-server adapter. Unknown outcomes propagate.
struct RelayRotationProcessTransport: RelayRotationTransport {
    let chittaExecutable: URL
    let socketPath: String
    let socketDevice: UInt64
    let socketInode: UInt64

    func ledger(_ operation: String, arguments: Data) async throws -> Data {
        try await run(chittaExecutable, arguments: ["ledger_op", "--op", operation,
            "--args", String(decoding: arguments, as: UTF8.self), "--json"], input: nil, envelope: true)
    }
    func backend(_ operation: String, arguments: Data) async throws -> Data {
        let (path, device, inode) = (socketPath, socketDevice, socketInode)
        return try await Task.detached {
            do {
                return try RelayCodexRotationBackend.perform(operation: operation, socketPath: path,
                    device: device, inode: inode, request: arguments)
            } catch { throw RelayRotationAdapterError.mismatchedEvidence }
        }.value
    }
    private func run(_ executable: URL, arguments: [String], input: Data?, envelope: Bool) async throws -> Data {
        try await Task.detached {
            let process = Process(); process.executableURL = executable; process.arguments = arguments
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output; process.standardError = errors
            if input == nil { process.standardInput = FileHandle.nullDevice }
            else { process.standardInput = Pipe() }
            let result = try ProcessCapture.run(process, output: output, errors: errors,
                input: input, timeout: 120, maximumBytesPerStream: 65_536)
            guard process.terminationStatus == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            if envelope {
                guard let object = try JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
                      let value = object["value"] else { throw RelayRotationAdapterError.mismatchedEvidence }
                return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
            }
            return result.standardOutput
        }.value
    }
}

import Foundation
import CryptoKit

/// Private launch snapshots are separate from the compact task capsule.
struct RelayClaudeRotationBinding: Sendable {
    let projectDir: String
    let snapshotPath: String
    let snapshotSHA256: String
    let sourcePaneID: String
    let sourcePID: Int
    let sourceProcessStart: String
    let capsule: Data

    var isValid: Bool {
        projectDir.hasPrefix("/") && snapshotPath.hasPrefix("/") &&
        snapshotSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil &&
        UUID(uuidString: sourcePaneID) != nil && sourcePID > 0 &&
        !sourceProcessStart.isEmpty && sourceProcessStart.allSatisfy(\.isNumber) && capsule.count <= 65536
    }
}

/// Fenced Claude lifecycle. Physical launch/input remains an injected backend;
/// the live factory must stay disabled until its throwaway-session check passes.
struct RelayClaudeRotationLifecycle: RelayRotationLifecycle {
    let client = "claude"
    let transport: any RelayRotationTransport
    let binding: RelayClaudeRotationBinding

    static func sessionID(for intentID: String) -> String {
        var namespace = UUID(uuidString: "5f1b7c1e-3a0e-4d2b-9a57-2c4f1f0e9b11")!.uuid
        let bytes = withUnsafeBytes(of: &namespace) { Data($0) } + Data(intentID.utf8)
        var digest = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
                           digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15])).uuidString.lowercased()
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
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
        guard admission.client == client, binding.isValid, admission.admits(now: Date()) else { throw RelayRotationAdapterError.mismatchedEvidence }
        let value = try await status(admission)
        guard value["v"] as? Int == 1, value["session_id"] as? String == admission.sourceThreadID,
              value["epoch"] as? String == admission.epoch, value["owner"] as? String == "relay",
              value["client"] as? String == "claude", value["cwd"] as? String == binding.projectDir,
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
            "thread_id": admission.sourceThreadID, "cwd": binding.projectDir, "code_head": admission.codeHead,
            "source_pane_id": binding.sourcePaneID, "source_pid": binding.sourcePID,
            "source_process_start": binding.sourceProcessStart])))
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
        let expected = Self.sessionID(for: intentID)
        let result = try object(await transport.backend("start", arguments: encode([
            "source_thread_id": admission.sourceThreadID, "cwd": binding.projectDir,
            "code_head": admission.codeHead, "intent_id": intentID, "session_id": expected,
            "snapshot_path": binding.snapshotPath, "snapshot_sha256": binding.snapshotSHA256,
            "source_pane_id": binding.sourcePaneID, "source_pid": binding.sourcePID,
            "source_process_start": binding.sourceProcessStart])))
        guard let thread = result["thread_id"] as? String, thread == expected,
              result["session_id"] as? String == thread,
              result["dedicated_pane"] as? Bool == true,
              result["snapshot_sha256"] as? String == binding.snapshotSHA256 else {
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
            "capsule": String(decoding: capsule, as: UTF8.self), "sha256": digest,
            "source_thread_id": admission.sourceThreadID, "intent_id": admission.claimID,
            "capsule_revision": admission.capsuleRevision, "receipt_only": true])))
        guard result["thread_id"] as? String == freshThreadID,
              result["completed"] as? Bool == true, result["sha256"] as? String == digest,
              result["intent_id"] as? String == admission.claimID,
              result["capsule_revision"] as? Int == admission.capsuleRevision,
              result["receipt_verified"] as? Bool == true, result["owner"] as? String == "relay" else {
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
            "thread_id": admission.sourceThreadID, "cwd": binding.projectDir, "code_head": admission.codeHead,
            "source_pane_id": binding.sourcePaneID, "source_pid": binding.sourcePID,
            "source_process_start": binding.sourceProcessStart, "fresh_thread_id": freshThreadID,
            "intent_id": admission.claimID, "epoch": admission.epoch,
            "token": admission.fencingToken, "capsule_revision": admission.capsuleRevision,
            "ack_verified": true])))
        guard archived["thread_id"] as? String == admission.sourceThreadID,
              archived["archived"] as? Bool == true else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }
}

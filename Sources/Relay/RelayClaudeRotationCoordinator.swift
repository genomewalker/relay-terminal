import Foundation
import CryptoKit

struct RelayClaudePhysicalSession: Codable, Equatable, Sendable {
    let sessionID: String
    let paneID: String
    let pid: Int
    let processStart: String
    let startedAtMilliseconds: Int64
    let cwd: String
    let idle: Bool
    let inputEmpty: Bool
    let noDescendants: Bool
    /// Attested from the live PTY screen, not from the agent registry's idle bit.
    let promptReady: Bool

    var incarnation: [String: Any] {
        ["session_id": sessionID, "pid": pid, "started_at_ms": startedAtMilliseconds]
    }
}

/// Implemented by the native Relay host. Input must compare the supplied
/// incarnation and empty input buffer immediately before writing. A missing
/// response is an unknown outcome; implementations must never retry input.
protocol RelayClaudeRotationHost: Sendable {
    func snapshot(at path: String) async throws -> Data
    func codeHead(projectDir: String) async throws -> String
    /// Must prove this exact Bash command runs without an interactive approval
    /// prompt under the captured settings. Unknown/manual modes return false.
    func receiptToolAuthorized(_ command: String, for session: RelayClaudePhysicalSession) async throws -> Bool
    func session(paneID: String, sessionID: String) async throws -> RelayClaudePhysicalSession?
    func launchDedicated(paneID: String, sessionID: String, intentID: String,
                         executable: String, arguments: [String], cwd: String) async throws
    func enrollRelayOwned(_ session: RelayClaudePhysicalSession, intentID: String) async throws
    func sendOnce(_ text: String, to session: RelayClaudePhysicalSession) async throws
    func waitForCompletedTurn(_ session: RelayClaudePhysicalSession) async throws
    func waitForExit(_ session: RelayClaudePhysicalSession) async throws
}

/// Executes the physical steps through native host callbacks. The host factory
/// is deliberately separate from stateless Python plans and remains disabled
/// until real launch/input/exit callbacks have passed a throwaway-session test.
actor RelayClaudeRotationCoordinator: RelayRotationTransport {
    private struct LaunchReceipt: Codable {
        let old: RelayClaudePhysicalSession
        let fresh: RelayClaudePhysicalSession
    }
    private let enrollment: RelayRetainedRotationEnrollment
    private let helper: RelayClaudeRotationJSONBackend
    private let host: any RelayClaudeRotationHost
    private let ledgerTransport: any RelayRotationTransport
    private let actions: RelayClaudeRotationActionStore
    private var operating = false

    init(enrollment: RelayRetainedRotationEnrollment, helper: RelayClaudeRotationJSONBackend,
         host: any RelayClaudeRotationHost, ledgerTransport: any RelayRotationTransport,
         actions: RelayClaudeRotationActionStore) {
        self.enrollment = enrollment; self.helper = helper; self.host = host
        self.ledgerTransport = ledgerTransport; self.actions = actions
    }

    func ledger(_ operation: String, arguments: Data) async throws -> Data {
        try await ledgerTransport.ledger(operation, arguments: arguments)
    }

    func backend(_ operation: String, arguments: Data) async throws -> Data {
        guard !operating, enrollment.valid, enrollment.client == "claude", arguments.count <= 65536 else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        operating = true; defer { operating = false }
        let args = try object(arguments)
        if let cwd = args["cwd"] as? String, let expectedHead = args["code_head"] as? String {
            guard try await host.codeHead(projectDir: cwd) == expectedHead else {
                throw RelayRotationAdapterError.mismatchedEvidence
            }
        }
        switch operation {
        case "inspect":
            try matchSource(args)
            guard args["thread_id"] as? String == enrollment.sessionID else { throw RelayRotationAdapterError.mismatchedEvidence }
            let current = try await source()
            guard args["cwd"] as? String == current.cwd else { throw RelayRotationAdapterError.mismatchedEvidence }
            return try encode(["idle": true, "root": true, "no_descendants": true])
        case "start": return try await start(args)
        case "load": return try await load(args)
        case "archive": return try await archive(args)
        default: throw RelayRotationAdapterError.mismatchedEvidence
        }
    }

    private func source() async throws -> RelayClaudePhysicalSession {
        guard let current = try await host.session(paneID: enrollment.paneID, sessionID: enrollment.sessionID),
              current.sessionID == enrollment.sessionID, current.paneID == enrollment.paneID,
              current.pid == enrollment.processID, current.processStart == enrollment.processStart,
              current.idle, current.inputEmpty, current.noDescendants, current.promptReady else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return current
    }

    private func matchSource(_ args: [String: Any]) throws {
        guard args["source_pane_id"] as? String == enrollment.paneID,
              args["source_pid"] as? Int == enrollment.processID,
              args["source_process_start"] as? String == enrollment.processStart else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }

    private func start(_ args: [String: Any]) async throws -> Data {
        try matchSource(args)
        guard args["source_thread_id"] as? String == enrollment.sessionID,
              args["snapshot_path"] as? String == enrollment.snapshotPath,
              args["snapshot_sha256"] as? String == enrollment.snapshotSHA256,
              let intent = args["intent_id"] as? String, !intent.isEmpty else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let old = try await source()
        let snapshot = try await host.snapshot(at: enrollment.snapshotPath)
        guard snapshot == enrollment.snapshot, sha(snapshot) == enrollment.snapshotSHA256 else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let launch = try object(snapshot)
        guard let executable = launch["executable"] as? String,
              let cwd = launch["cwd"] as? String, old.cwd == cwd, args["cwd"] as? String == cwd,
              let settings = launch["arguments"] as? [String: Any], settings["reusable"] as? Bool == true,
              let freshArgs = settings["fresh_args"] as? [String] else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let plan = try await request(.planStart, ["intent_id": intent, "fresh_argv": freshArgs, "cwd": cwd])
        let sid = RelayClaudeRotationLifecycle.sessionID(for: intent)
        let pane = RelayClaudeRotationLifecycle.sessionID(for: intent + ":pane")
        guard plan["session_id"] as? String == sid, args["session_id"] as? String == sid,
              plan["cwd"] as? String == cwd, let argv = plan["argv"] as? [String] else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let fingerprint = enrollment.snapshotSHA256
        let claimed = try actions.claim(intent: intent, action: "start", fingerprint: fingerprint)
        if claimed {
            // The claim is durable before launch. A thrown/lost launch response
            // leaves this claim consumed; subsequent calls inspect this pane.
            try await host.launchDedicated(paneID: pane, sessionID: sid, intentID: intent,
                                           executable: executable, arguments: argv, cwd: cwd)
        } else {
            guard try actions.read(intent: intent, action: "start")?.fingerprint == fingerprint else {
                throw RelayRotationAdapterError.mismatchedEvidence
            }
        }
        guard let fresh = try await host.session(paneID: pane, sessionID: sid),
              fresh.paneID == pane, fresh.sessionID == sid, fresh.cwd == cwd else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let confirmation = try await request(.confirm, ["intent_id": intent, "pane_pid": fresh.pid])
        guard confirmation["confirmed"] as? Bool == true,
              let incarnation = confirmation["incarnation"] as? [String: Any],
              incarnation["session_id"] as? String == sid, incarnation["pid"] as? Int == fresh.pid,
              incarnation["started_at_ms"] as? Int64 == fresh.startedAtMilliseconds else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        if !claimed, let record = try actions.read(intent: intent, action: "start"), record.completed,
           let data = record.result {
            let saved = try JSONDecoder().decode(LaunchReceipt.self, from: data)
            guard saved.fresh.pid == fresh.pid, saved.fresh.processStart == fresh.processStart,
                  saved.fresh.startedAtMilliseconds == fresh.startedAtMilliseconds else {
                throw RelayRotationAdapterError.mismatchedEvidence
            }
            return try encode(["thread_id": sid, "session_id": sid, "dedicated_pane": true,
                               "snapshot_sha256": enrollment.snapshotSHA256])
        }
        let receipt = try JSONEncoder().encode(LaunchReceipt(old: old, fresh: fresh))
        try actions.complete(intent: intent, action: "start", fingerprint: fingerprint, result: receipt)
        return try encode(["thread_id": sid, "session_id": sid, "dedicated_pane": true,
                           "snapshot_sha256": enrollment.snapshotSHA256])
    }

    private func launchReceipt(_ intent: String) throws -> LaunchReceipt {
        guard let record = try actions.read(intent: intent, action: "start"), record.completed,
              record.fingerprint == enrollment.snapshotSHA256, let result = record.result else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return try JSONDecoder().decode(LaunchReceipt.self, from: result)
    }

    private func freshSession(_ receipt: LaunchReceipt) async throws -> RelayClaudePhysicalSession {
        let expected = receipt.fresh
        guard let current = try await host.session(paneID: expected.paneID, sessionID: expected.sessionID),
              current.pid == expected.pid, current.processStart == expected.processStart,
              current.startedAtMilliseconds == expected.startedAtMilliseconds,
              current.paneID == expected.paneID, current.sessionID == expected.sessionID else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return current
    }

    private func load(_ args: [String: Any]) async throws -> Data {
        guard let intent = args["intent_id"] as? String, let text = args["capsule"] as? String,
              let expectedDigest = args["sha256"] as? String, sha(Data(text.utf8)) == expectedDigest,
              args["receipt_only"] as? Bool == true,
              args["source_thread_id"] as? String == enrollment.sessionID else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let receipt = try launchReceipt(intent)
        let fresh = try await freshSession(receipt)
        guard args["thread_id"] as? String == fresh.sessionID else { throw RelayRotationAdapterError.mismatchedEvidence }
        let capsule = try object(Data(text.utf8))
        guard let revision = args["capsule_revision"] as? Int, revision > 0,
              capsule["revision"] as? Int == revision,
              let expectedHead = capsule["code_head"] as? String,
              try await host.codeHead(projectDir: fresh.cwd) == expectedHead else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let plan = try await request(.receiptPlan, ["intent_id": intent, "old_session_id": enrollment.sessionID,
                                                   "project_dir": fresh.cwd, "capsule": capsule])
        guard plan["expected_digest"] as? String == expectedDigest,
              let command = plan["command"] as? String, let line = plan["expected_line"] as? String,
              let prompt = plan["prompt"] as? String else { throw RelayRotationAdapterError.mismatchedEvidence }
        let fingerprint = sha(Data((expectedDigest + "\u{0}" + command).utf8))
        guard fresh.promptReady,
              try await host.receiptToolAuthorized(command, for: fresh) else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        try await host.enrollRelayOwned(fresh, intentID: intent)
        if try actions.read(intent: intent, action: "receipt") == nil {
            guard fresh.idle, fresh.inputEmpty, fresh.noDescendants, fresh.promptReady else { throw RelayRotationAdapterError.mismatchedEvidence }
        }
        if try actions.claim(intent: intent, action: "receipt", fingerprint: fingerprint) {
            try await host.sendOnce(prompt, to: fresh)
        } else {
            guard try actions.read(intent: intent, action: "receipt")?.fingerprint == fingerprint else {
                throw RelayRotationAdapterError.mismatchedEvidence
            }
        }
        try await host.waitForCompletedTurn(fresh)
        let current = try await freshSession(receipt)
        let verified = try await request(.verifyReceipt, ["command": command, "expected_line": line,
            "expected_digest": expectedDigest, "incarnation": current.incarnation, "pane_pid": current.pid])
        guard verified["verified"] as? Bool == true else { throw RelayRotationAdapterError.mismatchedEvidence }
        let result = try encode(["thread_id": fresh.sessionID, "completed": true, "sha256": expectedDigest,
            "intent_id": intent, "capsule_revision": args["capsule_revision"]!,
            "receipt_verified": true, "owner": "relay"])
        try actions.complete(intent: intent, action: "receipt", fingerprint: fingerprint, result: result)
        return result
    }

    private func archive(_ args: [String: Any]) async throws -> Data {
        try matchSource(args)
        guard let intent = args["intent_id"] as? String,
              args["thread_id"] as? String == enrollment.sessionID else { throw RelayRotationAdapterError.mismatchedEvidence }
        let receipt = try launchReceipt(intent)
        _ = try await freshSession(receipt)
        guard args["fresh_thread_id"] as? String == receipt.fresh.sessionID,
              try actions.read(intent: intent, action: "receipt")?.completed == true else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let status = try object(await ledger("rotation_status", arguments: encode(["session_id": enrollment.sessionID])))
        guard let epoch = args["epoch"] as? String, !epoch.isEmpty,
              let token = args["token"] as? Int, token > 0,
              let revision = args["capsule_revision"] as? Int, revision > 0 else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        guard status["owner"] as? String == "relay", status["client"] as? String == "claude",
              status["session_id"] as? String == enrollment.sessionID, status["epoch"] as? String == epoch,
              let ack = status["ack"] as? [String: Any], ack["claim_id"] as? String == intent,
              ack["token"] as? Int == token,
              ack["capsule_revision"] as? Int == revision,
              ack["new_session_id"] as? String == receipt.fresh.sessionID,
              ack["lifecycle_performed"] as? Bool == true else { throw RelayRotationAdapterError.mismatchedEvidence }
        let fingerprint = enrollment.snapshotSHA256
        if try actions.read(intent: intent, action: "exit") == nil {
            let old = try await source()
            guard old.startedAtMilliseconds == receipt.old.startedAtMilliseconds else { throw RelayRotationAdapterError.mismatchedEvidence }
            let preflight = try await request(.retirePreflight, ["old": old.incarnation, "pane_pid": old.pid])
            guard preflight["allowed"] as? Bool == true, preflight["text"] as? String == "/exit" else {
                throw RelayRotationAdapterError.mismatchedEvidence
            }
            if try actions.claim(intent: intent, action: "exit", fingerprint: fingerprint) {
                try await host.sendOnce("/exit", to: old)
            }
        }
        guard try actions.read(intent: intent, action: "exit")?.fingerprint == fingerprint else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        try await host.waitForExit(receipt.old)
        var confirmedRetired = false
        for attempt in 0..<20 {
            let retired = try await request(.retired, ["old": receipt.old.incarnation])
            guard let isRetired = retired["retired"] as? Bool else {
                throw RelayRotationAdapterError.mismatchedEvidence
            }
            if isRetired { confirmedRetired = true; break }
            if attempt < 19 { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        guard confirmedRetired else { throw RelayRotationAdapterError.mismatchedEvidence }
        let result = try encode(["thread_id": enrollment.sessionID, "archived": true])
        try actions.complete(intent: intent, action: "exit", fingerprint: fingerprint, result: result)
        return result
    }

    /// Called by the runtime only after the executor records oldThreadRetired.
    func continueFresh(intentID: String) async throws {
        guard !operating, try actions.read(intent: intentID, action: "exit")?.completed == true else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        operating = true; defer { operating = false }
        let receipt = try launchReceipt(intentID)
        let fresh = try await freshSession(receipt)
        guard fresh.idle, fresh.inputEmpty, fresh.noDescendants, fresh.promptReady else { throw RelayRotationAdapterError.mismatchedEvidence }
        let plan = try await request(.continuationPlan, ["intent_id": intentID])
        guard let prompt = plan["prompt"] as? String else { throw RelayRotationAdapterError.mismatchedEvidence }
        let fingerprint = sha(Data(prompt.utf8))
        guard try actions.claim(intent: intentID, action: "continue", fingerprint: fingerprint) else {
            guard let old = try actions.read(intent: intentID, action: "continue"),
                  old.fingerprint == fingerprint, old.completed else { throw RelayRotationAdapterError.mismatchedEvidence }
            return
        }
        try await host.sendOnce(prompt, to: fresh)
        try actions.complete(intent: intentID, action: "continue", fingerprint: fingerprint, result: Data())
    }

    private func request(_ op: RelayClaudeRotationOperation, _ args: [String: Any]) async throws -> [String: Any] {
        try object(await helper.request(op, arguments: encode(args)))
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return value
    }
    private func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

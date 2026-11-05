import CryptoKit
import Foundation

// Context roll r2 (work/context-clear-20261101/DESIGN-r2-chitta.md): the stock
// /clear roll driven through Chitta's chitta.rotation/1 ledger contract.
// User decisions 2026-11-02: "Chitta capsule, file fallback" and "Relay carries
// rules" (standing rules travel verbatim beside the Chitta capsule, in Relay's
// own snapshot, because capsule_input holds at most 4 constraints of 128 bytes).

// MARK: - Ledger replies

/// One `chitta ledger_op` reply, classified. Only `value` is success.
struct RelayRotationLedgerReply: @unchecked Sendable {
    enum Kind: Equatable, Sendable {
        /// `{"value": {...}}`, exit 0.
        case value
        /// A contract refusal `{"v":1,"code":C,"message":M}` with a known code, exit 0.
        case refused(String)
        /// The chitta CLI is not installed on the host (exit 127).
        case missing
        /// Anything else: the operation may or may not have been applied.
        case ambiguous(String)
    }
    let kind: Kind
    let value: [String: Any]?

    static func refused(_ code: String) -> Self { .init(kind: .refused(code), value: nil) }
    static func ambiguous(_ why: String) -> Self { .init(kind: .ambiguous(why), value: nil) }
    static let missing = Self(kind: .missing, value: nil)
    static func ok(_ value: [String: Any]) -> Self { .init(kind: .value, value: value) }

    /// The contract's refusal codes (rotation_contract.schema.json, $defs.refusal).
    static let refusalCodes: Set<String> = [
        "ack_conflict", "already_acknowledged", "binding_conflict", "capsule_mismatch", "claim_expired", "claim_live",
        "claimant_mismatch", "intent_abandoned", "intent_unresolved", "invalid_request", "mid_turn", "new_claim_required",
        "not_ambiguous", "not_bound", "revision_mismatch", "seq_mismatch", "session_mismatch", "stale_token",
        "unknown_action", "unknown_intent", "unknown_operation", "unknown_session", "unsupported_version"]

    /// Classifies the CLI's stdout and exit code. Bounded: more than 1 MiB is ambiguous.
    static func classify(stdout: Data, exitCode: Int) -> Self {
        if exitCode == 127 { return .missing }
        guard exitCode == 0 else { return .ambiguous("chitta exited \(exitCode)") }
        guard stdout.count <= 1 << 20 else { return .ambiguous("reply too large") }
        guard let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            return .ambiguous("reply is not a JSON object")
        }
        if object.keys.contains("value") {
            guard let value = object["value"] as? [String: Any] else { return .ambiguous("value is not an object") }
            return .ok(value)
        }
        if let code = object["code"] as? String, object["message"] is String, RelayRotationJSON.int(object["v"]) == 1,
           refusalCodes.contains(code) {
            return .refused(code)
        }
        return .ambiguous("reply is neither a value nor a contract refusal")
    }
}

// MARK: - JSON helpers

enum RelayRotationJSON {
    /// A JSON integer (not a boolean, not fractional) in 0 ..< 2^53.
    static func int(_ value: Any?) -> Int? { RelayContextUsage.count(value) }

    /// Deterministic bytes for a JSON value: sorted keys, no slash escaping.
    static func canonical(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject([value]) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count >= 2 else { return nil }
        // Strip the wrapping array so scalars are allowed too.
        return data.subdata(in: 1..<(data.count - 1))
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b, let x = canonical(a), let y = canonical(b) else { return false }
        return x == y
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Capsule file (agent-written) and snapshot (Relay-held)

enum RelayRollCapsule {
    static let maximumFileBytes = 6000
    static let maximumRules = 16
    static let maximumRuleBytes = 512

    static func path(_ transition: UUID) -> String {
        "~/.local/share/relay/rotation/" + transition.uuidString.lowercased() + ".json"
    }

    /// The fields the agent may write, with their UTF-8 byte limits (capsule_input in the contract).
    /// session_id, ledger_seq and version are Relay's.
    static let textLimits: [String: Int] = [
        "objective": 384, "next_action": 400, "project_dir": 384, "repository": 384, "stream_id": 96,
        "branch": 128, "code_head": 64, "state": 16]
    static let listLimits: [String: (items: Int, bytes: Int)] = [
        "constraints": (4, 128), "dirty_paths": (20, 128), "blockers": (3, 160)]
    static let required: [String] = ["objective", "next_action", "project_dir"]
    static let states: Set<String> = ["in_progress", "complete"]

    enum Refusal: Error, Equatable {
        case empty, oversize, encoding, json, shape, unknownField(String), missing(String), type(String)
        case tooLong(String), control(String), historyMarker, value(String)
    }

    struct Parsed {
        /// Agent fields only, as Foundation JSON values.
        let capsule: [String: Any]
        let rules: [String]
    }

    /// A string Relay can render verbatim on one line: non-empty after trimming, within
    /// `limit` UTF-8 bytes, with no control, line or paragraph separator characters.
    static func text(_ value: Any?, limit: Int, field: String) -> Result<String, Refusal> {
        guard let s = value as? String else { return .failure(.type(field)) }
        guard s.utf8.count <= limit else { return .failure(.tooLong(field)) }
        guard !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80..<0xA0).contains($0.value) ||
            $0.value == 0x2028 || $0.value == 0x2029 }) else { return .failure(.control(field)) }
        guard s.contains(where: { !$0.isWhitespace }) else { return .failure(.value(field)) }
        return .success(s)
    }

    static func validate(_ data: Data, nonce: String) -> Result<Parsed, Refusal> {
        guard !data.isEmpty else { return .failure(.empty) }
        guard data.count <= maximumFileBytes else { return .failure(.oversize) }
        guard let raw = String(data: data, encoding: .utf8) else { return .failure(.encoding) }
        guard !raw.contains(nonce) else { return .failure(.historyMarker) }
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.json) }
        // JSON escapes (r...) can hide the marker from the raw check; check the decoded values too.
        guard let decoded = RelayRotationJSON.canonical(top), !String(decoding: decoded, as: UTF8.self).contains(nonce) else {
            return .failure(.historyMarker)
        }
        for key in top.keys where key != "capsule" && key != "standing_rules" { return .failure(.unknownField(key)) }
        guard let capsule = top["capsule"] as? [String: Any] else { return .failure(.shape) }
        guard let rulesValue = top["standing_rules"] as? [Any] else { return .failure(.shape) }
        guard rulesValue.count <= maximumRules else { return .failure(.tooLong("standing_rules")) }
        var rules: [String] = []
        for rule in rulesValue {
            switch text(rule, limit: maximumRuleBytes, field: "standing_rules") {
            case .success(let s): rules.append(s)
            case .failure(let r): return .failure(r)
            }
        }
        var out: [String: Any] = [:]
        for (key, value) in capsule {
            // r3: an optional text field with no value (a detached HEAD gives "branch": "") is
            // omitted, as if the agent had left the key out. Required fields stay strict.
            if textLimits[key] != nil, !required.contains(key), let s = value as? String, s.allSatisfy({ $0 == " " }) {
                continue
            }
            if let limit = textLimits[key] {
                switch text(value, limit: limit, field: key) {
                case .success(let s): out[key] = s
                case .failure(let r): return .failure(r)
                }
            } else if let limit = listLimits[key] {
                guard let items = value as? [Any] else { return .failure(.type(key)) }
                guard items.count <= limit.items else { return .failure(.tooLong(key)) }
                var list: [String] = []
                for item in items {
                    switch text(item, limit: limit.bytes, field: key) {
                    case .success(let s): list.append(s)
                    case .failure(let r): return .failure(r)
                    }
                }
                out[key] = list
            } else if key == "jobs" {
                guard let jobs = value as? [Any] else { return .failure(.type(key)) }
                guard jobs.count <= 4 else { return .failure(.tooLong(key)) }
                var list: [[String: Any]] = []
                for job in jobs {
                    guard let j = job as? [String: Any], Set(j.keys) == ["id", "result_path"] else { return .failure(.type(key)) }
                    guard case .success(let id) = text(j["id"], limit: 64, field: key),
                          case .success(let path) = text(j["result_path"], limit: 192, field: key) else { return .failure(.value(key)) }
                    list.append(["id": id, "result_path": path])
                }
                out[key] = list
            } else if key == "gates" {
                guard let gates = value as? [String: Any] else { return .failure(.type(key)) }
                guard gates.count <= 6 else { return .failure(.tooLong(key)) }
                var map: [String: Any] = [:]
                for (name, gate) in gates {
                    guard case .success = text(name, limit: 48, field: key),
                          let g = gate as? [String: Any], Set(g.keys) == ["status", "number"],
                          let status = g["status"] as? String, status == "pass" || status == "fail",
                          let number = g["number"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, abs(number.doubleValue) < 1e15 else { return .failure(.value(key)) }
                    map[name] = ["status": status, "number": number]
                }
                out[key] = map
            } else {
                return .failure(.unknownField(key))
            }
        }
        for key in required where out[key] == nil { return .failure(.missing(key)) }
        guard let dir = out["project_dir"] as? String, dir.hasPrefix("/") else { return .failure(.value("project_dir")) }
        if let state = out["state"] as? String, !states.contains(state) { return .failure(.value("state")) }
        return .success(Parsed(capsule: out, rules: rules))
    }

    /// The capsule_input Relay sends: the agent's fields plus Relay's identity and watermark.
    static func input(_ parsed: Parsed, sessionID: String, ledgerSeq: Int) -> [String: Any] {
        var capsule = parsed.capsule
        capsule["session_id"] = sessionID
        capsule["ledger_seq"] = ledgerSeq
        return capsule
    }

    /// Whether the daemon's copy carries every field Relay sent, unchanged.
    static func matches(_ saved: [String: Any], sent: [String: Any]) -> Bool {
        sent.allSatisfy { RelayRotationJSON.same(saved[$0.key], $0.value) }
    }

    // MARK: snapshot

    struct Snapshot: Equatable {
        let transition: String
        let revision: Int
        let sessionID: String
        let ledgerSeq: Int
        /// The agent fields as read back from Chitta (canonical JSON of each value).
        let fields: [String: Any]
        let rules: [String]

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.transition == b.transition && a.revision == b.revision && a.sessionID == b.sessionID &&
                a.ledgerSeq == b.ledgerSeq && a.rules == b.rules && RelayRotationJSON.same(a.fields, b.fields)
        }
    }

    /// One canonical JSON document: Relay journals it with its sha256 and restores only from it.
    static func encode(_ s: Snapshot) -> Data? {
        RelayRotationJSON.canonical(["v": 1, "transition": s.transition, "revision": s.revision, "session_id": s.sessionID,
                                     "ledger_seq": s.ledgerSeq, "capsule": s.fields, "standing_rules": s.rules] as [String: Any])
    }

    static func decode(_ data: Data) -> Snapshot? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], RelayRotationJSON.int(o["v"]) == 1,
              Set(o.keys) == ["v", "transition", "revision", "session_id", "ledger_seq", "capsule", "standing_rules"],
              let t = o["transition"] as? String, let rev = RelayRotationJSON.int(o["revision"]), rev >= 1,
              let sid = o["session_id"] as? String, let seq = RelayRotationJSON.int(o["ledger_seq"]),
              let fields = o["capsule"] as? [String: Any], let rules = o["standing_rules"] as? [String] else { return nil }
        return Snapshot(transition: t, revision: rev, sessionID: sid, ledgerSeq: seq, fields: fields, rules: rules)
    }

    static func header(_ transition: UUID, revision: Int, sha: String) -> String {
        "relay-capsule-restore \(transition.uuidString.lowercased()) rev \(revision) sha \(sha)"
    }

    /// The restore prompt, a pure function of the snapshot bytes. Fields in a fixed order.
    static func restore(transition: UUID, snapshot data: Data) -> String? {
        guard let s = decode(data), s.transition == transition.uuidString.lowercased() else { return nil }
        let sha = RelayRotationJSON.sha256(data)
        var lines = [header(transition, revision: s.revision, sha: sha),
                     "Relay cleared your previous context. This is the capsule you wrote before the clear (Chitta revision " +
                     "\(s.revision)), with your standing rules verbatim; treat it as your current state.", ""]
        func line(_ label: String, _ key: String) {
            if let v = s.fields[key] as? String { lines.append("\(label): \(v)") }
        }
        func list(_ label: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append(label + ":")
            lines += items.map { "- " + $0 }
        }
        list("Standing rules (verbatim)", s.rules)
        line("Objective", "objective")
        line("Next action", "next_action")
        list("Constraints", s.fields["constraints"] as? [String] ?? [])
        list("Blockers", s.fields["blockers"] as? [String] ?? [])
        if let gates = s.fields["gates"] as? [String: Any], !gates.isEmpty {
            lines.append("Gates:")
            for name in gates.keys.sorted() {
                guard let g = gates[name] as? [String: Any], let status = g["status"] as? String,
                      let number = g["number"].flatMap({ RelayRotationJSON.canonical($0) }) else { return nil }
                lines.append("- \(name): \(status) \(String(decoding: number, as: UTF8.self))")
            }
        }
        if let jobs = s.fields["jobs"] as? [[String: Any]], !jobs.isEmpty {
            lines.append("Jobs:")
            for j in jobs {
                guard let id = j["id"] as? String, let path = j["result_path"] as? String else { return nil }
                lines.append("- \(id) -> \(path)")
            }
        }
        list("Dirty paths", s.fields["dirty_paths"] as? [String] ?? [])
        line("Project dir", "project_dir")
        line("Repository", "repository")
        line("Branch", "branch")
        line("Code head", "code_head")
        line("Stream", "stream_id")
        line("State", "state")
        lines.append("Previous session: \(s.sessionID) (ledger seq \(s.ledgerSeq))")
        lines.append("")
        lines.append("Reply first with exactly: \(RelayContextCapsule.ack(transition)) . Then continue with the next action.")
        return lines.joined(separator: "\n")
    }

    static func request(transition: UUID, nonce: String) -> String {
        let id = transition.uuidString.lowercased()
        return """
        [Relay context rotation \(id)] Your context is large. Relay will clear it and restore a capsule you write now. \
        Write one JSON object to the exact file \(path(transition)) (create the directory if needed), at most \
        \(maximumFileBytes) bytes of UTF-8, with exactly two keys. "standing_rules": every standing rule the user gave \
        you, verbatim, one string each (at most \(maximumRules), each at most \(maximumRuleBytes) bytes). "capsule": an \
        object with only these keys: objective (required, <= 384 bytes), next_action (required, <= 400), project_dir \
        (required, absolute path of the working directory), constraints (<= 4 strings of <= 128), blockers (<= 3 of <= \
        160), dirty_paths (<= 20 of <= 128), jobs (<= 4 objects {"id" <= 64, "result_path" <= 192}), gates (<= 6 entries \
        name -> {"status": "pass" or "fail", "number": n}), branch, code_head, repository, stream_id, state \
        ("in_progress" or "complete"). Leave out any optional key you have no value for; never write an empty \
        string. No other keys, and no newlines or control characters inside any string. Do not \
        copy this message or the marker \(RelayContextCapsule.historyMarker(nonce)) into it. Do not save it to Chitta \
        yourself; Relay saves it. Start no new work. When the file is written, reply with exactly: CAPSULE \(id)
        """
    }
}

// MARK: - Durable ledger state of one transition

struct RelayRotationLedgerRecord: Codable, Equatable, Sendable {
    /// The contract epoch: the transition ID.
    let epoch: String
    let claimant: String
    var signalSeq: Int?
    var claimID: String?
    var token: Int?
    var claimedSeq: Int?
    var intentID: String?
    var capsuleRevision: Int?
    /// Canonical snapshot JSON (UTF-8) and its sha256; the restore is rendered only from it.
    var snapshot: String?
    var snapshotSHA256: String?
    /// The last ledger outcome worth keeping (refusal code, ambiguity, release result).
    var note: String?
}

enum RelayRotationLedgerPolicy {
    /// Ops Relay may run. Nothing else is ever passed to `chitta ledger_op`.
    static let operations: Set<String> = ["rotation_status", "rotation_signal", "rotation_claim", "rotation_release",
                                          "rotation_intent", "rotation_abandon_intent", "rotation_bind", "rotation_ack", "capsule_get", "capsule_save"]

    /// Deviation from the design's 900000 ms, stated: the lease must outlive every post-claim deadline,
    /// or the ack after a slow but healthy restore turn is refused as claim_expired.
    static var leaseMilliseconds: Int {
        let states: [RelayContextRotationMachine.State] = [.claimed, .capsuleVerified, .intentRecorded, .sendingClear,
                                                          .clearSubmitted, .clearSeen, .clearVerified, .sendingRestore,
                                                          .restoreSubmitted, .acknowledging]
        let total = states.map { RelayStockRotationPolicy.deadline($0) }.reduce(0, +)
        return Int(total * 1000) + 5 * 60 * 1000
    }

    /// The host command: the chitta CLI on the pane's host; arguments arrive on stdin.
    static func command(op: String) -> String? {
        guard operations.contains(op) else { return nil }
        return #"c=$(command -v chitta 2>/dev/null); [ -n "$c" ] || c="$HOME/.claude/bin/chitta"; "# +
            #"[ -x "$c" ] || exit 127; a=$(cat); exec "$c" ledger_op --op "# + op + #" --args "$a" --json"#
    }
}

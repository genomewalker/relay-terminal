import Foundation
import CryptoKit

/// Unlike the separate dollar-policy interface, this accepts the public nested
/// status and returns rotate/hold/abstain plus v1 rotation_signal arguments.
protocol RelayContextRotationPolicy: Sendable {
    func evaluate(status: Data, now: Date) async throws -> Data
}

/// Swift port of Resources/Rotation/policy.py. Its output is byte-identical to
/// `python3 policy.py --now-ms N` and to relayd's Go port; both are pinned by
/// remote/relayd/internal/daemon/testdata/host_rotation_policy/golden.json.
struct RelayNativeContextRotationPolicy: RelayContextRotationPolicy {
    func evaluate(status: Data, now: Date) async throws -> Data {
        guard status.count <= 262_144,
              now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970 >= 0,
              now.timeIntervalSince1970 < Double(Int64.max / 1000) else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        do {
            return try RelayRotationPolicyRules.evaluate(status: status,
                nowMS: Int64(now.timeIntervalSince1970 * 1000))
        } catch {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
    }
}

/// The policy's decisions over chitta.rotation/1 `rotation_status`, from
/// measured token counters only; it never estimates dollars. On rotate it
/// returns the exact `rotation_signal` arguments. A thrown error is the
/// Python policy's non-zero exit.
enum RelayRotationPolicyRules {
    typealias Value = RelayPythonJSON.Value
    typealias Dict = RelayPythonJSON.Dict

    // Every constant carries its source in policy.py and its README.
    static let freshContextTokens: Int64 = 38_000
    static let reworkTokens: Int64 = 52_000
    static let paybackTurns: Int64 = 2
    static let minimumSessionTurns: Int64 = 3
    static let minimumHeadroomRatio = 0.10
    static let ratios: [String: (cached: Double, write: Double)] = [
        "claude": (0.1, 2.0), "codex": (0.25, 1.0)]
    static let counters = ["input", "cached_input", "uncached_input", "output", "responses", "turns"]
    static let sources = ["in_flight_tool": "transcript", "turn_id_fresh": "transcript",
                          "transcript_mtime_ms_at_stop": "hook", "client": "hook",
                          "last_user_message_ms": "transcript", "last_model_request_ms": "transcript",
                          "last_model_response_ms": "transcript", "cache_ttl_ms": "hook"]
    static let maximumCount: Int64 = 1 << 53

    static func evaluate(status: Data, nowMS: Int64) throws -> Data {
        // Parsing, reading and releasing a status nested up to the decoder's
        // limit recurse once per level; keep all of it on a deep stack.
        try RelayPythonJSON.onDeepStack {
            let decision = try decide(unwrap(RelayPythonJSON.decode(status)), nowMS: nowMS)
            return Data((RelayPythonJSON.dumps(.dict(decision)) + "\n").utf8)
        }
    }

    /// The counter value when `value` is a Python int (never bool) in [0, 2^53).
    static func count(_ value: Value?) -> Int64? {
        guard case .int(let number)? = value, number >= 0, number < maximumCount else { return nil }
        return number
    }

    /// An observation's value only if it carries the provenance the ledger requires.
    static func observed(_ usage: Dict, _ key: String) -> Value {
        guard case .dict(let entry)? = usage[key], let value = entry["value"] else { return .none }
        if case .none = value { return .none }
        return (entry["provenance"] ?? .none).equals(.text(sources[key]!)) ? value : .none
    }

    /// A bare status, the CLI's {value: status}, or the tools/call reply.
    static func unwrap(_ document: Value) throws -> Dict {
        guard case .dict(let top) = document, case .dict(let result) = top["result"] ?? document,
              case .dict(let structured) = result["structured"] ?? .dict(result) else {
            throw RelayPythonJSON.Failure()
        }
        if case .dict(let value)? = structured["value"] { return value }
        return structured
    }

    static func abstain(_ reason: String) -> Dict {
        Dict([("v", .int(1)), ("decision", .text("abstain")), ("reasons", .list([.text(reason)])), ("signal", .none)])
    }

    static func isNone(_ value: Value?) -> Bool {
        if case .none? = value { return true }
        return value == nil
    }

    /// Two bounded wakeups; never a keepalive or permission to send input.
    static func cacheSchedule(_ status: Dict, _ usage: Dict, nowMS: Int64) throws -> Dict {
        let unavailable = Dict([("v", .int(1)), ("state", .text("unknown")), ("binding", .none),
            ("next_evaluation_ms", .none), ("event", .none), ("refresh_capability", .text("unverified"))])
        guard nowMS >= 0, nowMS < maximumCount,
              let request = count(observed(usage, "last_model_request_ms")),
              let response = count(observed(usage, "last_model_response_ms")),
              let ttl = count(observed(usage, "cache_ttl_ms")),
              ttl != 0, response >= request, response <= nowMS, request <= nowMS,
              case .string(let model)? = usage["model"], !model.codePoints.isEmpty,
              try model.utf8Count() <= 256,
              let expires = count(.int(request + ttl)) else { return unavailable }
        let identity = Dict([("session_id", status["session_id"] ?? .none), ("turn_seq", status["turn_seq"] ?? .none),
            ("client", observed(usage, "client")), ("model", .string(model)),
            ("last_model_request_ms", .int(request)), ("cache_ttl_ms", .int(ttl))])
        let canonical = RelayPythonJSON.dumps(.dict(identity), sortKeys: true, itemSeparator: ",", keySeparator: ":")
        let fingerprint = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        // This reserve schedules re-evaluation; it does not assume a provider TTL.
        let reserve = max(1, min(30_000, ttl / 10))
        let prepare = expires - reserve
        let (next, event, state): (Value, Value, String) =
            nowMS < prepare ? (.int(prepare), .text("cache_expiry_approaching"), "before_expiry") :
            nowMS < expires ? (.int(expires), .text("cache_expiry_estimate_reached"), "expiry_approaching") :
            (.none, .none, "expiry_estimate_reached")
        return Dict([("v", .int(1)), ("state", .text(state)), ("binding", .dict(identity)),
            ("fingerprint", .text(fingerprint)), ("next_evaluation_ms", next), ("event", event),
            ("expires_at_ms", .int(expires)), ("preparation_reserve_ms", .int(reserve)),
            ("evidence", .text("request time plus observed TTL; reuse is not guaranteed")),
            ("refresh_capability", .text("unverified"))])
    }

    static func decide(_ status: Dict, nowMS: Int64) throws -> Dict {
        guard (status["v"] ?? .none).equals(.int(1)), case .string(let sid)? = status["session_id"],
              !sid.codePoints.isEmpty, let turnSeq = count(status["turn_seq"]), turnSeq >= 1 else {
            return abstain("not a chitta.rotation/1 status with a session and completed-turn watermark")
        }
        if ["signal", "claim", "intent", "ack"].contains(where: { !isNone(status[$0]) }) {
            return abstain("rotation already signalled or in progress")
        }
        guard case .dict(let usage)? = status["usage"], usage.contains("in_flight_tool") else {
            return abstain("no per-turn usage, or legacy 5-field usage")
        }
        let clientValue = observed(usage, "client")
        guard clientValue.isHashable else { throw RelayPythonJSON.Failure() }
        guard case .string(let clientText) = clientValue,
              let ratio = ratios.first(where: { RelayPythonJSON.Text($0.key) == clientText })?.value else {
            return abstain("unknown client " + RelayPythonJSON.repr(clientValue))
        }
        let sessionValue = usage["session"] ?? .none
        guard case .dict(let session) = sessionValue.truthy ? sessionValue : .dict(Dict()) else {
            throw RelayPythonJSON.Failure()
        }
        var counted: [String: Int64] = [:]
        for key in counters {
            guard let value = count(session[key]) else {
                return abstain("session counters missing, negative, non-integer or out of range")
            }
            counted[key] = value
        }
        let input = counted["input"]!, cachedInput = counted["cached_input"]!
        guard cachedInput <= input, cachedInput + counted["uncached_input"]! == input else {
            return abstain("session input accounting inconsistent")
        }
        guard let context = count(usage["context_tokens"]) else { return abstain("context_tokens not measured") }
        let windowValue = usage["context_window"] ?? .none
        var window: Int64?
        if !isNone(windowValue) {
            guard let measured = count(windowValue), measured != 0, context <= measured else {
                return abstain("invalid measured context window")
            }
            window = measured
        }
        let remaining = window.map { $0 - context }
        let pressure = window.map { Double($0 - context) <= Double($0) * minimumHeadroomRatio } ?? false
        guard case .bool(false) = observed(usage, "in_flight_tool") else {
            return abstain("tool in flight or unknown: not a clean turn boundary")
        }
        guard case .bool(true) = observed(usage, "turn_id_fresh") else { return abstain("turn id stale or unknown") }
        guard counted["turns"]! >= minimumSessionTurns, counted["responses"]! != 0 else {
            return abstain("fewer than \(minimumSessionTurns) completed turns")
        }

        let stopValue = observed(usage, "transcript_mtime_ms_at_stop")
        let stop = count(stopValue)
        if let stop, nowMS < stop { return abstain("clock skew: now precedes the last Stop") }
        let activityKeys = ["last_user_message_ms", "last_model_request_ms", "last_model_response_ms"]
        var activity: [Value] = []
        for key in activityKeys {
            let value = observed(usage, key)
            if !isNone(value) {
                guard let measured = count(value), measured <= nowMS else {
                    return abstain("invalid or future activity timestamp: \(key)")
                }
            }
            activity.append(value)
        }
        let request = count(activity[1]), response = count(activity[2])
        if let request, let response, response < request {
            return abstain("latest model request has no completed response")
        }
        let ttlValue = observed(usage, "cache_ttl_ms")
        let ttl = count(ttlValue)
        if !isNone(ttlValue), ttl == nil || ttl == 0 { return abstain("invalid cache TTL observation") }
        let idle = stop.map { nowMS - $0 }
        let cacheAge = request.map { nowMS - $0 }
        let cold: Bool? = if let cacheAge, let ttl { cacheAge >= ttl } else { nil }
        let callsPerTurn = Double(counted["responses"]!) / Double(counted["turns"]!)
        let scaled = callsPerTurn * Double(max(context - freshContextTokens, 0))
        let saving = scaled * ratio.cached
        let writeOverCached = ratio.write - ratio.cached
        let coldPenalty = cold == true ? Double(context) * writeOverCached : 0.0
        let freshWrite = Double(freshContextTokens) * ratio.write
        let overhead = freshWrite + Double(reworkTokens)
        let payback = Double(paybackTurns) * saving
        let net = payback + coldPenalty - overhead
        func optional(_ value: Int64?) -> Value { value.map { .int($0) } ?? .none }
        var economics = Dict([
            ("units", .text("base-input-token equivalents; measured counters x price ratios")),
            ("client", .string(clientText)),
            ("context_tokens", .int(context)),
            ("context_window", optional(window)),
            ("remaining_context_tokens", optional(remaining)),
            ("context_pressure", .bool(pressure)),
            ("minimum_headroom_ratio", .float(minimumHeadroomRatio)),
            ("calls_per_turn", .float(RelayPythonJSON.round(callsPerTurn, digits: 3))),
            ("idle_ms", optional(idle)),
            ("last_completed_turn_ms", stopValue)])
        for (key, value) in zip(activityKeys, activity) { economics[key] = value }
        economics["cache_age_ms"] = optional(cacheAge)
        economics["cache_ttl_ms"] = optional(ttl)
        economics["cache_state"] = .text(cold == true ? "expired" : cold == false ? "warm" : "unknown")
        economics["provenance"] = .text("counters measured; ratios from price defaults; fresh/rework priors per README")
        economics["cache_cold"] = cold.map { .bool($0) } ?? Value.none
        economics["saving_per_turn"] = try RelayPythonJSON.round(saving)
        economics["cold_penalty"] = try RelayPythonJSON.round(coldPenalty)
        economics["reset_overhead"] = try RelayPythonJSON.round(overhead)
        economics["net_after_payback"] = try RelayPythonJSON.round(net)
        economics["payback_turns"] = .int(paybackTurns)
        guard [saving, coldPenalty, overhead, net].allSatisfy(\.isFinite) else { return abstain("non-finite economics") }
        var out = Dict([("v", .int(1)), ("decision", .text("hold")), ("reasons", .list([])),
            ("economics", .dict(economics)), ("schedule", .dict(try cacheSchedule(status, usage, nowMS: nowMS))),
            ("enforceable", .bool((status["owner"] ?? .none).equals(.text("relay")))), ("signal", .none)])
        if net <= 0 && !pressure {
            out["reasons"] = .list([.text("continuing is cheaper within the payback window")])
            return out
        }
        let why = if pressure, let window, let remaining {
            "context headroom \(remaining) of \(window) tokens"
        } else if cold == true {
            "cache expired"
        } else {
            "context \(context) tokens repays reset in \(paybackTurns) turns"
        }
        out["decision"] = .text("rotate")
        out["reasons"] = .list([.text(why)])
        out["signal"] = .dict(Dict([("v", .int(1)), ("session_id", .string(sid)), ("epoch", .text("turn-\(turnSeq)")),
            ("action", .text("rotate")), ("reason", .text("policy: " + why)), ("usage", .dict(economics))]))
        return out
    }
}

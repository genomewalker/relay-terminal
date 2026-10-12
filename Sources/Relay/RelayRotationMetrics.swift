import Foundation

/// The daemon reports counters, not a dollar cost. Billing evidence must be
/// supplied independently and bound to the same completed-turn watermark.
struct RelayRotationCostObservation: Sendable {
    let sessionID: String
    let turnSequence: Int
    let model: String
    let totalCostUSD: Double
    let lastTurnCostUSD: Double?
    let provenance: String
}

struct RelayRotationPolicyInput: Codable, Equatable, Sendable {
    let sessionID: String
    let totalCostUSD: Double
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let nTurns: Int
    let contextSizeTokens: Int
    let lastTurnCost: Double?
    let lastTurnTokens: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", totalCostUSD = "total_cost_usd"
        case totalInputTokens = "total_input_tokens", totalOutputTokens = "total_output_tokens"
        case nTurns = "n_turns", contextSizeTokens = "context_size_tokens"
        case lastTurnCost = "last_turn_cost", lastTurnTokens = "last_turn_tokens"
    }
}

enum RelayRotationMetricResult: Equatable, Sendable {
    case ready(RelayRotationPolicyInput)
    case abstain(String)
}

enum RelayRotationContextStatusResult: Equatable, Sendable {
    case ready(Data)
    case abstain(String)
}

enum RelayRotationMetricAdapter {
    private struct Observation<T: Decodable & Equatable>: Decodable, Equatable {
        let value: T?
        let provenance: String
    }
    private struct Counters: Decodable, Equatable {
        let input: Int
        let output: Int
        let cachedInput: Int
        let uncachedInput: Int
        enum CodingKeys: String, CodingKey {
            case input, output, cachedInput = "cached_input", uncachedInput = "uncached_input"
        }
        var valid: Bool {
            guard input >= 0, output >= 0, cachedInput >= 0, uncachedInput >= 0 else { return false }
            let sum = cachedInput.addingReportingOverflow(uncachedInput)
            return !sum.overflow && sum.partialValue == input
        }
    }
    private struct SessionCounters: Decodable, Equatable {
        let input: Int
        let output: Int
        let cachedInput: Int
        let uncachedInput: Int
        let turns: Int
        let responses: Int?
        enum CodingKeys: String, CodingKey {
            case input, output, turns, responses, cachedInput = "cached_input", uncachedInput = "uncached_input"
        }
        var counters: Counters {
            Counters(input: input, output: output, cachedInput: cachedInput, uncachedInput: uncachedInput)
        }
    }
    private struct Usage: Decodable, Equatable {
        let turn: Counters
        let session: SessionCounters
        let contextTokens: Int?
        let contextWindow: Int?
        let model: String?
        let inFlightTool: Observation<Bool>?
        let turnIDFresh: Observation<Bool>?
        let client: Observation<String>?
        let stopTimeMS: Observation<Int>?
        let lastUserMessageMS: Observation<Int>?
        let lastModelRequestMS: Observation<Int>?
        let lastModelResponseMS: Observation<Int>?
        let cacheTTLMS: Observation<Int>?
        enum CodingKeys: String, CodingKey {
            case turn, session, model, client, contextTokens = "context_tokens"
            case contextWindow = "context_window"
            case inFlightTool = "in_flight_tool", turnIDFresh = "turn_id_fresh"
            case stopTimeMS = "transcript_mtime_ms_at_stop"
            case lastUserMessageMS = "last_user_message_ms"
            case lastModelRequestMS = "last_model_request_ms"
            case lastModelResponseMS = "last_model_response_ms"
            case cacheTTLMS = "cache_ttl_ms"
        }
    }
    private struct Turn: Decodable {
        let seq: Int
        let sessionID: String
        let turnID: String
        let usage: Usage
        enum CodingKeys: String, CodingKey {
            case seq, usage, sessionID = "session_id", turnID = "turn_id"
        }
    }
    private struct Status: Decodable {
        let v: Int
        let sessionID: String
        let turnSequence: Int
        let usage: Usage
        let history: [Turn]
        enum CodingKeys: String, CodingKey {
            case v, usage, sessionID = "session_id", turnSequence = "turn_seq", history = "usage_history"
        }
    }
    private struct Envelope: Decodable { let value: Status }

    private enum ValidationFailure: Error { case reason(String) }

    /// The context-only policy receives the real validated status, never a
    /// synthetic zero-dollar input. Dollar policy observations stay separate.
    static func contextStatus(_ data: Data, expectedSessionID: String, expectedTurnSequence: Int,
                              expectedTurnID: String, expectedClient: String,
                              backendIdle: Bool, observedAt: Date, now: Date = Date()) -> RelayRotationContextStatusResult {
        do {
            let status = try validate(data, expectedSessionID: expectedSessionID,
                expectedTurnSequence: expectedTurnSequence, expectedTurnID: expectedTurnID,
                backendIdle: backendIdle, observedAt: observedAt, now: now)
            guard ["codex", "claude"].contains(expectedClient),
                  status.usage.client?.value == expectedClient,
                  status.usage.client?.provenance == "hook",
                  let responses = status.usage.session.responses, responses > 0,
                  let stopTime = status.usage.stopTimeMS?.value, stopTime >= 0,
                  status.usage.stopTimeMS?.provenance == "hook",
                  Double(stopTime) <= now.timeIntervalSince1970 * 1000 else {
                return .abstain("context_provenance_unverified")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .abstain("invalid_status")
            }
            let raw = (json["value"] as? [String: Any]) ?? json
            guard raw["client"] as? String == expectedClient else { return .abstain("client_mismatch") }
            return .ready(try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]))
        } catch ValidationFailure.reason(let reason) { return .abstain(reason) }
        catch { return .abstain("invalid_status") }
    }

    /// Freshness and idle state come from the live backend, not from a ledger's
    /// `live` field (which describes the claim lease). No lifecycle side effects.
    static func adapt(_ data: Data, expectedSessionID: String, expectedTurnSequence: Int,
                      backendIdle: Bool, observedAt: Date, now: Date = Date(),
                      cost: RelayRotationCostObservation?,
                      expectedTurnID: String? = nil) -> RelayRotationMetricResult {
        let status: Status
        do {
            status = try validate(data, expectedSessionID: expectedSessionID,
                expectedTurnSequence: expectedTurnSequence, expectedTurnID: expectedTurnID,
                backendIdle: backendIdle, observedAt: observedAt, now: now)
        } catch ValidationFailure.reason(let reason) { return .abstain(reason) }
        catch { return .abstain("invalid_status") }
        let usage = status.usage
        let lastTokens = usage.turn.input.addingReportingOverflow(usage.turn.output)
        guard !lastTokens.overflow else { return .abstain("token_overflow") }
        guard let cost else { return .abstain("measured_cost_absent") }
        guard cost.sessionID == expectedSessionID, cost.turnSequence == expectedTurnSequence,
              cost.model == usage.model, cost.provenance == "measured_billing",
              cost.totalCostUSD.isFinite, cost.totalCostUSD >= 0,
              cost.lastTurnCostUSD.map({ $0.isFinite && $0 >= 0 && $0 <= cost.totalCostUSD }) ?? true else {
            return .abstain("cost_unverified")
        }
        return .ready(RelayRotationPolicyInput(sessionID: expectedSessionID,
            totalCostUSD: cost.totalCostUSD, totalInputTokens: usage.session.input,
            totalOutputTokens: usage.session.output, nTurns: usage.session.turns,
            contextSizeTokens: usage.contextTokens!, lastTurnCost: cost.lastTurnCostUSD,
            lastTurnTokens: lastTokens.partialValue))
    }

    private static func validate(_ data: Data, expectedSessionID: String, expectedTurnSequence: Int,
                                 expectedTurnID: String?, backendIdle: Bool,
                                 observedAt: Date, now: Date) throws -> Status {
        guard data.count <= 262_144 else { throw ValidationFailure.reason("status_too_large") }
        guard !expectedSessionID.isEmpty, expectedSessionID.utf8.count <= 110,
              !expectedSessionID.contains("/"), expectedTurnSequence > 0 else {
            throw ValidationFailure.reason("invalid_identity")
        }
        let age = now.timeIntervalSince(observedAt)
        guard backendIdle, age.isFinite, age >= 0, age <= 30 else { throw ValidationFailure.reason("not_idle_or_stale") }
        let decoder = JSONDecoder()
        let status: Status
        do {
            // The public CLI wraps the ledger result in `value`; direct ledger
            // transports return the same status without that envelope.
            if let direct = try? decoder.decode(Status.self, from: data) { status = direct }
            else { status = try decoder.decode(Envelope.self, from: data).value }
        } catch { throw ValidationFailure.reason("invalid_status") }
        guard status.v == 1, status.sessionID == expectedSessionID,
              status.turnSequence == expectedTurnSequence, status.history.count <= 16,
              let latest = status.history.last, latest.seq == status.turnSequence,
              latest.sessionID == expectedSessionID, !latest.turnID.isEmpty,
              latest.usage == status.usage else { throw ValidationFailure.reason("watermark_mismatch") }
        if let expectedTurnID {
            guard !expectedTurnID.isEmpty, expectedTurnID.utf8.count <= 110,
                  latest.turnID == expectedTurnID else { throw ValidationFailure.reason("completed_turn_mismatch") }
        }
        let usage = status.usage
        guard usage.inFlightTool?.provenance == "transcript", usage.inFlightTool?.value == false,
              usage.turnIDFresh?.provenance == "transcript", usage.turnIDFresh?.value == true else {
            throw ValidationFailure.reason("completed_turn_unverified")
        }
        guard usage.turn.valid, usage.session.counters.valid, usage.session.turns >= 3,
              usage.session.input >= usage.turn.input, usage.session.output >= usage.turn.output,
              let context = usage.contextTokens, context >= 0,
              let model = usage.model, !model.isEmpty else { throw ValidationFailure.reason("invalid_or_early_usage") }
        return status
    }
}

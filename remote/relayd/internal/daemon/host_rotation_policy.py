#!/usr/bin/env python3
"""Relay rotation policy over chitta.rotation/1 `rotation_status`.

Decides rotate / hold / abstain from measured token counters only; it never
estimates dollars. On rotate it returns the exact `rotation_signal` arguments
(docs/DESIGN-2026-09-25-rotation-contract.md); claim, intent, capsule, bind and
ack stay with the Relay executor.

Usage: policy.py [--now-ms N] < rotation_status.json   (raw status or RPC reply)
"""
import json
import hashlib
import math
import sys
import time

# Every constant carries its source; see README.md for the evidence and its limits.
DEFAULTS = {
    "fresh_context_tokens": 38_000,  # p50 first-call context, 308 Claude sessions, 2026-09-27
    "rework_tokens": 52_000,  # pilot-v3-1 pooled reset-minus-continue tokens, 95% CI 15k..90k
    "payback_turns": 2,  # overhead must be repaid within this many continued turns
    "min_session_turns": 3,
    "minimum_headroom_ratio": 0.10,  # preparation reserve, not a provider limit
}
# Multipliers on the base input price. Cached ratios match hooks/turn_usage.py
# defaults (Claude 1.5/15, Codex 0.5/2). Write multipliers remain cost priors,
# independent of the observed cache lifetime; they are not billing evidence.
RATIOS = {"claude": {"cached": 0.1, "write": 2.0}, "codex": {"cached": 0.25, "write": 1.0}}
COUNTERS = ("input", "cached_input", "uncached_input", "output", "responses", "turns")
MAX_COUNT = 2**53
# Provenance each observation must carry, as validated by task_rotation.hpp.
SOURCES = {"in_flight_tool": "transcript", "turn_id_fresh": "transcript",
           "transcript_mtime_ms_at_stop": "hook", "client": "hook",
           "last_user_message_ms": "transcript", "last_model_request_ms": "transcript",
           "last_model_response_ms": "transcript", "cache_ttl_ms": "hook"}


def count(value):
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value < MAX_COUNT


def observed(usage, key):
    """Value of an observation only if its provenance is the one the ledger requires."""
    entry = usage.get(key)
    if not isinstance(entry, dict) or entry.get("value") is None:
        return None
    return entry["value"] if entry.get("provenance") == SOURCES[key] else None



def cache_schedule(status, usage, now_ms):
    """Two bounded wakeups; never a keepalive or permission to send input.

    A host must reload the ledger and compare this binding before evaluating
    a timer. A later turn/model/request/TTL invalidates the old timer.
    Request time plus an observed TTL is an expiry estimate, not a cache-hit
    guarantee. Refresh requires a separately verified native provider API.
    """
    request_ms = observed(usage, "last_model_request_ms")
    response_ms = observed(usage, "last_model_response_ms")
    ttl_ms = observed(usage, "cache_ttl_ms")
    model = usage.get("model")
    unavailable = {"v": 1, "state": "unknown", "binding": None,
                   "next_evaluation_ms": None, "event": None,
                   "refresh_capability": "unverified"}
    if not count(now_ms) or not count(request_ms) or not count(response_ms) or             not count(ttl_ms) or ttl_ms == 0 or response_ms < request_ms or             response_ms > now_ms or request_ms > now_ms or             not isinstance(model, str) or not model or len(model.encode("utf-8")) > 256:
        return unavailable
    expires_ms = request_ms + ttl_ms
    if not count(expires_ms):
        return unavailable
    identity = {"session_id": status["session_id"], "turn_seq": status["turn_seq"],
                "client": observed(usage, "client"), "model": model,
                "last_model_request_ms": request_ms, "cache_ttl_ms": ttl_ms}
    fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True,
                                            separators=(",", ":")).encode()).hexdigest()
    # This reserve schedules re-evaluation; it does not assume a provider TTL
    # or predict that a capsule/refresh can finish within the reserve.
    reserve_ms = max(1, min(30_000, ttl_ms // 10))
    prepare_ms = expires_ms - reserve_ms
    if now_ms < prepare_ms:
        next_ms, event, state = prepare_ms, "cache_expiry_approaching", "before_expiry"
    elif now_ms < expires_ms:
        next_ms, event, state = expires_ms, "cache_expiry_estimate_reached", "expiry_approaching"
    else:
        next_ms, event, state = None, None, "expiry_estimate_reached"
    return {"v": 1, "state": state, "binding": identity, "fingerprint": fingerprint,
            "next_evaluation_ms": next_ms, "event": event,
            "expires_at_ms": expires_ms, "preparation_reserve_ms": reserve_ms,
            "evidence": "request time plus observed TTL; reuse is not guaranteed",
            "refresh_capability": "unverified"}


def unwrap(doc):
    """Accept a bare status, the CLI's {value: status}, or the tools/call reply."""
    doc = doc.get("result", doc)
    doc = doc.get("structured", doc)
    return doc["value"] if isinstance(doc.get("value"), dict) else doc


def decide(status, now_ms, cfg=DEFAULTS):
    def abstain(reason):
        return {"v": 1, "decision": "abstain", "reasons": [reason], "signal": None}

    sid = status.get("session_id")
    if status.get("v") != 1 or not isinstance(sid, str) or not sid or not count(status.get("turn_seq")) \
            or status["turn_seq"] < 1:
        return abstain("not a chitta.rotation/1 status with a session and completed-turn watermark")
    if any(status.get(k) is not None for k in ("signal", "claim", "intent", "ack")):
        return abstain("rotation already signalled or in progress")
    usage = status.get("usage")
    if not isinstance(usage, dict) or "in_flight_tool" not in usage:
        return abstain("no per-turn usage, or legacy 5-field usage")
    client = observed(usage, "client")
    if client not in RATIOS:
        return abstain(f"unknown client {client!r}")
    session = usage.get("session") or {}
    if not all(count(session.get(k)) for k in COUNTERS):
        return abstain("session counters missing, negative, non-integer or out of range")
    if session["cached_input"] > session["input"] or \
            session["cached_input"] + session["uncached_input"] != session["input"]:
        return abstain("session input accounting inconsistent")
    context = usage.get("context_tokens")
    if not count(context):
        return abstain("context_tokens not measured")
    window = usage.get("context_window")
    if window is not None and (not count(window) or window == 0 or context > window):
        return abstain("invalid measured context window")
    remaining = window - context if window is not None else None
    pressure = remaining is not None and remaining <= window * cfg["minimum_headroom_ratio"]
    if observed(usage, "in_flight_tool") is not False:
        return abstain("tool in flight or unknown: not a clean turn boundary")
    if observed(usage, "turn_id_fresh") is not True:
        return abstain("turn id stale or unknown")
    if session["turns"] < cfg["min_session_turns"] or session["responses"] == 0:
        return abstain(f"fewer than {cfg['min_session_turns']} completed turns")

    stop_ms = observed(usage, "transcript_mtime_ms_at_stop")
    if count(stop_ms) and now_ms < stop_ms:
        return abstain("clock skew: now precedes the last Stop")
    r = RATIOS[client]
    activity = {key: observed(usage, key) for key in
                ("last_user_message_ms", "last_model_request_ms", "last_model_response_ms")}
    for key, value in activity.items():
        if value is not None and (not count(value) or value > now_ms):
            return abstain(f"invalid or future activity timestamp: {key}")
    request_ms = activity["last_model_request_ms"]
    response_ms = activity["last_model_response_ms"]
    if request_ms is not None and response_ms is not None and response_ms < request_ms:
        return abstain("latest model request has no completed response")
    ttl_ms = observed(usage, "cache_ttl_ms")
    if ttl_ms is not None and (not count(ttl_ms) or ttl_ms == 0):
        return abstain("invalid cache TTL observation")
    idle_ms = now_ms - stop_ms if count(stop_ms) else None
    # User messages and Stop hooks do not establish when the server saw a request.
    # A measured TTL is required for either client; missing evidence stays unknown.
    cache_age_ms = now_ms - request_ms if request_ms is not None else None
    cold = cache_age_ms >= ttl_ms if cache_age_ms is not None and ttl_ms is not None else None
    fresh = cfg["fresh_context_tokens"]
    calls_per_turn = session["responses"] / session["turns"]
    saving_per_turn = calls_per_turn * max(context - fresh, 0) * r["cached"]
    cold_penalty = context * (r["write"] - r["cached"]) if cold else 0.0
    overhead = fresh * r["write"] + cfg["rework_tokens"]
    net = cfg["payback_turns"] * saving_per_turn + cold_penalty - overhead
    economics = {
        "units": "base-input-token equivalents; measured counters x price ratios",
        "client": client,
        "context_tokens": context,
        "context_window": window,
        "remaining_context_tokens": remaining,
        "context_pressure": pressure,
        "minimum_headroom_ratio": cfg["minimum_headroom_ratio"],
        "calls_per_turn": round(calls_per_turn, 3),
        "idle_ms": idle_ms,
        "last_completed_turn_ms": stop_ms,
        **activity,
        "cache_age_ms": cache_age_ms,
        "cache_ttl_ms": ttl_ms,
        "cache_state": "expired" if cold is True else "warm" if cold is False else "unknown",
        "provenance": "counters measured; ratios from price defaults; fresh/rework priors per README",
        "cache_cold": cold,
        "saving_per_turn": round(saving_per_turn),
        "cold_penalty": round(cold_penalty),
        "reset_overhead": round(overhead),
        "net_after_payback": round(net),
        "payback_turns": cfg["payback_turns"],
    }
    if not all(math.isfinite(v) for v in (saving_per_turn, cold_penalty, overhead, net)):
        return abstain("non-finite economics")
    out = {"v": 1, "decision": "hold", "reasons": [], "economics": economics,
           "schedule": cache_schedule(status, usage, now_ms),
           "enforceable": status.get("owner") == "relay", "signal": None}
    if net <= 0 and not pressure:
        out["reasons"].append("continuing is cheaper within the payback window")
        return out
    why = (f"context headroom {remaining} of {window} tokens" if pressure else
           "cache expired" if cold else f"context {context} tokens repays reset in {cfg['payback_turns']} turns")
    out["decision"] = "rotate"
    out["reasons"].append(why)
    out["signal"] = {"v": 1, "session_id": status["session_id"], "epoch": f"turn-{status.get('turn_seq', 0)}",
                     "action": "rotate", "reason": f"policy: {why}", "usage": economics}
    return out


def main(argv):
    now_ms = int(argv[argv.index("--now-ms") + 1]) if "--now-ms" in argv else int(time.time() * 1000)
    try:
        status = unwrap(json.load(sys.stdin))
    except (ValueError, AttributeError) as e:
        print(json.dumps({"v": 1, "decision": "abstain", "reasons": [f"unreadable status: {e}"], "signal": None}))
        return 1
    print(json.dumps(decide(status, now_ms)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

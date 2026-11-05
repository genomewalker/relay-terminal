package daemon

// Go port of the former Sources/Relay/Resources/Rotation/policy.py (relay
// rotation policy over chitta.rotation/1 rotation_status). It decides rotate /
// hold / abstain from measured token counters only and never estimates
// dollars. The output is byte-identical to the former `policy.py --now-ms N`,
// including the trailing newline; testdata/host_rotation_policy/golden.json
// holds the frozen parity goldens recorded from it. The Swift app has its own
// port; a policy change must be made in both and added to golden.json.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
)

type hostRotationPolicyConfig struct {
	freshContextTokens   int64
	reworkTokens         int64
	paybackTurns         int64
	minSessionTurns      int64
	minimumHeadroomRatio float64
}

// Every constant carries its source in policy.py and its README.
var hostRotationPolicyDefaults = hostRotationPolicyConfig{
	freshContextTokens:   38_000,
	reworkTokens:         52_000,
	paybackTurns:         2,
	minSessionTurns:      3,
	minimumHeadroomRatio: 0.10,
}

// Runtime values, not constants: Python computes `write - cached` in float64,
// whereas Go would fold a constant expression exactly.
var hostRotationPolicyRatios = map[string]struct{ cached, write float64 }{
	"claude": {cached: 0.1, write: 2.0},
	"codex":  {cached: 0.25, write: 1.0},
}

var hostRotationPolicyCounters = []string{"input", "cached_input", "uncached_input", "output", "responses", "turns"}

var hostRotationPolicySources = map[string]string{
	"in_flight_tool": "transcript", "turn_id_fresh": "transcript",
	"transcript_mtime_ms_at_stop": "hook", "client": "hook",
	"last_user_message_ms": "transcript", "last_model_request_ms": "transcript",
	"last_model_response_ms": "transcript", "cache_ttl_ms": "hook",
}

const hostRotationPolicyMaxCount = int64(1) << 53

// errHostRotationPolicyFailed corresponds to a non-zero exit of policy.py:
// an unreadable status or a status shape on which the Python raised.
var errHostRotationPolicyFailed = errors.New("host rotation policy could not evaluate the status")

// evaluateHostRotationPolicy is `policy.py --now-ms nowMS < status`.
func evaluateHostRotationPolicy(status []byte, nowMS int64) (result []byte, err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			if _, ok := recovered.(pyTypeError); !ok {
				panic(recovered)
			}
			result, err = nil, errHostRotationPolicyFailed
		}
	}()
	document, err := pyDecode(status)
	if err != nil {
		return nil, errHostRotationPolicyFailed
	}
	if decision, active := capacityHostPolicy(hostRotationPolicyUnwrap(document), nowMS); active {
		return append(pyEncode(decision, pyDumpsDefault), '\n'), nil
	}
	decision := hostRotationPolicyDecide(hostRotationPolicyUnwrap(document), nowMS, hostRotationPolicyDefaults)
	return append(pyEncode(decision, pyDumpsDefault), '\n'), nil
}

func hostRotationPolicyCount(v any) bool {
	i, ok := pyInt(v)
	return ok && i >= 0 && i < hostRotationPolicyMaxCount
}

func hostRotationPolicyObserved(usage *pyObject, key string) any {
	entry, ok := usage.Get(key).(*pyObject)
	if !ok || entry.Get("value") == nil {
		return nil
	}
	if pyEqual(entry.Get("provenance"), hostRotationPolicySources[key]) {
		return entry.Get("value")
	}
	return nil
}

func hostRotationPolicyUnwrap(document any) *pyObject {
	doc := pyMustObject(document)
	next := doc.GetOr("result", doc)
	doc = pyMustObject(next)
	next = doc.GetOr("structured", doc)
	doc = pyMustObject(next)
	if value, ok := doc.Get("value").(*pyObject); ok {
		return value
	}
	return doc
}

func hostRotationPolicyCacheSchedule(status, usage *pyObject, nowMS int64) *pyObject {
	request := hostRotationPolicyObserved(usage, "last_model_request_ms")
	response := hostRotationPolicyObserved(usage, "last_model_response_ms")
	ttl := hostRotationPolicyObserved(usage, "cache_ttl_ms")
	model := usage.Get("model")
	unavailable := pyObj("v", int64(1), "state", "unknown", "binding", nil,
		"next_evaluation_ms", nil, "event", nil, "refresh_capability", "unverified")
	modelText, modelOK := model.(string)
	if !hostRotationPolicyCount(nowMS) || !hostRotationPolicyCount(request) || !hostRotationPolicyCount(response) ||
		!hostRotationPolicyCount(ttl) {
		return unavailable
	}
	requestMS, _ := pyInt(request)
	responseMS, _ := pyInt(response)
	ttlMS, _ := pyInt(ttl)
	if ttlMS == 0 || responseMS < requestMS || responseMS > nowMS || requestMS > nowMS ||
		!modelOK || modelText == "" || len(modelText) > 256 {
		return unavailable
	}
	expiresMS := requestMS + ttlMS
	if !hostRotationPolicyCount(expiresMS) {
		return unavailable
	}
	identity := pyObj("session_id", status.Get("session_id"), "turn_seq", status.Get("turn_seq"),
		"client", hostRotationPolicyObserved(usage, "client"), "model", modelText,
		"last_model_request_ms", requestMS, "cache_ttl_ms", ttlMS)
	digest := sha256.Sum256(pyEncode(identity, pyDumpsSortedASCII))
	// This reserve schedules re-evaluation; it does not assume a provider TTL.
	reserveMS := max(int64(1), min(int64(30_000), ttlMS/10))
	prepareMS := expiresMS - reserveMS
	var next, event any
	var state string
	switch {
	case nowMS < prepareMS:
		next, event, state = prepareMS, "cache_expiry_approaching", "before_expiry"
	case nowMS < expiresMS:
		next, event, state = expiresMS, "cache_expiry_estimate_reached", "expiry_approaching"
	default:
		next, event, state = nil, nil, "expiry_estimate_reached"
	}
	return pyObj("v", int64(1), "state", state, "binding", identity, "fingerprint", hex.EncodeToString(digest[:]),
		"next_evaluation_ms", next, "event", event, "expires_at_ms", expiresMS, "preparation_reserve_ms", reserveMS,
		"evidence", "request time plus observed TTL; reuse is not guaranteed", "refresh_capability", "unverified")
}

func hostRotationPolicyDecide(status *pyObject, nowMS int64, cfg hostRotationPolicyConfig) *pyObject {
	abstain := func(reason string) *pyObject {
		return pyObj("v", int64(1), "decision", "abstain", "reasons", pyListOf(reason), "signal", nil)
	}
	sid, sidOK := status.Get("session_id").(string)
	turnSeq, _ := pyInt(status.Get("turn_seq"))
	if !pyEqual(status.Get("v"), int64(1)) || !sidOK || sid == "" || !hostRotationPolicyCount(status.Get("turn_seq")) || turnSeq < 1 {
		return abstain("not a chitta.rotation/1 status with a session and completed-turn watermark")
	}
	for _, key := range []string{"signal", "claim", "intent", "ack"} {
		if status.Get(key) != nil {
			return abstain("rotation already signalled or in progress")
		}
	}
	usage, ok := status.Get("usage").(*pyObject)
	if !ok || !usage.Has("in_flight_tool") {
		return abstain("no per-turn usage, or legacy 5-field usage")
	}
	clientValue := hostRotationPolicyObserved(usage, "client")
	if !pyHashable(clientValue) {
		panic(pyTypeError("unhashable client"))
	}
	client, _ := clientValue.(string)
	ratio, known := hostRotationPolicyRatios[client]
	if _, isString := clientValue.(string); !isString || !known {
		return abstain(fmt.Sprintf("unknown client %s", pyRepr(clientValue)))
	}
	sessionValue := usage.Get("session")
	if !pyTruthy(sessionValue) {
		sessionValue = newPyObject()
	}
	session := pyMustObject(sessionValue)
	counters := map[string]int64{}
	for _, key := range hostRotationPolicyCounters {
		if !hostRotationPolicyCount(session.Get(key)) {
			return abstain("session counters missing, negative, non-integer or out of range")
		}
		counters[key], _ = pyInt(session.Get(key))
	}
	if counters["cached_input"] > counters["input"] || counters["cached_input"]+counters["uncached_input"] != counters["input"] {
		return abstain("session input accounting inconsistent")
	}
	if !hostRotationPolicyCount(usage.Get("context_tokens")) {
		return abstain("context_tokens not measured")
	}
	context, _ := pyInt(usage.Get("context_tokens"))
	windowValue := usage.Get("context_window")
	var window int64
	if windowValue != nil {
		window, _ = pyInt(windowValue)
		if !hostRotationPolicyCount(windowValue) || window == 0 || context > window {
			return abstain("invalid measured context window")
		}
	}
	var remaining any
	pressure := false
	if windowValue != nil {
		remaining = window - context
		pressure = float64(window-context) <= float64(window)*cfg.minimumHeadroomRatio
	}
	if flight, ok := hostRotationPolicyObserved(usage, "in_flight_tool").(bool); !ok || flight {
		return abstain("tool in flight or unknown: not a clean turn boundary")
	}
	if fresh, ok := hostRotationPolicyObserved(usage, "turn_id_fresh").(bool); !ok || !fresh {
		return abstain("turn id stale or unknown")
	}
	if counters["turns"] < cfg.minSessionTurns || counters["responses"] == 0 {
		return abstain(fmt.Sprintf("fewer than %d completed turns", cfg.minSessionTurns))
	}

	stop := hostRotationPolicyObserved(usage, "transcript_mtime_ms_at_stop")
	stopMS, _ := pyInt(stop)
	stopCounted := hostRotationPolicyCount(stop)
	if stopCounted && nowMS < stopMS {
		return abstain("clock skew: now precedes the last Stop")
	}
	activityKeys := []string{"last_user_message_ms", "last_model_request_ms", "last_model_response_ms"}
	activity := map[string]any{}
	for _, key := range activityKeys {
		value := hostRotationPolicyObserved(usage, key)
		activity[key] = value
		if value != nil {
			v, _ := pyInt(value)
			if !hostRotationPolicyCount(value) || v > nowMS {
				return abstain("invalid or future activity timestamp: " + key)
			}
		}
	}
	request, response := activity["last_model_request_ms"], activity["last_model_response_ms"]
	requestMS, _ := pyInt(request)
	responseMS, _ := pyInt(response)
	if request != nil && response != nil && responseMS < requestMS {
		return abstain("latest model request has no completed response")
	}
	ttl := hostRotationPolicyObserved(usage, "cache_ttl_ms")
	ttlMS, _ := pyInt(ttl)
	if ttl != nil && (!hostRotationPolicyCount(ttl) || ttlMS == 0) {
		return abstain("invalid cache TTL observation")
	}
	var idle any
	if stopCounted {
		idle = nowMS - stopMS
	}
	var cacheAge any
	if request != nil {
		cacheAge = nowMS - requestMS
	}
	var cold any
	if request != nil && ttl != nil {
		cold = nowMS-requestMS >= ttlMS
	}
	isCold := cold == true
	fresh := cfg.freshContextTokens
	callsPerTurn := float64(counters["responses"]) / float64(counters["turns"])
	// Explicit conversions round each product, preventing fused multiply-add.
	saving := float64(float64(callsPerTurn*float64(max(context-fresh, 0))) * ratio.cached)
	coldPenalty := 0.0
	if isCold {
		coldPenalty = float64(float64(context) * float64(ratio.write-ratio.cached))
	}
	overhead := float64(float64(fresh)*ratio.write) + float64(cfg.reworkTokens)
	net := float64(float64(float64(cfg.paybackTurns)*saving)+coldPenalty) - overhead
	cacheState := "unknown"
	if cold == true {
		cacheState = "expired"
	} else if cold == false {
		cacheState = "warm"
	}
	var windowOut any
	if windowValue != nil {
		windowOut = window
	}
	economics := pyObj(
		"units", "base-input-token equivalents; measured counters x price ratios",
		"client", client,
		"context_tokens", context,
		"context_window", windowOut,
		"remaining_context_tokens", remaining,
		"context_pressure", pressure,
		"minimum_headroom_ratio", cfg.minimumHeadroomRatio,
		"calls_per_turn", pyRoundDigits(callsPerTurn, 3),
		"idle_ms", idle,
		"last_completed_turn_ms", stop,
	)
	for _, key := range activityKeys {
		economics.Set(key, activity[key])
	}
	economics.Set("cache_age_ms", cacheAge)
	economics.Set("cache_ttl_ms", ttl)
	economics.Set("cache_state", cacheState)
	economics.Set("provenance", "counters measured; ratios from price defaults; fresh/rework priors per README")
	economics.Set("cache_cold", cold)
	for _, value := range []float64{saving, coldPenalty, overhead, net} {
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return abstain("non-finite economics")
		}
	}
	economics.Set("saving_per_turn", pyRound(saving))
	economics.Set("cold_penalty", pyRound(coldPenalty))
	economics.Set("reset_overhead", pyRound(overhead))
	economics.Set("net_after_payback", pyRound(net))
	economics.Set("payback_turns", cfg.paybackTurns)
	out := pyObj("v", int64(1), "decision", "hold", "reasons", pyListOf(), "economics", economics,
		"schedule", hostRotationPolicyCacheSchedule(status, usage, nowMS),
		"enforceable", pyEqual(status.Get("owner"), "relay"), "signal", nil)
	reasons := out.Get("reasons").(*pyList)
	if net <= 0 && !pressure {
		reasons.items = append(reasons.items, "continuing is cheaper within the payback window")
		return out
	}
	var why string
	switch {
	case pressure:
		why = fmt.Sprintf("context headroom %d of %d tokens", window-context, window)
	case isCold:
		why = "cache expired"
	default:
		why = fmt.Sprintf("context %d tokens repays reset in %d turns", context, cfg.paybackTurns)
	}
	out.Set("decision", "rotate")
	reasons.items = append(reasons.items, why)
	out.Set("signal", pyObj("v", int64(1), "session_id", sid, "epoch", fmt.Sprintf("turn-%d", turnSeq),
		"action", "rotate", "reason", "policy: "+why, "usage", economics))
	return out
}

package remotemcpbridge

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// Miko agent tools (relay_ask_miko, relay_miko_receipt) over the bridge.
//
// Authority. The Mac consumes a single-use relayd attestation that proves the
// calling pane from kernel process ancestry, and enforces the terminal input
// grant, caller policy and per-pane receipt ownership. The bridge cannot
// verify that attestation (it is opaque and single use), so it never
// substitutes for it. It only narrows: exact tool, exact argument shape, a
// source pane that is on this bridge host, and receipt reads limited to the
// (pane, caller token) that the Mac confirmed for that request.

const (
	mikoPath          = "/api/miko/supervisor"
	mikoBodyLimit     = 32 << 10
	mikoArgumentLimit = 16 << 10
	mikoTextLimit     = 4096
	mikoReceiptCap    = 256 // equals the Mac's askLimit
	mikoPaneCap       = 32
	mikoReceiptTTL    = 6 * time.Hour
)

var (
	strictUUID    = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	anyCaseUUID   = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	attestationID = regexp.MustCompile(`^[0-9a-f]{32}$`)
)

// Lifecycle of a bridge receipt slot.
//
//	provisional: reserved before forwarding; the Mac has not answered yet, or has only
//	             proven rejection so far. Removed only when every in-flight request
//	             for the key has been proven rejected.
//	confirmed:   the Mac answered 200 with the matching Mac-verified pane and id.
//	uncertain:   the outcome is unknown (transport error, 5xx, malformed 200). The Mac
//	             may have accepted the ask, so the slot is kept (still counted toward
//	             the caps and the lifetime) and the owner can read the receipt to reconcile.
//
// inflight counts forwards for the key that have not finished. A slot with
// inflight > 0 is never purged, and a rejection can never remove a slot that
// another request confirmed or left uncertain.
const (
	mikoProvisional = iota
	mikoConfirmed
	mikoUncertain
)

type mikoOwner struct {
	pane, caller string
	expires      time.Time
	state        int
	inflight     int
}

const (
	mikoOutcomeConfirmed = iota
	mikoOutcomeUncertain
	mikoOutcomeRejected
)

// mikoProvenRejection reports whether a Mac status proves the call did not
// execute. Handler semantics (RelayMikoSupervisor.swift, RelaySidePanel.swift):
//
//	400  invalid identity/arguments, rejected before any proof is spent or ask recorded
//	403  caller paused/unknown, input grant missing, pane not open, proof not verified:
//	     all refusals before agentAnswer runs
//	404  unknown tool, or no such receipt: nothing executed
//	409  stale instance, busy, window closed, receipt limit, id reused for another
//	     request: ask() returns before recording anything
//
// Everything else is uncertain: 5xx includes "completion audit failed; do not
// replay" (503, returned AFTER dispatch), 502 (oversized/invalid desktop reply)
// and any status the Mac does not document.
func mikoProvenRejection(status int) bool {
	return status == 400 || status == 403 || status == 404 || status == 409
}

type mikoCall struct {
	tool, callID, attestation, pane, arguments, logical string
	context                                             string
}

// parseMiko validates the supervisor body. It returns an HTTP status of 0 when
// accepted. It is pure so it can be fuzzed.
func parseMiko(obj map[string]any, allowed map[string]bool) (mikoCall, int, string) {
	var c mikoCall
	if len(obj) != 5 {
		return c, 400, "Exact Miko request fields required"
	}
	field := func(name string) (string, bool) { s, ok := obj[name].(string); return s, ok }
	var ok1, ok2, ok3, ok4, ok5 bool
	c.tool, ok1 = field("tool")
	c.callID, ok2 = field("request_id")
	c.attestation, ok3 = field("attestation_id")
	c.pane, ok4 = field("supervisor_pane_id")
	c.arguments, ok5 = field("arguments")
	if !(ok1 && ok2 && ok3 && ok4 && ok5) {
		return c, 400, "Exact Miko request fields required"
	}
	if c.tool != "relay_ask_miko" && c.tool != "relay_miko_receipt" {
		return c, 403, "Only relay_ask_miko and relay_miko_receipt are allowed through this bridge"
	}
	if !strictUUID.MatchString(c.callID) || !attestationID.MatchString(c.attestation) || !strictUUID.MatchString(c.pane) ||
		len(c.arguments) > mikoArgumentLimit || !utf8.ValidString(c.arguments) {
		return c, 400, "Invalid Miko request identity"
	}
	if !allowed[c.pane] {
		return c, 403, "Miko caller pane is not a pane on this bridge host"
	}
	if hasDuplicateKeys([]byte(c.arguments)) {
		return c, 400, "Invalid Miko arguments"
	}
	v, e := decode([]byte(c.arguments))
	args, e2 := object(v)
	if e != nil || e2 != nil {
		return c, 400, "Invalid Miko arguments"
	}
	want := map[string]bool{"instance": true, "request_id": true}
	if c.tool == "relay_ask_miko" {
		want["text"] = true
	}
	for k := range args {
		if !want[k] && !(c.tool == "relay_ask_miko" && k == "pane_id") {
			return c, 400, "Invalid Miko arguments"
		}
	}
	for k := range want {
		if _, ok := args[k]; !ok {
			return c, 400, "Invalid Miko arguments"
		}
	}
	instance, _ := args["instance"].(string)
	logical, _ := args["request_id"].(string)
	if !anyCaseUUID.MatchString(instance) || !anyCaseUUID.MatchString(logical) {
		return c, 400, "Invalid Miko arguments"
	}
	c.logical = strings.ToLower(logical)
	if c.tool == "relay_ask_miko" {
		text, ok := args["text"].(string)
		if !ok || strings.TrimSpace(text) == "" || len(text) > mikoTextLimit {
			return c, 400, "Invalid Miko arguments"
		}
		if raw, present := args["pane_id"]; present {
			pane, ok := raw.(string)
			if !ok || !anyCaseUUID.MatchString(pane) {
				return c, 400, "Invalid Miko arguments"
			}
			if !allowed[strings.ToLower(pane)] {
				return c, 403, "Miko context pane is not a pane on this bridge host"
			}
		}
	}
	return c, 0, ""
}

// hasDuplicateKeys reports a repeated object key at any depth, or malformed JSON.
func hasDuplicateKeys(raw []byte) bool {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var walk func() bool
	walk = func() bool {
		t, e := d.Token()
		if e != nil {
			return true
		}
		delim, ok := t.(json.Delim)
		if !ok {
			return false
		}
		if delim == '[' {
			for d.More() {
				if walk() {
					return true
				}
			}
		} else {
			seen := map[string]bool{}
			for d.More() {
				k, e := d.Token()
				key, ok := k.(string)
				if e != nil || !ok || seen[key] {
					return true
				}
				seen[key] = true
				if walk() {
					return true
				}
			}
		}
		_, e = d.Token()
		return e != nil
	}
	if walk() {
		return true
	}
	_, e := d.Token()
	return e != io.EOF
}

// pruneMiko drops expired owners that have nothing in flight. The caller holds b.mu.
func (b *Bridge) pruneMiko(now time.Time) {
	for id, o := range b.mikoOwners {
		if o.inflight == 0 && !now.Before(o.expires) {
			delete(b.mikoOwners, id)
		}
	}
}

// reserveMiko claims (or joins) a receipt slot for (pane, caller) before the
// ask is forwarded, and counts one in-flight forward. status is non-zero on refusal.
func (b *Bridge) reserveMiko(id, pane, caller string) (status int, message string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	b.pruneMiko(now)
	if o, ok := b.mikoOwners[id]; ok {
		if o.pane == pane && o.caller == caller {
			o.inflight++
			b.mikoOwners[id] = o
			return 0, ""
		}
		return 403, "Request identity is not owned by this caller"
	}
	perPane := 0
	for _, o := range b.mikoOwners {
		if o.pane == pane {
			perPane++
		}
	}
	if len(b.mikoOwners) >= mikoReceiptCap || perPane >= mikoPaneCap {
		return 429, "Bridge Miko request limit reached"
	}
	b.mikoOwners[id] = mikoOwner{pane: pane, caller: caller, expires: now.Add(mikoReceiptTTL), inflight: 1}
	return 0, ""
}

// finishMiko ends one in-flight forward. Confirmed is sticky; uncertain is
// sticky over provisional; a rejection deletes the slot only if it is still
// provisional and this was the last in-flight forward.
func (b *Bridge) finishMiko(id string, outcome int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	o, ok := b.mikoOwners[id]
	if !ok {
		return
	}
	if o.inflight > 0 {
		o.inflight--
	}
	o.expires = b.now().Add(mikoReceiptTTL) // lifetime runs from the last finished forward
	switch outcome {
	case mikoOutcomeConfirmed:
		o.state = mikoConfirmed
	case mikoOutcomeUncertain:
		if o.state == mikoProvisional {
			o.state = mikoUncertain
		}
	}
	if outcome == mikoOutcomeRejected && o.state == mikoProvisional && o.inflight == 0 {
		delete(b.mikoOwners, id)
		return
	}
	b.mikoOwners[id] = o
}

// confirmMiko upgrades an uncertain slot when the Mac itself reports the
// owner's receipt (read-only reconciliation).
func (b *Bridge) confirmMiko(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if o, ok := b.mikoOwners[id]; ok && o.state == mikoUncertain {
		o.state = mikoConfirmed
		b.mikoOwners[id] = o
	}
}

func (b *Bridge) mikoOwned(id, pane, caller string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.pruneMiko(b.now())
	o, ok := b.mikoOwners[id]
	return ok && o.pane == pane && o.caller == caller
}

func (b *Bridge) mikoAgent(r *http.Request, caller string, allowed map[string]bool) (int, []byte, error) {
	_, obj, e := body(r, mikoBodyLimit, "Bounded Miko request required")
	if e != nil {
		return 0, nil, e
	}
	c, status, message := parseMiko(obj, allowed)
	if status != 0 {
		return status, encode(map[string]string{"error": message}), nil
	}
	isAsk := c.tool == "relay_ask_miko"
	if isAsk {
		if status, message = b.reserveMiko(c.logical, c.pane, caller); status != 0 {
			return status, encode(map[string]string{"error": message}), nil
		}
	} else if !b.mikoOwned(c.logical, c.pane, caller) {
		// Unknown, expired, another pane's, another caller's or another bridge's: one answer.
		return deny("Miko receipt is outside this bridge caller scope")
	}
	forwardBody := encode(map[string]string{"tool": c.tool, "request_id": c.callID, "attestation_id": c.attestation,
		"supervisor_pane_id": c.pane, "arguments": c.arguments})
	status, result, e := b.forward(r.Context(), "POST", mikoPath, forwardBody, caller)
	if e != nil {
		if isAsk {
			b.finishMiko(c.logical, mikoOutcomeUncertain) // transport error: the Mac may have accepted it
		}
		return 0, nil, e
	}
	if status != 200 {
		if isAsk {
			if mikoProvenRejection(status) {
				b.finishMiko(c.logical, mikoOutcomeRejected)
			} else {
				b.finishMiko(c.logical, mikoOutcomeUncertain)
			}
		}
		return status, result, nil
	}
	v, e := decode(result)
	reply, e2 := object(v)
	if e != nil || e2 != nil || lower(reply["supervisor_pane_id"]) != c.pane || lower(reply["request_id"]) != c.logical {
		if isAsk {
			b.finishMiko(c.logical, mikoOutcomeUncertain) // a 200 we cannot trust does not prove non-execution
		}
		return 502, []byte(`{"error":"Desktop Miko reply did not match the authenticated caller"}`), nil
	}
	if isAsk {
		b.finishMiko(c.logical, mikoOutcomeConfirmed)
	} else {
		b.confirmMiko(c.logical)
	}
	return status, result, nil
}

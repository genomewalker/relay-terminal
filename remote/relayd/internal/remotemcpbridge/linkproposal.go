package remotemcpbridge

import (
	"net/http"
	"time"
)

// Cross-host pane-link proposals over the bridge.
//
// A remote pane may never create a cross-host link: POST /api/pane-links stays
// denied for a target that is not on this host. It may only PROPOSE one. The
// Mac shows a native confirmation naming both panes and both hosts and creates
// the link only on the user's Allow.
//
// Authority. The Mac spends a single-use relayd attestation bound to the
// operation, the source pane, the target pane and the proposal id, and rejects
// a claimed source that the attestation does not prove. The bridge cannot
// verify that attestation (opaque, single use). It only narrows: exact shape,
// a source pane that is on this bridge host per the Mac's own state, a target
// that is not on this host (same-host links keep the direct path), and status
// reads limited to the (pane, caller token) that the Mac confirmed.

const (
	linkProposalPath      = "/api/pane-link-proposals"
	linkProposalBodyLimit = 4 << 10
	linkProposalCap       = 64 // equals the Mac's table bound
	linkProposalPaneCap   = 8
	linkProposalTTL       = time.Hour
)

type linkProposalState int

const (
	// proposalProvisional: reserved, no Mac answer yet. It is the only state a
	// proven rejection may remove.
	proposalProvisional linkProposalState = iota
	// proposalConfirmed: the Mac answered 200 with the same proposal and pane.
	proposalConfirmed
	// proposalUncertain: the outcome at the Mac is unknown (transport error,
	// 5xx, malformed or mismatching reply). Never removed before the TTL.
	proposalUncertain
)

type linkProposalEntry struct {
	pane, caller, target string
	state                linkProposalState
	inflight             int // forwards in progress; an entry with inflight>0 is never pruned
	expires              time.Time
}

type linkProposalCall struct {
	op, id, attestation, source, target string
}

// parseLinkProposal validates the body. Status 0 means accepted. It is pure so
// it can be fuzzed.
func parseLinkProposal(obj map[string]any, allowed map[string]bool) (linkProposalCall, int, string) {
	var c linkProposalCall
	str := func(name string) (string, bool) { s, ok := obj[name].(string); return s, ok }
	var ok1, ok2, ok3, ok4 bool
	c.op, ok1 = str("op")
	c.id, ok2 = str("proposal_id")
	c.attestation, ok3 = str("attestation_id")
	c.source, ok4 = str("source_pane_id")
	if !(ok1 && ok2 && ok3 && ok4) || (c.op != "propose" && c.op != "status") {
		return c, 400, "Exact pane-link proposal fields required"
	}
	want := 4
	if c.op == "propose" {
		var ok5 bool
		c.target, ok5 = str("target_pane_id")
		if !ok5 {
			return c, 400, "Exact pane-link proposal fields required"
		}
		want = 5
	}
	if len(obj) != want {
		return c, 400, "Exact pane-link proposal fields required"
	}
	if !strictUUID.MatchString(c.id) || !attestationID.MatchString(c.attestation) || !strictUUID.MatchString(c.source) ||
		(c.op == "propose" && !strictUUID.MatchString(c.target)) {
		return c, 400, "Invalid pane-link proposal identity"
	}
	if !allowed[c.source] {
		return c, 403, "Proposal source must be a pane on this bridge host"
	}
	if c.op == "propose" {
		if c.target == c.source {
			return c, 400, "Proposal needs two distinct panes"
		}
		if allowed[c.target] {
			return c, 400, "Target is on this bridge host; same-host links use the direct path"
		}
	}
	return c, 0, ""
}

// pruneLinkProposals drops expired, idle entries. The caller holds b.mu.
func (b *Bridge) pruneLinkProposals(now time.Time) {
	for id, e := range b.linkProposals {
		if e.inflight == 0 && !now.Before(e.expires) {
			delete(b.linkProposals, id)
		}
	}
}

// reserveLinkProposal registers one forward for (id, pane, caller, target).
// Concurrent identical requests share the entry through the inflight count, so
// one request failing can never delete state another request accepted.
func (b *Bridge) reserveLinkProposal(c linkProposalCall, caller string) (int, string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	b.pruneLinkProposals(now)
	if e, ok := b.linkProposals[c.id]; ok {
		if e.pane != c.source || e.caller != caller {
			return 403, "Proposal identity is not owned by this caller"
		}
		if e.target != c.target {
			return 409, "Proposal id was already used for different content"
		}
		e.inflight++
		b.linkProposals[c.id] = e
		return 0, ""
	}
	perPane := 0
	for _, e := range b.linkProposals {
		if e.pane == c.source {
			perPane++
		}
	}
	if len(b.linkProposals) >= linkProposalCap || perPane >= linkProposalPaneCap {
		return 429, "Bridge pane-link proposal limit reached"
	}
	b.linkProposals[c.id] = linkProposalEntry{pane: c.source, caller: caller, target: c.target,
		state: proposalProvisional, inflight: 1, expires: now.Add(linkProposalTTL)}
	return 0, ""
}

// Outcomes of one forward, as in the Miko slot lifecycle (miko.go): confirmed
// is sticky, uncertain is sticky over provisional, and a proven rejection
// removes the entry only while it is provisional and only for the last
// in-flight forward. The set of proven rejections is the Miko one: the Mac
// refuses with 400, 403, 404 or 409 before it records a proposal; 5xx (including
// "completion audit failed") and 429 from an intermediary are uncertain.

// finishLinkProposal ends one in-flight forward.
func (b *Bridge) finishLinkProposal(id string, outcome int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	e, ok := b.linkProposals[id]
	if !ok {
		return
	}
	if e.inflight > 0 {
		e.inflight--
	}
	e.expires = b.now().Add(linkProposalTTL) // lifetime runs from the last finished forward
	switch outcome {
	case mikoOutcomeConfirmed:
		e.state = proposalConfirmed
	case mikoOutcomeUncertain:
		if e.state == proposalProvisional {
			e.state = proposalUncertain
		}
	}
	if outcome == mikoOutcomeRejected && e.state == proposalProvisional && e.inflight == 0 {
		delete(b.linkProposals, id)
		return
	}
	b.linkProposals[id] = e
}

// confirmLinkProposal upgrades an uncertain entry when the Mac itself reports
// the owner's proposal (read-only reconciliation).
func (b *Bridge) confirmLinkProposal(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if e, ok := b.linkProposals[id]; ok && e.state == proposalUncertain {
		e.state = proposalConfirmed
		b.linkProposals[id] = e
	}
}

func (b *Bridge) linkProposalOwned(id, pane, caller string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.pruneLinkProposals(b.now())
	e, ok := b.linkProposals[id]
	return ok && e.pane == pane && e.caller == caller
}

func (b *Bridge) linkProposal(r *http.Request, caller string, allowed map[string]bool) (int, []byte, error) {
	_, obj, e := body(r, linkProposalBodyLimit, "Bounded pane-link proposal required")
	if e != nil {
		return 0, nil, e
	}
	c, status, message := parseLinkProposal(obj, allowed)
	if status != 0 {
		return status, encode(map[string]string{"error": message}), nil
	}
	forwardFields := map[string]string{"op": c.op, "proposal_id": c.id, "attestation_id": c.attestation, "source_pane_id": c.source}
	tracked := false
	if c.op == "propose" {
		forwardFields["target_pane_id"] = c.target
		if status, message = b.reserveLinkProposal(c, caller); status != 0 {
			return status, encode(map[string]string{"error": message}), nil
		}
		tracked = true
	} else if !b.linkProposalOwned(c.id, c.source, caller) {
		// Unknown, expired, another pane's, another caller's or another bridge's: one answer.
		return deny("Pane-link proposal is outside this bridge caller scope")
	}
	status, result, e := b.forward(r.Context(), "POST", linkProposalPath, encode(forwardFields), caller)
	if e != nil {
		if tracked {
			b.finishLinkProposal(c.id, mikoOutcomeUncertain) // transport error: the Mac may have recorded it
		}
		return 0, nil, e
	}
	if status != 200 {
		if tracked {
			if mikoProvenRejection(status) {
				b.finishLinkProposal(c.id, mikoOutcomeRejected)
			} else {
				b.finishLinkProposal(c.id, mikoOutcomeUncertain)
			}
		}
		return status, result, nil
	}
	v, e := decode(result)
	reply, e2 := object(v)
	if e != nil || e2 != nil || lower(reply["source_pane_id"]) != c.source || lower(reply["proposal_id"]) != c.id ||
		(c.op == "propose" && lower(reply["target_pane_id"]) != c.target) {
		// A 200 that does not match is not proof that nothing was created.
		if tracked {
			b.finishLinkProposal(c.id, mikoOutcomeUncertain)
		}
		return 502, []byte(`{"error":"Desktop pane-link reply did not match the authenticated caller"}`), nil
	}
	if tracked {
		b.finishLinkProposal(c.id, mikoOutcomeConfirmed)
	} else {
		b.confirmLinkProposal(c.id)
	}
	return status, result, nil
}

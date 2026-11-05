package remotemcpbridge

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"
)

// linkMac models what matters about the Mac for link proposals: it proves the
// pane behind an attestation, keeps proposals by id, and answers per a script.
type linkMac struct {
	mu        sync.Mutex
	proof     map[string]string // attestation -> proven pane
	proposals map[string]string // proposal id -> source|target
	forwarded []map[string]string
	callers   []string
	paneLinks int
	saved     [][2]string
	// script, when set, decides the answer for the nth proposal-route call (1-based).
	script func(n int, req map[string]string) (int, []byte, error)
	calls  int
}

func newLinkMac() *linkMac {
	return &linkMac{proof: map[string]string{attA: paneA, attB: paneB}, proposals: map[string]string{}}
}

func (m *linkMac) desktop(_ context.Context, method, path string, raw []byte, caller string) (int, []byte, error) {
	m.mu.Lock()
	switch {
	case path == "/api/state":
		m.mu.Unlock()
		return 200, encode(macState()), nil
	case path == "/api/workspace/context":
		m.mu.Unlock()
		return 200, []byte(`{}`), nil
	case method == "GET" && path == "/api/pane-links":
		links := []any{}
		for _, p := range m.saved {
			links = append(links, map[string]any{"members": []any{map[string]any{"paneID": p[0]}, map[string]any{"paneID": p[1]}}})
		}
		m.mu.Unlock()
		return 200, encode(map[string]any{"links": links}), nil
	case method == "POST" && path == "/api/pane-links":
		m.paneLinks++
		m.mu.Unlock()
		return 200, []byte(`{"id":"link"}`), nil
	case method == "POST" && path == linkProposalPath:
		m.calls++
		n := m.calls
		var req map[string]string
		if json.Unmarshal(raw, &req) != nil {
			m.mu.Unlock()
			return 400, []byte(`{}`), nil
		}
		m.forwarded = append(m.forwarded, req)
		m.callers = append(m.callers, caller)
		script := m.script
		m.mu.Unlock()
		if script != nil {
			return script(n, req)
		}
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.proof[req["attestation_id"]] != req["source_pane_id"] {
			return 403, []byte(`{"error":"The proposal proof did not match this pane and call."}`), nil
		}
		reply := map[string]any{"proposal_id": req["proposal_id"], "source_pane_id": req["source_pane_id"], "status": "pending"}
		if req["op"] == "propose" {
			reply["target_pane_id"] = req["target_pane_id"]
			m.proposals[req["proposal_id"]] = req["source_pane_id"] + "|" + req["target_pane_id"]
		} else if m.proposals[req["proposal_id"]] == "" {
			return 404, []byte(`{"error":"unknown"}`), nil
		}
		return 200, encode(reply), nil
	}
	m.mu.Unlock()
	return 200, []byte(`{"status":"fixture_only"}`), nil
}

func lp(n int) string { return lid(500 + n) }

func propose(b *Bridge, caller, source, att, id, target string) (int, any) {
	return request(b, "POST", linkProposalPath, map[string]any{"op": "propose", "proposal_id": id, "attestation_id": att,
		"source_pane_id": source, "target_pane_id": target}, "fixture", caller)
}

func proposalStatus(b *Bridge, caller, source, att, id string) (int, any) {
	return request(b, "POST", linkProposalPath, map[string]any{"op": "status", "proposal_id": id, "attestation_id": att,
		"source_pane_id": source}, "fixture", caller)
}

func TestLinkProposalForwardedAndOwnStatus(t *testing.T) {
	m := newLinkMac()
	b := New("dandy-07", "fixture", m.desktop)
	if s, v := propose(b, "caller_a", paneA, attA, lp(1), macPane); s != 200 {
		t.Fatalf("proposal: %d %v", s, v)
	}
	if len(m.forwarded) != 1 || m.forwarded[0]["target_pane_id"] != macPane || m.forwarded[0]["op"] != "propose" || m.callers[0] != "caller_a" {
		t.Fatalf("forwarded %v callers %v", m.forwarded, m.callers)
	}
	if s, v := proposalStatus(b, "caller_a", paneA, attA, lp(1)); s != 200 {
		t.Fatalf("own status: %d %v", s, v)
	}
	if m.paneLinks != 0 {
		t.Fatal("a proposal must never create a link")
	}
}

func TestLinkProposalDeniedBeforeForwarding(t *testing.T) {
	m := newLinkMac()
	b := New("dandy-07", "fixture", m.desktop)
	good := func() map[string]any {
		return map[string]any{"op": "propose", "proposal_id": lp(1), "attestation_id": attA, "source_pane_id": paneA, "target_pane_id": macPane}
	}
	with := func(k string, v any) map[string]any { p := good(); p[k] = v; return p }
	without := func(k string) map[string]any { p := good(); delete(p, k); return p }
	cases := map[string]map[string]any{
		"forged source: a Mac pane":          with("source_pane_id", macPane),
		"forged source: a pane nobody has":   with("source_pane_id", lid(99)),
		"missing attestation":                without("attestation_id"),
		"empty attestation":                  with("attestation_id", ""),
		"short attestation":                  with("attestation_id", "abc"),
		"missing target":                     without("target_pane_id"),
		"extra field":                        with("note", "x"),
		"unknown op":                         with("op", "approve"),
		"uppercase proposal id":              with("proposal_id", "DDDDDDDD-0000-4000-8000-000000000501"),
		"non-string target":                  with("target_pane_id", 7),
		"self link":                          with("target_pane_id", paneA),
		"same-host target (direct path)":     with("target_pane_id", paneB),
		"status carrying a target":           with("op", "status"),
		"claimed source on target, uppercas": with("source_pane_id", "AAAAAAA1-0000-4000-8000-000000000001"),
	}
	for name, payload := range cases {
		if s, _ := request(b, "POST", linkProposalPath, payload, "fixture", "caller_a"); s < 400 {
			t.Errorf("%s: status %d", name, s)
		}
	}
	if s, _ := request(b, "POST", linkProposalPath, good(), "wrong", "caller_a"); s != 401 {
		t.Errorf("bad bridge token: %d", s)
	}
	if s, _ := request(b, "GET", linkProposalPath, nil, "fixture", "caller_a"); s < 400 {
		t.Errorf("GET: %d", s)
	}
	if len(m.forwarded) != 0 || len(b.linkProposals) != 0 {
		t.Fatalf("denied requests must not reach the Mac or the table: %d %d", len(m.forwarded), len(b.linkProposals))
	}
}

// A remote caller can never use the plain create route for a cross-host target,
// even when the pair is already saved and even with a valid in-host source.
func TestCrossHostDirectCreateStillDenied(t *testing.T) {
	m := newLinkMac()
	b := New("dandy-07", "fixture", m.desktop)
	body := map[string]any{"sourcePaneID": paneA, "paneID": macPane}
	if s, _ := request(b, "POST", "/api/pane-links", body, "fixture", "caller_a"); s != 403 {
		t.Fatalf("cross-host create: %d", s)
	}
	m.saved = [][2]string{{paneA, macPane}}
	if s, _ := request(b, "POST", "/api/pane-links", body, "fixture", "caller_a"); s != 403 {
		t.Fatalf("cross-host create over a saved pair: %d", s)
	}
	if m.paneLinks != 0 {
		t.Fatal("plain create reached the Mac")
	}
}

func TestLinkProposalForgedInHostSourceIsRefusedByMacAndForgotten(t *testing.T) {
	m := newLinkMac()
	b := New("dandy-07", "fixture", m.desktop)
	// attB proves paneB, but the request claims paneA. The bridge cannot see that; the Mac does.
	if s, _ := propose(b, "caller_a", paneA, attB, lp(1), macPane); s != 403 {
		t.Fatalf("forged source: %d", s)
	}
	if len(b.linkProposals) != 0 {
		t.Fatal("a proven rejection must release the reservation")
	}
	if s, _ := proposalStatus(b, "caller_a", paneA, attA, lp(1)); s != 403 {
		t.Fatalf("status of a rejected proposal: %d", s)
	}
}

func TestLinkProposalStatusDenials(t *testing.T) {
	m := newLinkMac()
	b := New("dandy-07", "fixture", m.desktop)
	if s, _ := propose(b, "caller_a", paneA, attA, lp(1), macPane); s != 200 {
		t.Fatal("setup")
	}
	before := len(m.forwarded)
	cases := []struct{ name, caller, pane, att, id string }{
		{"other pane and caller", "caller_b", paneB, attB, lp(1)},
		{"owner's pane, other caller", "caller_b", paneA, attA, lp(1)},
		{"other pane, owner's caller", "caller_a", paneB, attB, lp(1)},
		{"unknown id", "caller_a", paneA, attA, lp(77)},
	}
	for _, c := range cases {
		if s, _ := proposalStatus(b, c.caller, c.pane, c.att, c.id); s != 403 {
			t.Errorf("%s: %d", c.name, s)
		}
	}
	if len(m.forwarded) != before {
		t.Fatal("a denied status read reached the Mac")
	}
	// Another caller cannot take over the id by proposing it either.
	if s, _ := propose(b, "caller_b", paneA, attA, lp(1), macPane); s != 403 {
		t.Fatalf("takeover: %d", s)
	}
}

func TestLinkProposalIdempotentAndConflict(t *testing.T) {
	m := newLinkMac()
	b := New("dandy-07", "fixture", m.desktop)
	for i := 0; i < 2; i++ {
		if s, _ := propose(b, "caller_a", paneA, attA, lp(1), macPane); s != 200 {
			t.Fatalf("identical retry %d: %d", i, s)
		}
	}
	if len(b.linkProposals) != 1 {
		t.Fatalf("retry must not add a table entry: %d", len(b.linkProposals))
	}
	forwarded := len(m.forwarded)
	other := lid(98)
	if s, _ := propose(b, "caller_a", paneA, attA, lp(1), other); s != 409 {
		t.Fatalf("same id, different target: %d", s)
	}
	if len(m.forwarded) != forwarded {
		t.Fatal("a conflicting id was forwarded")
	}
}

func TestLinkProposalTableBounded(t *testing.T) {
	m := newLinkMac()
	b := New("dandy-07", "fixture", m.desktop)
	for i := 1; i <= linkProposalPaneCap; i++ {
		if s, _ := propose(b, "caller_a", paneA, attA, lp(i), macPane); s != 200 {
			t.Fatalf("proposal %d: %d", i, s)
		}
	}
	if s, _ := propose(b, "caller_a", paneA, attA, lp(100), macPane); s != 429 {
		t.Fatalf("per-pane cap: %d", s)
	}
	// Nothing is evicted to make room: an earlier owner can still read.
	if s, _ := proposalStatus(b, "caller_a", paneA, attA, lp(1)); s != 200 {
		t.Fatalf("earlier entry evicted: %d", s)
	}
	for i := 0; len(b.linkProposals) < linkProposalCap; i++ {
		b.linkProposals[lid(10000+i)] = linkProposalEntry{pane: lid(20000 + i), caller: "x", expires: b.now().Add(time.Hour)}
	}
	if s, _ := propose(b, "caller_b", paneB, attB, lp(200), macPane); s != 429 {
		t.Fatalf("global cap: %d", s)
	}
	if len(b.linkProposals) != linkProposalCap {
		t.Fatalf("table grew past its cap: %d", len(b.linkProposals))
	}
}

func TestLinkProposalExpiryPrunesIdleEntries(t *testing.T) {
	m := newLinkMac()
	b := New("dandy-07", "fixture", m.desktop)
	now := time.Unix(1000, 0)
	b.now = func() time.Time { return now }
	if s, _ := propose(b, "caller_a", paneA, attA, lp(1), macPane); s != 200 {
		t.Fatal("setup")
	}
	now = now.Add(linkProposalTTL + time.Second)
	if s, _ := proposalStatus(b, "caller_a", paneA, attA, lp(1)); s != 403 {
		t.Fatalf("expired entry readable: %d", s)
	}
}

// Requirement: a failing request must never delete state another request
// accepted. A (blocked inside the Mac) and B (same id, same owner) overlap; B is
// accepted, then A fails with a proven rejection. The entry must survive.
func TestLinkProposalForcedInterleavingFailureNeverDeletesAcceptedState(t *testing.T) {
	m := newLinkMac()
	aInside, releaseA := make(chan struct{}), make(chan struct{})
	m.script = func(n int, req map[string]string) (int, []byte, error) {
		if n == 1 {
			close(aInside)
			<-releaseA
			return 403, []byte(`{"error":"late refusal"}`), nil
		}
		return 200, encode(map[string]any{"proposal_id": req["proposal_id"], "source_pane_id": req["source_pane_id"],
			"target_pane_id": req["target_pane_id"], "status": "pending"}), nil
	}
	b := New("dandy-07", "fixture", m.desktop)
	done := make(chan int, 1)
	go func() { s, _ := propose(b, "caller_a", paneA, attA, lp(1), macPane); done <- s }()
	<-aInside
	if s, v := propose(b, "caller_a", paneA, attA, lp(1), macPane); s != 200 {
		t.Fatalf("B: %d %v", s, v)
	}
	close(releaseA)
	if s := <-done; s != 403 {
		t.Fatalf("A: %d", s)
	}
	b.mu.Lock()
	e, ok := b.linkProposals[lp(1)]
	b.mu.Unlock()
	if !ok || e.state != proposalConfirmed || e.inflight != 0 {
		t.Fatalf("accepted state was damaged by A's failure: %+v %v", e, ok)
	}
	m.script = nil
	m.proposals[lp(1)] = paneA + "|" + macPane
	if s, _ := proposalStatus(b, "caller_a", paneA, attA, lp(1)); s != 200 {
		t.Fatalf("owner lost the status read: %d", s)
	}
}

// Both overlapping requests are proven rejections: only the last one removes the entry.
func TestLinkProposalOverlappingRejectionsRemoveOnlyWhenIdle(t *testing.T) {
	m := newLinkMac()
	aInside, releaseA := make(chan struct{}), make(chan struct{})
	m.script = func(n int, _ map[string]string) (int, []byte, error) {
		if n == 1 {
			close(aInside)
			<-releaseA
		}
		return 403, []byte(`{}`), nil
	}
	b := New("dandy-07", "fixture", m.desktop)
	done := make(chan struct{})
	go func() { propose(b, "caller_a", paneA, attA, lp(1), macPane); close(done) }()
	<-aInside
	propose(b, "caller_a", paneA, attA, lp(1), macPane) // B rejected while A still in flight
	b.mu.Lock()
	_, stillThere := b.linkProposals[lp(1)]
	b.mu.Unlock()
	if !stillThere {
		t.Fatal("entry removed while another forward was in flight")
	}
	close(releaseA)
	<-done
	if len(b.linkProposals) != 0 {
		t.Fatal("entry kept after every forward was proven rejected")
	}
}

// An uncertain outcome (transport error, 5xx, mismatching 200) never removes the entry.
func TestLinkProposalUncertainOutcomesKeepTheEntry(t *testing.T) {
	cases := map[string]func(int, map[string]string) (int, []byte, error){
		"transport error": func(int, map[string]string) (int, []byte, error) { return 0, nil, errors.New("boom") },
		"http 500":        func(int, map[string]string) (int, []byte, error) { return 500, []byte(`{}`), nil },
		"200 for another pane": func(_ int, req map[string]string) (int, []byte, error) {
			return 200, encode(map[string]any{"proposal_id": req["proposal_id"], "source_pane_id": paneB, "target_pane_id": req["target_pane_id"]}), nil
		},
		"200 not json": func(int, map[string]string) (int, []byte, error) { return 200, []byte(`nope`), nil },
	}
	for name, script := range cases {
		m := newLinkMac()
		m.script = script
		b := New("dandy-07", "fixture", m.desktop)
		propose(b, "caller_a", paneA, attA, lp(1), macPane)
		b.mu.Lock()
		e, ok := b.linkProposals[lp(1)]
		b.mu.Unlock()
		if !ok || e.state != proposalUncertain || e.inflight != 0 {
			t.Errorf("%s: %+v %v", name, e, ok)
		}
	}
}

// Same proven-rejection set as the Miko slots: 429 and 5xx are uncertain.
func TestLinkProposalOnlyMikoProvenRejectionsRemoveTheEntry(t *testing.T) {
	for status, removed := range map[int]bool{400: true, 403: true, 404: true, 409: true, 429: false, 500: false, 503: false, 502: false} {
		status := status
		m := newLinkMac()
		m.script = func(int, map[string]string) (int, []byte, error) { return status, []byte(`{}`), nil }
		b := New("dandy-07", "fixture", m.desktop)
		propose(b, "caller_a", paneA, attA, lp(1), macPane)
		if _, kept := b.linkProposals[lp(1)]; kept == removed {
			t.Errorf("status %d: kept=%v", status, kept)
		}
	}
}

// An uncertain entry stays readable by its owner and a matching Mac status upgrades it.
func TestLinkProposalUncertainEntryIsReconciledByOwnerStatus(t *testing.T) {
	m := newLinkMac()
	m.script = func(int, map[string]string) (int, []byte, error) { return 500, []byte(`{}`), nil }
	b := New("dandy-07", "fixture", m.desktop)
	propose(b, "caller_a", paneA, attA, lp(1), macPane)
	m.script = func(_ int, req map[string]string) (int, []byte, error) {
		return 200, encode(map[string]any{"proposal_id": req["proposal_id"], "source_pane_id": req["source_pane_id"], "status": "denied"}), nil
	}
	if s, _ := proposalStatus(b, "caller_b", paneA, attA, lp(1)); s != 403 {
		t.Fatalf("other caller read an uncertain entry: %d", s)
	}
	if s, _ := proposalStatus(b, "caller_a", paneA, attA, lp(1)); s != 200 {
		t.Fatalf("owner could not read an uncertain entry: %d", s)
	}
	if b.linkProposals[lp(1)].state != proposalConfirmed {
		t.Fatal("status 200 should reconcile an uncertain entry")
	}
	// A later rejection (e.g. a stale retry) cannot remove a confirmed entry.
	m.script = func(int, map[string]string) (int, []byte, error) { return 403, []byte(`{}`), nil }
	propose(b, "caller_a", paneA, attA, lp(1), macPane)
	if _, ok := b.linkProposals[lp(1)]; !ok {
		t.Fatal("confirmed entry removed by a later rejection")
	}
}

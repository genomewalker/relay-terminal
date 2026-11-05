package remotemcpbridge

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	paneA   = "aaaaaaa1-0000-4000-8000-000000000001"
	paneB   = "bbbbbbb2-0000-4000-8000-000000000002"
	macPane = "ccccccc3-0000-4000-8000-000000000003"
	inst    = "11111111-2222-4333-8444-555555555555"
	attA    = "0123456789abcdef0123456789abcdef"
	attB    = "fedcba9876543210fedcba9876543210"
	attA2   = "0123456789abcdef0123456789abcde0"
)

func lid(n int) string { return fmt.Sprintf("dddddddd-0000-4000-8000-%012d", n) }

// fakeMac models the parts of the Mac that matter here: the attestation proves
// one pane, a receipt belongs to the pane that asked, and nothing else.
type fakeMac struct {
	mu          sync.Mutex
	attestation map[string]string // attestation id -> proven pane
	asks        map[string]string // logical id -> pane
	forwarded   int
	paneLinks   int
	saved       [][2]string
	busy        bool
	wrongPane   bool
	force       int  // answer every Miko call with this status, executing nothing
	acceptThen  int  // execute an ask, then answer with this status
	transport   bool // fail the Miko call at the transport level
	callers     []string
}

func newFakeMac() *fakeMac {
	return &fakeMac{attestation: map[string]string{attA: paneA, attB: paneB, attA2: paneA}, asks: map[string]string{}}
}

func macState() any {
	pane := func(id, host, kind string) any {
		return map[string]any{"id": id, "host": host, "contentKind": kind}
	}
	return map[string]any{"selectedPaneID": paneA, "sessions": []any{map[string]any{"id": "s", "tabs": []any{
		map[string]any{"id": "t", "panes": []any{pane(paneA, "dandy-07", "terminal"), pane(paneB, "dandy-07", "terminal")}},
		map[string]any{"id": "t2", "panes": []any{pane(macPane, "laptop", "terminal")}}}}}}
}

func (m *fakeMac) desktop(_ context.Context, method, path string, raw []byte, caller string) (int, []byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	switch {
	case path == "/api/state":
		return 200, encode(macState()), nil
	case path == "/api/workspace/context":
		return 200, []byte(`{}`), nil
	case method == "GET" && path == "/api/pane-links":
		links := []any{}
		for _, p := range m.saved {
			links = append(links, map[string]any{"members": []any{map[string]any{"paneID": p[0]}, map[string]any{"paneID": p[1]}}})
		}
		return 200, encode(map[string]any{"links": links}), nil
	case method == "POST" && path == "/api/pane-links":
		m.paneLinks++
		return 200, []byte(`{"id":"link"}`), nil
	case method == "POST" && path == mikoPath:
		m.forwarded++
		m.callers = append(m.callers, caller)
		if m.transport {
			return 0, nil, fmt.Errorf("connection reset")
		}
		if m.force != 0 {
			return m.force, []byte(`{"error":"forced"}`), nil
		}
		var req map[string]string
		if json.Unmarshal(raw, &req) != nil {
			return 400, []byte(`{}`), nil
		}
		if m.attestation[req["attestation_id"]] != req["supervisor_pane_id"] {
			return 403, []byte(`{"error":"The supervisor proof did not match this pane and call."}`), nil
		}
		var args map[string]any
		_ = json.Unmarshal([]byte(req["arguments"]), &args)
		id := strings.ToLower(args["request_id"].(string))
		replyPane := req["supervisor_pane_id"]
		if m.wrongPane {
			replyPane = paneB
		}
		reply := map[string]any{"supervisor_pane_id": replyPane, "request_id": id, "call_id": req["request_id"]}
		if req["tool"] == "relay_ask_miko" {
			if m.busy {
				return 409, []byte(`{"status":"busy"}`), nil
			}
			m.asks[id] = req["supervisor_pane_id"]
			reply["status"] = "accepted"
			if m.acceptThen != 0 {
				return m.acceptThen, []byte(`{"error":"after acceptance"}`), nil
			}
		} else {
			if m.asks[id] != req["supervisor_pane_id"] {
				return 404, []byte(`{"error":"No relay_ask_miko from this pane has that request_id"}`), nil
			}
			reply["status"] = "ok"
		}
		return 200, encode(reply), nil
	}
	return 200, []byte(`{"status":"fixture_only"}`), nil
}

func miko(b *Bridge, caller, tool, pane, att string, args map[string]any) (int, any) {
	a, _ := json.Marshal(args)
	return request(b, "POST", mikoPath, map[string]any{"tool": tool, "request_id": lid(900), "attestation_id": att,
		"supervisor_pane_id": pane, "arguments": string(a)}, "fixture", caller)
}
func ask(b *Bridge, caller, pane, att string, n int) (int, any) {
	return miko(b, caller, "relay_ask_miko", pane, att, map[string]any{"instance": inst, "request_id": lid(n), "text": "hello"})
}
func receipt(b *Bridge, caller, pane, att string, id string) (int, any) {
	return miko(b, caller, "relay_miko_receipt", pane, att, map[string]any{"instance": inst, "request_id": id})
}

func TestMikoAskAndOwnReceipt(t *testing.T) {
	m := newFakeMac()
	b := New("dandy-07", "fixture", m.desktop)
	if s, v := ask(b, "caller_a", paneA, attA, 1); s != 200 {
		t.Fatalf("own ask: %d %v", s, v)
	}
	if s, v := receipt(b, "caller_a", paneA, attA, lid(1)); s != 200 {
		t.Fatalf("own receipt: %d %v", s, v)
	}
	// Mac-side caller identity input is the forwarded header, unchanged.
	if m.callers[0] != "caller_a" || m.callers[1] != "caller_a" {
		t.Fatalf("caller not forwarded: %v", m.callers)
	}
	// A replay by the same owner is forwarded and answered by the Mac.
	if s, _ := ask(b, "caller_a", paneA, attA, 1); s != 200 {
		t.Fatalf("own replay %d", s)
	}
}

func TestMikoReceiptDenials(t *testing.T) {
	m := newFakeMac()
	b := New("dandy-07", "fixture", m.desktop)
	if s, _ := ask(b, "caller_a", paneA, attA, 1); s != 200 {
		t.Fatal("setup ask")
	}
	forwardedBefore := m.forwarded
	cases := []struct {
		name, caller, pane, att, id string
	}{
		{"other pane, other caller, own proof", "caller_b", paneB, attB, lid(1)},
		{"other caller claims owner's pane, own proof", "caller_b", paneA, attB, lid(1)},
		{"same caller token, other pane", "caller_a", paneB, attB, lid(1)},
		{"owner's pane but a different caller token", "caller_c", paneA, attA, lid(1)},
		{"owner's pane but no caller token", "", paneA, attA, lid(1)},
		{"unknown receipt", "caller_a", paneA, attA, lid(77)},
		{"id never recorded by this bridge, other pane", "caller_b", paneB, attB, lid(78)},
	}
	for _, c := range cases {
		s, _ := receipt(b, c.caller, c.pane, c.att, c.id)
		if s != 403 {
			t.Fatalf("%s: status %d", c.name, s)
		}
	}
	if m.forwarded != forwardedBefore {
		t.Fatal("denied receipt reached the desktop")
	}
	// Another bridge process has its own table: it never recorded the id.
	other := New("dandy-07", "fixture", m.desktop)
	if s, _ := receipt(other, "caller_a", paneA, attA, lid(1)); s != 403 {
		t.Fatalf("other bridge receipt %d", s)
	}
	// The owner is unaffected.
	if s, _ := receipt(b, "caller_a", paneA, attA, lid(1)); s != 200 {
		t.Fatal("owner lost receipt")
	}
}

func TestMikoTwoCallersSameHost(t *testing.T) {
	m := newFakeMac()
	b := New("dandy-07", "fixture", m.desktop)
	if s, _ := ask(b, "caller_a", paneA, attA, 1); s != 200 {
		t.Fatal("A ask")
	}
	if s, _ := ask(b, "caller_b", paneB, attB, 2); s != 200 {
		t.Fatal("B ask")
	}
	if s, _ := receipt(b, "caller_a", paneA, attA, lid(1)); s != 200 {
		t.Fatal("A own")
	}
	if s, _ := receipt(b, "caller_b", paneB, attB, lid(2)); s != 200 {
		t.Fatal("B own")
	}
	if s, _ := receipt(b, "caller_b", paneB, attB, lid(1)); s != 403 {
		t.Fatal("B read A's receipt")
	}
	if s, _ := receipt(b, "caller_a", paneA, attA, lid(2)); s != 403 {
		t.Fatal("A read B's receipt")
	}
	// B asking with A's request id is refused without reaching the desktop.
	n := m.forwarded
	if s, _ := ask(b, "caller_b", paneB, attB, 1); s != 403 || m.forwarded != n {
		t.Fatalf("id collision: %d forwarded=%d", s, m.forwarded-n)
	}
}

func TestMikoForgedSourceDenied(t *testing.T) {
	m := newFakeMac()
	b := New("dandy-07", "fixture", m.desktop)
	// Pane on another host, and a pane id the Mac does not list: stopped at the bridge.
	for _, pane := range []string{macPane, "eeeeeee5-0000-4000-8000-000000000005", strings.ToUpper(paneA)} {
		if s, _ := ask(b, "caller_a", pane, attA, 1); s == 200 || m.forwarded != 0 {
			t.Fatalf("forged source %s status %d forwarded %d", pane, s, m.forwarded)
		}
	}
	// In-host forged source: passes bridge scope, fails the Mac's attestation; nothing recorded.
	if s, _ := ask(b, "caller_b", paneA, attB, 1); s != 403 {
		t.Fatalf("attestation mismatch %d", s)
	}
	if len(b.mikoOwners) != 0 {
		t.Fatal("rejected ask left an owner")
	}
	// A context pane outside this host is refused.
	s, _ := miko(b, "caller_a", "relay_ask_miko", paneA, attA, map[string]any{"instance": inst, "request_id": lid(5), "text": "x", "pane_id": macPane})
	if s != 403 {
		t.Fatalf("foreign context pane %d", s)
	}
	s, _ = miko(b, "caller_a", "relay_ask_miko", paneA, attA, map[string]any{"instance": inst, "request_id": lid(5), "text": "x", "pane_id": paneB})
	if s != 200 {
		t.Fatalf("same-host context pane %d", s)
	}
}

func TestMikoBusyDoesNotRecord(t *testing.T) {
	m := newFakeMac()
	m.busy = true
	b := New("dandy-07", "fixture", m.desktop)
	if s, _ := ask(b, "caller_a", paneA, attA, 1); s != 409 {
		t.Fatalf("busy %d", s)
	}
	if len(b.mikoOwners) != 0 {
		t.Fatal("refused ask recorded")
	}
}

func TestMikoMismatchedReplyNotRecorded(t *testing.T) {
	m := newFakeMac()
	m.wrongPane = true
	b := New("dandy-07", "fixture", m.desktop)
	// A 200 we cannot trust does not prove the ask was not executed: keep the slot as uncertain.
	if s, _ := ask(b, "caller_a", paneA, attA, 1); s != 502 || len(b.mikoOwners) != 1 || b.mikoOwners[lid(1)].state != mikoUncertain {
		t.Fatalf("mismatched Mac reply: %d owners %v", s, b.mikoOwners)
	}
}

func TestMikoMalformedAndOtherToolsDenied(t *testing.T) {
	m := newFakeMac()
	b := New("dandy-07", "fixture", m.desktop)
	good := map[string]any{"instance": inst, "request_id": lid(1), "text": "x"}
	for _, tool := range []string{"relay_miko_turn", "relay_miko_card", "relay_miko_set_instructions", "relay_miko_set_memory",
		"relay_miko_set_capabilities", "relay_miko_revert", "relay_miko_transcript", "relay_miko_state", "relay_miko_audit", ""} {
		for _, args := range []map[string]any{good, {"instance": inst, "request_id": lid(1)}} {
			if s, _ := miko(b, "caller_a", tool, paneA, attA, args); s != 403 {
				t.Fatalf("%s status %d", tool, s)
			}
		}
	}
	bad := []map[string]any{
		{"instance": inst, "request_id": lid(1)},                                               // ask without text
		{"instance": inst, "request_id": lid(1), "text": "x", "extra": 1},                      // extra key
		{"instance": inst, "request_id": lid(1), "text": strings.Repeat("x", mikoTextLimit+1)}, // too long
		{"instance": inst, "request_id": lid(1), "text": "  "},                                 // blank
		{"instance": "nope", "request_id": lid(1), "text": "x"},
		{"instance": inst, "request_id": "nope", "text": "x"},
		{"instance": inst, "request_id": lid(1), "text": "x", "pane_id": 5},
	}
	for i, args := range bad {
		if s, _ := miko(b, "caller_a", "relay_ask_miko", paneA, attA, args); s != 400 {
			t.Fatalf("bad %d status %d", i, s)
		}
	}
	// Receipt takes exactly instance and request_id.
	if s, _ := miko(b, "caller_a", "relay_miko_receipt", paneA, attA, map[string]any{"instance": inst, "request_id": lid(1), "text": "x"}); s != 400 {
		t.Fatalf("receipt extra key %d", s)
	}
	// Body shape: wrong key set, non-string field, query string, GET, unauthenticated.
	post := func(path string, payload any, token string) int {
		s, _ := request(b, "POST", path, payload, token, "caller_a")
		return s
	}
	base := func() map[string]any {
		return map[string]any{"tool": "relay_ask_miko", "request_id": lid(900), "attestation_id": attA, "supervisor_pane_id": paneA, "arguments": `{"instance":"` + inst + `","request_id":"` + lid(1) + `","text":"x"}`}
	}
	extra := base()
	extra["extra"] = "x"
	num := base()
	num["tool"] = 5
	dup := base()
	dup["arguments"] = `{"instance":"` + inst + `","request_id":"` + lid(1) + `","request_id":"` + lid(2) + `","text":"x"}`
	badAtt := base()
	badAtt["attestation_id"] = "xyz"
	for name, c := range map[string]int{
		"extra key": post(mikoPath, extra, "fixture"), "non-string": post(mikoPath, num, "fixture"),
		"duplicate argument key": post(mikoPath, dup, "fixture"), "bad attestation shape": post(mikoPath, badAtt, "fixture"),
	} {
		if c != 400 {
			t.Fatalf("%s: %d", name, c)
		}
	}
	if c := post(mikoPath+"?x=1", base(), "fixture"); c != 403 {
		t.Fatalf("query string %d", c)
	}
	if c := post(mikoPath+"/", base(), "fixture"); c != 403 {
		t.Fatalf("trailing slash %d", c)
	}
	if c := post("/api/miko/other", base(), "fixture"); c != 403 {
		t.Fatalf("other miko path %d", c)
	}
	if c := post(mikoPath, base(), "wrong"); c != 401 {
		t.Fatalf("unauthenticated %d", c)
	}
	if s, _ := request(b, "GET", mikoPath, nil, "fixture", "caller_a"); s != 403 {
		t.Fatalf("GET %d", s)
	}
	if m.forwarded != 0 {
		t.Fatalf("a malformed or denied request reached the desktop %d", m.forwarded)
	}
}

func TestMikoReceiptBounds(t *testing.T) {
	m := newFakeMac()
	b := New("dandy-07", "fixture", m.desktop)
	clock := time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)
	b.now = func() time.Time { return clock }
	// Per-pane cap, then global cap with a second pane.
	for i := 1; i <= mikoPaneCap; i++ {
		if s, _ := ask(b, "caller_a", paneA, attA, i); s != 200 {
			t.Fatalf("ask %d: %d", i, s)
		}
	}
	n := m.forwarded
	if s, _ := ask(b, "caller_a", paneA, attA, 1000); s != 429 || m.forwarded != n {
		t.Fatalf("per-pane cap %d", s)
	}
	// A full pane does not starve another pane, and nothing is evicted.
	if s, _ := ask(b, "caller_b", paneB, attB, 2000); s != 200 {
		t.Fatal("other pane starved")
	}
	if s, _ := receipt(b, "caller_a", paneA, attA, lid(1)); s != 200 {
		t.Fatal("receipt evicted")
	}
	// Fill to the global cap using synthetic owners, then one more is refused.
	for i := len(b.mikoOwners); i < mikoReceiptCap; i++ {
		b.mikoOwners[lid(5000+i)] = mikoOwner{pane: "z", caller: "z", expires: clock.Add(time.Hour)}
	}
	if s, _ := ask(b, "caller_b", paneB, attB, 3000); s != 429 || len(b.mikoOwners) != mikoReceiptCap {
		t.Fatalf("global cap %d size %d", s, len(b.mikoOwners))
	}
	// Lifetime: just before expiry readable, at expiry gone, and the slot is reusable.
	clock = clock.Add(mikoReceiptTTL - time.Second)
	if s, _ := receipt(b, "caller_a", paneA, attA, lid(1)); s != 200 {
		t.Fatal("receipt expired early")
	}
	clock = clock.Add(time.Second)
	if s, _ := receipt(b, "caller_a", paneA, attA, lid(1)); s != 403 {
		t.Fatal("receipt outlived lifetime")
	}
	if len(b.mikoOwners) != 0 {
		t.Fatalf("expired owners not purged: %d", len(b.mikoOwners))
	}
	if s, _ := ask(b, "caller_b", paneB, attB, 3000); s != 200 {
		t.Fatal("slot not reusable after expiry")
	}
}

func TestMikoConcurrentAsksRespectCap(t *testing.T) {
	m := newFakeMac()
	b := New("dandy-07", "fixture", m.desktop)
	var wg sync.WaitGroup
	var mu sync.Mutex
	ok := 0
	start := make(chan struct{})
	for i := 1; i <= mikoPaneCap*2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			if s, _ := ask(b, "caller_a", paneA, attA, i); s == 200 {
				mu.Lock()
				ok++
				mu.Unlock()
			}
		}(i)
	}
	close(start)
	wg.Wait()
	if ok != mikoPaneCap || len(b.mikoOwners) != mikoPaneCap {
		t.Fatalf("admitted %d recorded %d", ok, len(b.mikoOwners))
	}
}

// Cross-host pane-link creation stays closed: the Mac has no per-link user
// approval (see DESIGN.md section 4), so no bridge-side evidence is enough.
func TestPaneLinkCreateStaysClosedCrossHost(t *testing.T) {
	for _, savedPair := range []bool{false, true} {
		for _, c := range []struct{ name, source, target string }{
			{"own pane to Mac pane", paneA, macPane},
			{"forged Mac source", macPane, paneA},
			{"forged other-host source to Mac", macPane, macPane},
			{"unknown source", "eeeeeee5-0000-4000-8000-000000000005", macPane},
		} {
			m := newFakeMac()
			if savedPair {
				m.saved = [][2]string{{paneA, macPane}, {macPane, paneA}}
			}
			b := New("dandy-07", "fixture", m.desktop)
			s, _ := request(b, "POST", "/api/pane-links", map[string]any{"sourcePaneID": c.source, "paneID": c.target}, "fixture", "caller_a")
			if s != 403 || m.paneLinks != 0 {
				t.Fatalf("%s saved=%v status %d creates %d", c.name, savedPair, s, m.paneLinks)
			}
		}
	}
	// Same-host links and saved cross-host messaging are unchanged.
	m := newFakeMac()
	b := New("dandy-07", "fixture", m.desktop)
	if s, _ := request(b, "POST", "/api/pane-links", map[string]any{"sourcePaneID": paneA, "paneID": paneB}, "fixture", "caller_a"); s != 200 || m.paneLinks != 1 {
		t.Fatalf("same-host link %d", s)
	}
	if s, _ := request(b, "POST", "/api/panes/"+macPane+"/message", map[string]any{"sourcePaneID": paneA}, "fixture", "caller_a"); s != 403 {
		t.Fatalf("unsaved cross-host message %d", s)
	}
	m.saved = [][2]string{{paneA, macPane}}
	if s, _ := request(b, "POST", "/api/panes/"+macPane+"/message", map[string]any{"sourcePaneID": paneA}, "fixture", "caller_a"); s != 200 {
		t.Fatalf("saved cross-host message %d", s)
	}
}

// Routes that were denied before this change are still denied.
func TestMikoChangeLeavesOtherRoutesDenied(t *testing.T) {
	m := newFakeMac()
	b := New("dandy-07", "fixture", m.desktop)
	for _, e := range []struct{ method, path string }{
		{"POST", "/api/miko"}, {"POST", "/api/miko/turn"}, {"POST", "/api/miko/supervisor/x"}, {"GET", "/api/miko/supervisor"},
		{"POST", "/api/network/desktop-route/send"}, {"POST", "/api/assistant/ask"}, {"GET", "/api/miko/receipts/" + requestID},
	} {
		if s, _ := request(b, e.method, e.path, map[string]any{"a": 1}, "fixture", "caller_a"); s != 403 {
			t.Fatalf("%s %s -> %d", e.method, e.path, s)
		}
	}
	if m.forwarded != 0 {
		t.Fatal("forwarded")
	}
}

func TestHasDuplicateKeys(t *testing.T) {
	for raw, want := range map[string]bool{
		`{}`: false, `{"a":1,"b":{"a":2},"c":[{"a":1},{"a":2}]}`: false,
		`{"a":1,"a":2}`: true, `{"a":{"b":1,"b":2}}`: true, `[{"a":1,"a":1}]`: true,
		`{"a":1`: true, `{"a":1}{}`: true, ``: true, `{"a":}`: true,
	} {
		if got := hasDuplicateKeys([]byte(raw)); got != want {
			t.Fatalf("%q: got %v", raw, got)
		}
	}
}

// gatedDesktop holds Miko calls whose attestation id is in gates until released,
// after announcing that they reached the desktop.
type gatedDesktop struct {
	inner   Desktop
	entered map[string]chan struct{}
	release map[string]chan struct{}
}

func newGated(inner Desktop, ids ...string) *gatedDesktop {
	g := &gatedDesktop{inner: inner, entered: map[string]chan struct{}{}, release: map[string]chan struct{}{}}
	for _, id := range ids {
		g.entered[id], g.release[id] = make(chan struct{}), make(chan struct{})
	}
	return g
}

func (g *gatedDesktop) call(ctx context.Context, method, path string, raw []byte, caller string) (int, []byte, error) {
	if path == mikoPath {
		var req map[string]string
		_ = json.Unmarshal(raw, &req)
		if gate, ok := g.entered[req["attestation_id"]]; ok {
			close(gate)
			<-g.release[req["attestation_id"]]
		}
	}
	return g.inner(ctx, method, path, raw, caller)
}

const badAtt = "00000000000000000000000000000000" // proves no pane: the Mac refuses it with 403

type result struct {
	status int
	body   any
}

func async(f func() (int, any)) chan result {
	c := make(chan result, 1)
	go func() { s, v := f(); c <- result{s, v} }()
	return c
}

// A rejected request must never remove the slot another request for the same
// (owner, id) was accepted for, whichever finishes first.
func TestMikoRejectionCannotRemoveAcceptedSlot(t *testing.T) {
	// Request A (bad proof) is held at the Mac; B (good proof) reserves the same
	// key, is accepted and finishes; then A is refused.
	m := newFakeMac()
	g := newGated(m.desktop, badAtt)
	b := New("dandy-07", "fixture", g.call)
	a := async(func() (int, any) { return ask(b, "caller_a", paneA, badAtt, 1) })
	<-g.entered[badAtt]
	if s, v := ask(b, "caller_a", paneA, attA, 1); s != 200 {
		t.Fatalf("B accepted: %d %v", s, v)
	}
	close(g.release[badAtt])
	if r := <-a; r.status != 403 {
		t.Fatalf("A should be refused: %d", r.status)
	}
	if s, v := receipt(b, "caller_a", paneA, attA, lid(1)); s != 200 {
		t.Fatalf("B's receipt lost: %d %v", s, v)
	}
	if o := b.mikoOwners[lid(1)]; o.state != mikoConfirmed || o.inflight != 0 {
		t.Fatalf("slot %+v", o)
	}

	// Mirror: A (good) is held at the Mac after B (bad) reserved and was refused first.
	m = newFakeMac()
	g = newGated(m.desktop, attA)
	b = New("dandy-07", "fixture", g.call)
	a = async(func() (int, any) { return ask(b, "caller_a", paneA, attA, 1) })
	<-g.entered[attA]
	if s, _ := ask(b, "caller_a", paneA, badAtt, 1); s != 403 {
		t.Fatalf("B refused: %d", s)
	}
	if o, ok := b.mikoOwners[lid(1)]; !ok || o.inflight != 1 {
		t.Fatalf("slot must survive B's rejection while A is in flight: %+v %v", o, ok)
	}
	close(g.release[attA])
	if r := <-a; r.status != 200 {
		t.Fatalf("A accepted: %d", r.status)
	}
	if s, _ := receipt(b, "caller_a", paneA, attA2, lid(1)); s != 200 {
		t.Fatalf("A receipt lost %d", s)
	}

	// Both refused: the last one out removes the provisional slot.
	m = newFakeMac()
	g = newGated(m.desktop, badAtt)
	b = New("dandy-07", "fixture", g.call)
	a = async(func() (int, any) { return ask(b, "caller_a", paneA, badAtt, 1) })
	<-g.entered[badAtt]
	m.force = 409
	if s, _ := ask(b, "caller_a", paneA, attA, 1); s != 409 {
		t.Fatal("second refusal")
	}
	if len(b.mikoOwners) != 1 {
		t.Fatal("slot removed while a request was still in flight")
	}
	close(g.release[badAtt])
	<-a
	if len(b.mikoOwners) != 0 {
		t.Fatalf("provisional slot not removed after all rejections: %v", b.mikoOwners)
	}
}

// A rejection after another request left the slot uncertain must not remove it.
func TestMikoRejectionCannotRemoveUncertainSlot(t *testing.T) {
	m := newFakeMac()
	g := newGated(m.desktop, badAtt)
	b := New("dandy-07", "fixture", g.call)
	a := async(func() (int, any) { return ask(b, "caller_a", paneA, badAtt, 1) })
	<-g.entered[badAtt]
	m.acceptThen = 503 // B is executed by the Mac, then its answer is lost
	if s, _ := ask(b, "caller_a", paneA, attA, 1); s != 503 {
		t.Fatal("B")
	}
	m.acceptThen = 0
	close(g.release[badAtt])
	<-a
	if o := b.mikoOwners[lid(1)]; o.state != mikoUncertain {
		t.Fatalf("slot %+v", o)
	}
	if s, _ := receipt(b, "caller_a", paneA, attA, lid(1)); s != 200 {
		t.Fatal("owner cannot reconcile")
	}
	if b.mikoOwners[lid(1)].state != mikoConfirmed {
		t.Fatal("Mac-reported receipt should confirm the slot")
	}
}

func TestMikoProvenRejectionStatuses(t *testing.T) {
	for _, c := range []struct {
		status int
		proven bool
	}{{400, true}, {403, true}, {404, true}, {409, true},
		{401, false}, {408, false}, {418, false}, {429, false}, {500, false}, {502, false}, {503, false}, {504, false}} {
		m := newFakeMac()
		m.force = c.status
		b := New("dandy-07", "fixture", m.desktop)
		if s, _ := ask(b, "caller_a", paneA, attA, 1); s != c.status {
			t.Fatalf("%d passthrough %d", c.status, s)
		}
		if _, kept := b.mikoOwners[lid(1)]; kept == c.proven {
			t.Fatalf("status %d: proven=%v kept=%v", c.status, c.proven, kept)
		}
	}
}

func TestMikoUncertainSlotsStayBoundedAndReadable(t *testing.T) {
	// Accepted by the Mac, then answered 5xx: the slot stays and the owner reads the receipt.
	m := newFakeMac()
	m.acceptThen = 500
	b := New("dandy-07", "fixture", m.desktop)
	clock := time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)
	b.now = func() time.Time { return clock }
	if s, _ := ask(b, "caller_a", paneA, attA, 1); s != 500 {
		t.Fatal("ask")
	}
	m.acceptThen = 0
	if s, _ := receipt(b, "caller_b", paneB, attB, lid(1)); s != 403 {
		t.Fatal("another caller read an uncertain receipt")
	}
	if s, _ := receipt(b, "caller_a", paneA, attA, lid(1)); s != 200 {
		t.Fatal("owner cannot read uncertain receipt")
	}
	// Transport failure leaves an uncertain slot too.
	m.transport = true
	if s, _ := ask(b, "caller_a", paneA, attA, 2); s != 503 {
		t.Fatalf("transport error status %d", s)
	}
	m.transport = false
	if o := b.mikoOwners[lid(2)]; o.state != mikoUncertain {
		t.Fatalf("transport slot %+v", o)
	}
	// Uncertain slots count toward the per-pane cap.
	m.acceptThen = 500
	for i := 3; len(b.mikoOwners) < mikoPaneCap; i++ {
		ask(b, "caller_a", paneA, attA, i)
	}
	if s, _ := ask(b, "caller_a", paneA, attA, 999); s != 429 {
		t.Fatalf("uncertain slots escaped the cap: %d", s)
	}
	// And they expire.
	clock = clock.Add(mikoReceiptTTL)
	if s, _ := receipt(b, "caller_a", paneA, attA, lid(1)); s != 403 || len(b.mikoOwners) != 0 {
		t.Fatalf("uncertain slot outlived lifetime: %d %d", s, len(b.mikoOwners))
	}
}

// An in-flight slot is not purged by the lifetime sweep, and a later uncertain
// answer does not downgrade a confirmed slot.
func TestMikoInflightAndConfirmedSlotsAreSticky(t *testing.T) {
	m := newFakeMac()
	g := newGated(m.desktop, attA)
	b := New("dandy-07", "fixture", g.call)
	clock := time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)
	var cm sync.Mutex
	b.now = func() time.Time { cm.Lock(); defer cm.Unlock(); return clock }
	a := async(func() (int, any) { return ask(b, "caller_a", paneA, attA, 1) })
	<-g.entered[attA]
	cm.Lock()
	clock = clock.Add(2 * mikoReceiptTTL)
	cm.Unlock()
	if s, _ := ask(b, "caller_b", paneB, attB, 2); s != 200 { // any call sweeps the table
		t.Fatal("other ask")
	}
	if _, ok := b.mikoOwners[lid(1)]; !ok {
		t.Fatal("in-flight slot purged")
	}
	close(g.release[attA])
	if r := <-a; r.status != 200 {
		t.Fatal("A")
	}
	m.acceptThen = 500
	if s, _ := ask(b, "caller_a", paneA, attB, 1); s != 403 { // wrong proof, rejected: still confirmed
		t.Fatal("replay with bad proof")
	}
	m.acceptThen = 0
	m.force = 503 // replay answered with an unknown outcome
	if s, _ := ask(b, "caller_a", paneA, attA2, 1); s != 503 {
		t.Fatal("uncertain replay")
	}
	if o := b.mikoOwners[lid(1)]; o.state != mikoConfirmed {
		t.Fatalf("confirmed slot downgraded: %+v", o)
	}
}

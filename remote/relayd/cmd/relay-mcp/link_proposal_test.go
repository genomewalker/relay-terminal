package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	linkTarget  = "129286a2-6e69-4d1a-9c83-91a0a2dec1e9"
	linkAttest  = "0123456789abcdef0123456789abcdef"
	linkOwnID   = "0c9d4e6b-7a21-4f83-b5e9-2d8f1a6c3e57"
	declineText = "relayd: both panes must belong to this daemon; remote peers require a server route"
)

type linkDesktop struct {
	paths  []string
	bodies []map[string]string
	status int
	reply  string
}

func remoteLinkServer(t *testing.T, attest nativeFixtureReply, d *linkDesktop) (server, string) {
	t.Helper()
	old := linkProposalRemote
	linkProposalRemote = func() bool { return true }
	t.Cleanup(func() { linkProposalRemote = old })
	wire := filepath.Join(t.TempDir(), "attest.json")
	attest.Record = true
	helper := nativeMCPFixture(t, nativeFixtureConfig{Pane: fallbackPane, Wire: wire,
		Default:    nativeFixtureReply{Error: declineText, Exit: 1},
		Operations: map[string]nativeFixtureReply{"attest": attest}})
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var body map[string]string
		_ = json.Unmarshal(raw, &body)
		d.paths = append(d.paths, r.URL.Path)
		d.bodies = append(d.bodies, body)
		w.WriteHeader(d.status)
		io.WriteString(w, d.reply)
	}))
	t.Cleanup(ts.Close)
	return server{daemonHelper: helper, callerToken: "fixture-caller", token: "fixture-desktop", client: ts.Client(), endpoint: ts.URL}, wire
}

func linkArgs(kv map[string]string) map[string]json.RawMessage {
	args := map[string]json.RawMessage{}
	for k, v := range kv {
		args[k], _ = json.Marshal(v)
	}
	return args
}

func readAttest(t *testing.T, wire string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(err)
	}
	var packet map[string]any
	_ = json.Unmarshal(data, &packet)
	return packet
}

func linkResultText(r any) string { b, _ := json.Marshal(r); return string(b) }

func TestRemoteCrossHostLinkBecomesAnAttestedProposal(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	d := &linkDesktop{status: 200, reply: `{"proposal_id":"` + linkOwnID + `","source_pane_id":"` + fallbackPane + `","status":"pending"}`}
	s, wire := remoteLinkServer(t, nativeFixtureReply{Out: `{"attestation_id":"` + linkAttest + `"}`}, d)
	result, handled := s.daemonCommunication("relay_link_panes", linkArgs(map[string]string{"pane_id": linkTarget, "proposal_id": linkOwnID}))
	if !handled || strings.Contains(linkResultText(result), `"isError":true`) {
		t.Fatalf("handled=%v %s", handled, linkResultText(result))
	}
	if len(d.paths) != 1 || d.paths[0] != linkProposalPath {
		t.Fatalf("must use only the proposal route, never /api/pane-links: %v", d.paths)
	}
	b := d.bodies[0]
	if b["op"] != "propose" || b["proposal_id"] != linkOwnID || b["source_pane_id"] != fallbackPane ||
		b["target_pane_id"] != linkTarget || b["attestation_id"] != linkAttest || len(b) != 5 {
		t.Fatalf("body %v", b)
	}
	// The proof is bound to the operation, both panes and the proposal id.
	p := readAttest(t, wire)
	if p["source_pane_id"] != fallbackPane || p["actor_pane_id"] != fallbackPane || p["pane_id"] != linkTarget ||
		p["message_id"] != linkOwnID || p["text"] != linkProposalText("propose", fallbackPane, linkTarget, linkOwnID) {
		t.Fatalf("attest packet %v", p)
	}
	if !strings.Contains(linkResultText(result), "pending") || !strings.Contains(linkResultText(result), "proposal_id="+linkOwnID) {
		t.Fatal("result must be a pending receipt the agent can poll", linkResultText(result))
	}
}

func TestRemoteProposalStatusReadIsAttestedToStatusOnly(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	d := &linkDesktop{status: 200, reply: `{"proposal_id":"` + linkOwnID + `","source_pane_id":"` + fallbackPane + `","status":"approved"}`}
	s, wire := remoteLinkServer(t, nativeFixtureReply{Out: `{"attestation_id":"` + linkAttest + `"}`}, d)
	result, handled := s.daemonCommunication("relay_link_panes", linkArgs(map[string]string{"proposal_id": linkOwnID}))
	if !handled || !strings.Contains(linkResultText(result), "approved") {
		t.Fatal(linkResultText(result))
	}
	if d.bodies[0]["op"] != "status" || len(d.bodies[0]) != 4 {
		t.Fatalf("body %v", d.bodies[0])
	}
	p := readAttest(t, wire)
	if p["pane_id"] != linkProposalInboxID || p["text"] != linkProposalText("status", fallbackPane, "", linkOwnID) {
		t.Fatalf("attest packet %v", p)
	}
}

func TestRemoteLinkRefusalsSendNothing(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	cases := map[string]struct {
		attest nativeFixtureReply
		args   map[string]string
	}{
		"attestation refused by relayd": {nativeFixtureReply{Error: "no", Exit: 1}, map[string]string{"pane_id": linkTarget}},
		"attestation reply malformed":   {nativeFixtureReply{Out: `{"attestation_id":"zz"}`}, map[string]string{"pane_id": linkTarget}},
		"missing target":                {nativeFixtureReply{Out: `{"attestation_id":"` + linkAttest + `"}`}, map[string]string{}},
		"bad target":                    {nativeFixtureReply{Out: `{"attestation_id":"` + linkAttest + `"}`}, map[string]string{"pane_id": "nope"}},
		"bad proposal id":               {nativeFixtureReply{Out: `{"attestation_id":"` + linkAttest + `"}`}, map[string]string{"pane_id": linkTarget, "proposal_id": "X"}},
	}
	for name, c := range cases {
		d := &linkDesktop{status: 200, reply: `{}`}
		s, _ := remoteLinkServer(t, c.attest, d)
		result, handled := s.daemonCommunication("relay_link_panes", linkArgs(c.args))
		if !handled || !strings.Contains(linkResultText(result), `"isError":true`) || len(d.paths) != 0 {
			t.Errorf("%s: handled=%v sent=%v %s", name, handled, d.paths, linkResultText(result))
		}
	}
}

func TestRemoteLinkWithoutProvenPaneDoesNotFallBackToTheDirectRoute(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	d := &linkDesktop{status: 200, reply: `{}`}
	s, _ := remoteLinkServer(t, nativeFixtureReply{Out: `{"attestation_id":"` + linkAttest + `"}`}, d)
	s.daemonHelper = nativeFixtureWithoutActor(t, s.daemonHelper)
	result, handled := s.daemonCommunication("relay_link_panes", linkArgs(map[string]string{"pane_id": linkTarget}))
	if !handled || !strings.Contains(linkResultText(result), `"isError":true`) || len(d.paths) != 0 {
		t.Fatalf("handled=%v sent=%v %s", handled, d.paths, linkResultText(result))
	}
}

func TestLinkProposalProofCannotBeAMikoProof(t *testing.T) {
	if strings.HasPrefix(linkProposalText("propose", "a", "b", "c"), mikoSupervisorPrefix) ||
		linkProposalInboxID == mikoInboxID ||
		linkProposalText("propose", "a", "b", "c") == mikoCanonicalText("relay_ask_miko", "{}") {
		t.Fatal("proposal and Miko proofs must be disjoint")
	}
	if linkProposalText("propose", "s", "t", "i") == linkProposalText("status", "s", "t", "i") {
		t.Fatal("operations must be distinguishable in the proof")
	}
}

package daemon

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Test-only owner signer. The production signer belongs to the Mac app; this
// fixture produces the exact record format communicationVerifyScope accepts.
type scopeOwner struct {
	node string
	root string
	pem  string
}

func newScopeOwner(t *testing.T, node string) scopeOwner {
	t.Helper()
	root, pem := peerFixture(t, node)
	return scopeOwner{node: node, root: root, pem: pem}
}

func (o scopeOwner) sign(t *testing.T, holder string, revision uint64, members ...communicationScopeMember) communicationScopeRecord {
	t.Helper()
	sort.Slice(members, func(i, j int) bool { return communicationScopeKey(members[i]) < communicationScopeKey(members[j]) })
	if members == nil {
		members = []communicationScopeMember{}
	}
	body := communicationScopeBody{Version: 1, Purpose: communicationScopePurpose, ScopeID: "scope-one", HolderNodeID: holder, OwnerNodeID: o.node,
		Revision: revision, CreatedAt: time.Now().UTC(), Members: members}
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	return o.signRaw(t, raw)
}

func (o scopeOwner) signRaw(t *testing.T, raw []byte) communicationScopeRecord {
	t.Helper()
	key, _, err := (communicationFileKeyStore{root: o.root, node: o.node}).HostKey()
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(key, append([]byte(communicationScopeDomain), raw...))
	return communicationScopeRecord{Version: 1, Body: base64.StdEncoding.EncodeToString(raw), OwnerCertificatePEM: o.pem, Signature: base64.StdEncoding.EncodeToString(signature)}
}

func (o scopeOwner) pin(t *testing.T, root, node string, signs bool) {
	t.Helper()
	cert, err := peerCertificate(o.pem, o.node)
	if err != nil {
		t.Fatal(err)
	}
	entry := communicationTrustedNode{NodeID: o.node, CertificatePEM: o.pem, CertificateSHA256: peerFingerprint(cert), SignsScopes: signs}
	if _, err := communicationNodeTrustSet(root, node, CommunicationRequest{Operation: "node_trust_set", TrustedNodes: []communicationTrustedNode{entry}}); err != nil {
		t.Fatal(err)
	}
}

func scopePair() []communicationScopeMember {
	return []communicationScopeMember{{NodeID: "node-a", PaneID: testGroupA}, {NodeID: "node-b", PaneID: testGroupB}}
}

func setScope(t *testing.T, root, node string, rec communicationScopeRecord) {
	t.Helper()
	if _, err := communicationRouteOperation(root, node, CommunicationRequest{Operation: "route_scope_set", Scope: &rec}); err != nil {
		t.Fatal(err)
	}
}

type scopeFixture struct {
	a, b, acert, bcert string
	owner              scopeOwner
	req                CommunicationRequest
	ahooks, bhooks     communicationGroupNative
	calls              *atomic.Int32
	bConv              *communicationPinnedConversation
}

// scopeFixtureNew builds two hosts with a route and a live TLS peer endpoint on
// B, no remote links, and both hosts pinning the owner and holding a scope that
// lists the pair (unless the option removes it).
func scopeFixtureNew(t *testing.T, dropSendReply bool) *scopeFixture {
	t.Helper()
	f := &scopeFixture{calls: &atomic.Int32{}}
	f.a, f.acert = peerFixture(t, "node-a")
	f.b, f.bcert = peerFixture(t, "node-b")
	f.owner = newScopeOwner(t, "owner-mac")
	localA := communicationPinnedConversation{Provider: "codex", SessionID: "source-conversation"}
	localB := &communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"}
	f.bConv = localB
	f.bhooks = communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: localB.Provider, SessionID: localB.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}, send: func(string, map[string]any) (map[string]any, error) {
		f.calls.Add(1)
		return map[string]any{"status": "accepted", "acknowledgement": "provider_accepted"}, nil
	}}
	f.ahooks = communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: localA.Provider, SessionID: localA.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}}
	handler := peerHandler(f.b, "node-b", f.bhooks)
	if dropSendReply {
		base := handler
		handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			data, _ := io.ReadAll(r.Body)
			r.Body = io.NopCloser(bytes.NewReader(data))
			var message communicationRemoteMessage
			_ = json.Unmarshal(data, &message)
			if message.Operation == "send" {
				base.ServeHTTP(httptest.NewRecorder(), r)
				connection, _, err := w.(http.Hijacker).Hijack()
				if err == nil {
					_ = connection.Close()
				}
				return
			}
			base.ServeHTTP(w, r)
		})
	}
	server := httptest.NewUnstartedServer(handler)
	var err error
	if server.TLS, err = peerServerTLS(f.b, "node-b"); err != nil {
		t.Fatal(err)
	}
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	t.Cleanup(server.Close)
	enrollPeer(t, f.a, "node-a", "node-b", strings.TrimPrefix(server.URL, "https://"), f.bcert)
	enrollPeer(t, f.b, "node-b", "node-a", "127.0.0.1:1", f.acert)
	digest := sha256.Sum256([]byte(remoteSenderToken))
	if err := communicationAtomic(communicationPolicyPath(f.a), communicationPolicy{Callers: []communicationCaller{{ID: "sender", Label: "Fixture", TokenHash: hex.EncodeToString(digest[:])}}}); err != nil {
		t.Fatal(err)
	}
	for _, h := range []struct{ root, node string }{{f.a, "node-a"}, {f.b, "node-b"}} {
		f.owner.pin(t, h.root, h.node, true)
		setScope(t, h.root, h.node, f.owner.sign(t, h.node, 1, scopePair()...))
	}
	f.req = CommunicationRequest{Operation: "remote_send", LinkID: remotePairID("node-a", testGroupA, "node-b", testGroupB), SourcePaneID: testGroupA, PaneID: testGroupB,
		PeerNodeID: "node-b", MessageID: testGroupID, ExpectedRemoteLinkRevision: 0, Text: "private fixture collaborator input", ClientToken: remoteSenderToken, ActorPaneID: testGroupA}
	return f
}

func linkFiles(t *testing.T, root string) []string {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
	if err != nil {
		t.Fatal(err)
	}
	return paths
}

func TestScopeEstablishPositiveReciprocalRevisionOneAndSingleDelivery(t *testing.T) {
	f := scopeFixtureNew(t, false)
	result, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks)
	if err != nil || result["status"] != "accepted" || result["message_id"] != testGroupID || result["replay_permitted"] != false || result["peer_authentication"] != "mutual_tls_pinned_node" || f.calls.Load() != 1 {
		t.Fatal(result, err, f.calls.Load())
	}
	id := remotePairID("node-a", testGroupA, "node-b", testGroupB)
	la, err := readRemoteLink(f.a, "node-a", id)
	if err != nil {
		t.Fatal(err)
	}
	lb, err := readRemoteLink(f.b, "node-b", id)
	if err != nil {
		t.Fatal(err)
	}
	if la.Revision != 1 || la.PeerRevision != 1 || lb.Revision != 1 || lb.PeerRevision != 1 || la.Retired || lb.Retired {
		t.Fatal("not reciprocal revision 1", la, lb)
	}
	if len(la.AllowedPeerCallers) != 1 || la.AllowedPeerCallers[0] != "sender" || len(lb.AllowedPeerCallers) != 1 || lb.AllowedPeerCallers[0] != "sender" {
		t.Fatal("callers must be only the proposing pane's registered caller", la.AllowedPeerCallers, lb.AllowedPeerCallers)
	}
	if la.PeerConversation != lb.LocalConversation || lb.PeerConversation != la.LocalConversation || la.PeerCertificateSHA256 == "" || la.PeerCertificateSHA256 == lb.PeerCertificateSHA256 {
		t.Fatal("pins are not reciprocal", la, lb)
	}
	for _, root := range []string{f.a, f.b} {
		data, err := os.ReadFile(filepath.Join(root, "scope-establish-"+id+".jsonl"))
		if err != nil || !strings.Contains(string(data), `"status":"established"`) || strings.Contains(string(data), remoteSenderToken) {
			t.Fatal("establish audit missing or leaks credential", err)
		}
	}
	// A retry of the same message id returns the stored receipt and never re-posts.
	retry := f.req
	retry.ExpectedRemoteLinkRevision = 1
	if _, err := communicationSendRemote(f.a, "node-a", retry, f.ahooks); err != nil || f.calls.Load() != 1 {
		t.Fatal("retry replayed", err, f.calls.Load())
	}
	// With the link saved, a fresh message id uses the ordinary path.
	next := retry
	next.MessageID = "44444444-4444-4444-8444-444444444444"
	if result, err := communicationSendRemote(f.a, "node-a", next, f.ahooks); err != nil || result["status"] != "accepted" || f.calls.Load() != 2 {
		t.Fatal(result, err)
	}
}

func TestScopeEstablishLostSendReplyStaysOutcomeUnknownWithoutReplay(t *testing.T) {
	f := scopeFixtureNew(t, true)
	result, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks)
	if err != nil || result["status"] != "outcome_unknown" || result["replay_permitted"] != false || result["message_id"] != testGroupID || f.calls.Load() != 1 {
		t.Fatal(result, err, f.calls.Load())
	}
	retry := f.req
	retry.ExpectedRemoteLinkRevision = 1
	if _, err := communicationSendRemote(f.a, "node-a", retry, f.ahooks); err != nil || f.calls.Load() != 1 {
		t.Fatal("lost reply was re-delivered", err, f.calls.Load())
	}
	retry.Operation, retry.Text = "remote_receipt", ""
	if result, err := communicationSendRemote(f.a, "node-a", retry, f.ahooks); err != nil || result["status"] != "accepted" || f.calls.Load() != 1 {
		t.Fatal("receipt recovery failed", result, err)
	}
}

func TestScopeEstablishIsIdempotentOnTheAcceptingSide(t *testing.T) {
	f := scopeFixtureNew(t, false)
	if _, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks); err != nil {
		t.Fatal(err)
	}
	id := remotePairID("node-a", testGroupA, "node-b", testGroupB)
	before, err := os.ReadFile(remoteLinkPath(f.b, id))
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := peerCertificate(f.acert, "node-a")
	m := communicationEstablishWire{Version: establishWireVersion, Operation: "establish", MessageID: "55555555-5555-4555-8555-555555555555", SourceNodeID: "node-a", TargetNodeID: "node-b",
		SourcePaneID: testGroupA, TargetPaneID: testGroupB, CallerID: "sender", SourceConversation: communicationPinnedConversation{Provider: "codex", SessionID: "source-conversation"}, ScopeID: "scope-one"}
	m.Fingerprint = establishFingerprint(m)
	for i := 0; i < 2; i++ {
		result, err := communicationReceiveEstablish(f.b, "node-b", peerFingerprint(cert), m, f.bhooks)
		if err != nil || result["status"] != "current" {
			t.Fatal(i, result, err)
		}
	}
	after, _ := os.ReadFile(remoteLinkPath(f.b, id))
	if !bytes.Equal(before, after) || len(linkFiles(t, f.b)) != 1 {
		t.Fatal("idempotent establish changed the saved half")
	}
}

func TestScopeOutOfScopePairKeepsOriginalMissingLinkBehavior(t *testing.T) {
	cases := map[string]func(f *scopeFixture, t *testing.T){
		"no scope on proposer": func(f *scopeFixture, t *testing.T) { _ = os.Remove(communicationScopePath(f.a)) },
		"target not listed": func(f *scopeFixture, t *testing.T) {
			setScope(t, f.a, "node-a", f.owner.sign(t, "node-a", 2, communicationScopeMember{NodeID: "node-a", PaneID: testGroupA}, communicationScopeMember{NodeID: "node-b", PaneID: testGroupID}))
		},
		"source not listed": func(f *scopeFixture, t *testing.T) {
			setScope(t, f.a, "node-a", f.owner.sign(t, "node-a", 2, communicationScopeMember{NodeID: "node-a", PaneID: testGroupID}, communicationScopeMember{NodeID: "node-b", PaneID: testGroupB}))
		},
		"revoked by empty scope": func(f *scopeFixture, t *testing.T) { setScope(t, f.a, "node-a", f.owner.sign(t, "node-a", 2)) },
		"pin removed":            func(f *scopeFixture, t *testing.T) { _ = os.Remove(communicationTrustPath(f.a)) },
		"owner not allowed to sign scopes": func(f *scopeFixture, t *testing.T) {
			f.owner.pin(t, f.a, "node-a", false)
		},
		"scope file tampered": func(f *scopeFixture, t *testing.T) {
			var rec communicationScopeRecord
			if err := communicationRead(communicationScopePath(f.a), &rec); err != nil {
				t.Fatal(err)
			}
			raw, _ := base64.StdEncoding.DecodeString(rec.Body)
			rec.Body = base64.StdEncoding.EncodeToString(bytes.Replace(raw, []byte(testGroupB), []byte(testGroupID), 1))
			if err := communicationAtomic(communicationScopePath(f.a), rec); err != nil {
				t.Fatal(err)
			}
		},
		"no registered caller": func(f *scopeFixture, t *testing.T) {
			f.req.ClientToken, f.req.ActorPaneID = "", ""
		},
		"missing peer node": func(f *scopeFixture, t *testing.T) { f.req.PeerNodeID = "" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			f := scopeFixtureNew(t, false)
			mutate(f, t)
			_, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks)
			if err == nil || !errors.Is(err, os.ErrNotExist) && !strings.Contains(err.Error(), "caller") && !strings.Contains(err.Error(), "valid reviewed remote pair") {
				t.Fatal("expected the original refusal", err)
			}
			if len(linkFiles(t, f.a)) != 0 || len(linkFiles(t, f.b)) != 0 || f.calls.Load() != 0 {
				t.Fatal("state written for an out-of-scope pair")
			}
			if _, statErr := os.Stat(remoteOutboundPath(f.a, f.req.MessageID)); statErr == nil {
				t.Fatal("outbound claim written")
			}
		})
	}
}

func TestScopePairMustBeInScopeOnBothHosts(t *testing.T) {
	for name, listed := range map[string][]communicationScopeMember{
		"peer scope empty":          nil,
		"peer lacks target":         {{NodeID: "node-a", PaneID: testGroupA}, {NodeID: "node-b", PaneID: testGroupID}},
		"peer lacks source":         {{NodeID: "node-a", PaneID: testGroupID}, {NodeID: "node-b", PaneID: testGroupB}},
		"peer lists only own panes": {{NodeID: "node-b", PaneID: testGroupB}},
	} {
		t.Run(name, func(t *testing.T) {
			f := scopeFixtureNew(t, false)
			setScope(t, f.b, "node-b", f.owner.sign(t, "node-b", 2, listed...))
			if _, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks); err == nil {
				t.Fatal("pair established although the peer scope does not allow it")
			}
			if len(linkFiles(t, f.a)) != 0 || len(linkFiles(t, f.b)) != 0 || f.calls.Load() != 0 {
				t.Fatal("half-established pair left behind")
			}
			if _, statErr := os.Stat(remoteOutboundPath(f.a, f.req.MessageID)); statErr == nil {
				t.Fatal("outbound claim written")
			}
		})
	}
	t.Run("peer has no scope file", func(t *testing.T) {
		f := scopeFixtureNew(t, false)
		_ = os.Remove(communicationScopePath(f.b))
		if _, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks); err == nil || len(linkFiles(t, f.a)) != 0 || len(linkFiles(t, f.b)) != 0 {
			t.Fatal("pair established without a peer scope", err)
		}
	})
}

func TestScopeEstablishRejectsUnpinnedPeerCertificate(t *testing.T) {
	f := scopeFixtureNew(t, false)
	_, otherCert := peerFixture(t, "node-a")
	other, _ := peerCertificate(otherCert, "node-a")
	m := communicationEstablishWire{Version: establishWireVersion, Operation: "establish", MessageID: "55555555-5555-4555-8555-555555555555", SourceNodeID: "node-a", TargetNodeID: "node-b",
		SourcePaneID: testGroupA, TargetPaneID: testGroupB, CallerID: "sender", SourceConversation: communicationPinnedConversation{Provider: "codex", SessionID: "source-conversation"}, ScopeID: "scope-one"}
	m.Fingerprint = establishFingerprint(m)
	if _, err := communicationReceiveEstablish(f.b, "node-b", peerFingerprint(other), m, f.bhooks); err == nil {
		t.Fatal("establish from an unpinned certificate accepted")
	}
	// A pinned certificate cannot speak for a different node either.
	good, _ := peerCertificate(f.acert, "node-a")
	wrongNode := m
	wrongNode.SourceNodeID = "node-z"
	wrongNode.Fingerprint = establishFingerprint(wrongNode)
	if _, err := communicationReceiveEstablish(f.b, "node-b", peerFingerprint(good), wrongNode, f.bhooks); err == nil {
		t.Fatal("establish for an unrouted node accepted")
	}
	// Tampered fingerprint and legacy caller are rejected before any state.
	bad := m
	bad.Fingerprint = strings.Repeat("0", 64)
	legacy := m
	legacy.CallerID = establishLegacyCaller
	legacy.Fingerprint = establishFingerprint(legacy)
	for _, wire := range []communicationEstablishWire{bad, legacy} {
		if _, err := communicationReceiveEstablish(f.b, "node-b", peerFingerprint(good), wire, f.bhooks); err == nil {
			t.Fatal("invalid establish accepted", wire)
		}
	}
	if len(linkFiles(t, f.b)) != 0 {
		t.Fatal("link written by rejected establish")
	}
}

func TestScopeEstablishNeverReplacesExistingLinkOrSubstitutesConversation(t *testing.T) {
	setup := func(t *testing.T) (*scopeFixture, communicationEstablishWire, string, []byte) {
		f := scopeFixtureNew(t, false)
		if _, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks); err != nil {
			t.Fatal(err)
		}
		id := remotePairID("node-a", testGroupA, "node-b", testGroupB)
		before, err := os.ReadFile(remoteLinkPath(f.b, id))
		if err != nil {
			t.Fatal(err)
		}
		m := communicationEstablishWire{Version: establishWireVersion, Operation: "establish", MessageID: "55555555-5555-4555-8555-555555555555", SourceNodeID: "node-a", TargetNodeID: "node-b",
			SourcePaneID: testGroupA, TargetPaneID: testGroupB, CallerID: "sender", SourceConversation: communicationPinnedConversation{Provider: "codex", SessionID: "source-conversation"}, ScopeID: "scope-one"}
		return f, m, id, before
	}
	cert := func(f *scopeFixture) string { c, _ := peerCertificate(f.acert, "node-a"); return peerFingerprint(c) }
	t.Run("different caller", func(t *testing.T) {
		f, m, id, before := setup(t)
		m.CallerID = "someone-else"
		m.Fingerprint = establishFingerprint(m)
		if _, err := communicationReceiveEstablish(f.b, "node-b", cert(f), m, f.bhooks); err == nil {
			t.Fatal("existing link replaced with different callers")
		}
		after, _ := os.ReadFile(remoteLinkPath(f.b, id))
		if !bytes.Equal(before, after) {
			t.Fatal("existing link modified")
		}
	})
	t.Run("different proposer conversation", func(t *testing.T) {
		f, m, id, before := setup(t)
		m.SourceConversation = communicationPinnedConversation{Provider: "codex", SessionID: "another-conversation"}
		m.Fingerprint = establishFingerprint(m)
		if _, err := communicationReceiveEstablish(f.b, "node-b", cert(f), m, f.bhooks); err == nil {
			t.Fatal("existing link replaced with a substituted conversation")
		}
		after, _ := os.ReadFile(remoteLinkPath(f.b, id))
		if !bytes.Equal(before, after) {
			t.Fatal("existing link modified")
		}
	})
	t.Run("recipient live conversation differs from saved pin", func(t *testing.T) {
		f, m, id, before := setup(t)
		*f.bConv = communicationPinnedConversation{Provider: "claude", SessionID: "different-conversation"}
		m.Fingerprint = establishFingerprint(m)
		if _, err := communicationReceiveEstablish(f.b, "node-b", cert(f), m, f.bhooks); err == nil {
			t.Fatal("substituted recipient conversation accepted")
		}
		after, _ := os.ReadFile(remoteLinkPath(f.b, id))
		if !bytes.Equal(before, after) {
			t.Fatal("existing link modified")
		}
	})
	t.Run("retired link is not revived", func(t *testing.T) {
		f, m, id, _ := setup(t)
		if _, err := communicationRemoteLinkOperation(f.b, "node-b", CommunicationRequest{Operation: "route_link_retire", LinkID: id, ExpectedRemoteLinkRevision: 1}); err != nil {
			t.Fatal(err)
		}
		before, _ := os.ReadFile(remoteLinkPath(f.b, id))
		m.Fingerprint = establishFingerprint(m)
		if _, err := communicationReceiveEstablish(f.b, "node-b", cert(f), m, f.bhooks); err == nil {
			t.Fatal("retired link revived")
		}
		after, _ := os.ReadFile(remoteLinkPath(f.b, id))
		if !bytes.Equal(before, after) {
			t.Fatal("retired link modified")
		}
	})
	t.Run("proposer side refuses to overwrite a link created meanwhile", func(t *testing.T) {
		f := scopeFixtureNew(t, false)
		id := remotePairID("node-a", testGroupA, "node-b", testGroupB)
		route, _, c, err := activePeerRoute(f.a, "node-a", "route")
		if err != nil {
			t.Fatal(err)
		}
		other := CommunicationRemoteLink{PeerNodeID: "node-b", LocalPaneID: testGroupA, PeerPaneID: testGroupB, RouteID: "route", RouteRevision: route.Revision, PeerCertificateSHA256: peerFingerprint(c),
			LocalConversation: communicationPinnedConversation{Provider: "codex", SessionID: "source-conversation"}, PeerConversation: communicationPinnedConversation{Provider: "claude", SessionID: "other-target"},
			AllowedPeerCallers: []string{"receiver"}}
		if _, _, err := communicationEstablishCommit(f.a, "node-a", other, "scope-one", "proposer", "x"); err != nil {
			t.Fatal(err)
		}
		before, _ := os.ReadFile(remoteLinkPath(f.a, id))
		other.AllowedPeerCallers = []string{"sender"}
		if _, _, err := communicationEstablishCommit(f.a, "node-a", other, "scope-one", "proposer", "x"); err == nil {
			t.Fatal("link with different pins replaced")
		}
		after, _ := os.ReadFile(remoteLinkPath(f.a, id))
		if !bytes.Equal(before, after) {
			t.Fatal("existing link modified")
		}
	})
}

func TestScopeEstablishRespectsCatalogueCap(t *testing.T) {
	f := scopeFixtureNew(t, false)
	for i := 0; i < 256; i++ {
		name := filepath.Join(f.b, "remote-link-"+strings.Repeat("0", 60)+string(rune('a'+i/26))+string(rune('a'+i%26))+"0.json")
		if err := os.WriteFile(name, []byte("{}"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks); err == nil {
		t.Fatal("establish beyond the 256-pair cap accepted")
	}
	if len(linkFiles(t, f.a)) != 0 || f.calls.Load() != 0 {
		t.Fatal("state written despite cap")
	}
}

func TestScopeRecordVerificationAndAdministration(t *testing.T) {
	root, _ := peerFixture(t, "node-a")
	owner := newScopeOwner(t, "owner-mac")
	owner.pin(t, root, "node-a", true)
	good := owner.sign(t, "node-a", 1, scopePair()...)
	trusted, err := communicationTrustedNodes(root, defaultCommunicationSigningDeps(root, "node-a"), "node-a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := communicationVerifyScope(good, trusted, "node-a"); err != nil {
		t.Fatal(err)
	}
	other := newScopeOwner(t, "owner-mac")
	forged := other.sign(t, "node-a", 1, scopePair()...)
	badSig := good
	badSig.Signature = base64.StdEncoding.EncodeToString(make([]byte, ed25519.SignatureSize))
	noSig := good
	noSig.Signature = ""
	rawOther := []byte(`{"v":1,"purpose":"relay-collaboration-scope","scope_id":"scope-one","holder_node_id":"node-z","owner_node_id":"owner-mac","revision":1,"created_at":"2026-11-05T00:00:00Z","members":[{"node_id":"node-b","pane_id":"` + testGroupB + `"},{"node_id":"node-z","pane_id":"` + testGroupA + `"}]}`)
	for name, rec := range map[string]communicationScopeRecord{
		"unpinned key":            forged,
		"bad signature":           badSig,
		"absent signature":        noSig,
		"other holder node":       owner.sign(t, "node-b", 1, scopePair()...),
		"signed for another node": owner.signRaw(t, rawOther),
		"no member on holder":     owner.sign(t, "node-a", 1, communicationScopeMember{NodeID: "node-b", PaneID: testGroupB}),
		"revision zero":           owner.sign(t, "node-a", 0, scopePair()...),
		"unsorted members":        owner.signRaw(t, []byte(`{"v":1,"purpose":"relay-collaboration-scope","scope_id":"scope-one","holder_node_id":"node-a","owner_node_id":"owner-mac","revision":1,"created_at":"2026-11-05T00:00:00Z","members":[{"node_id":"node-b","pane_id":"`+testGroupB+`"},{"node_id":"node-a","pane_id":"`+testGroupA+`"}]}`)),
		"unknown field":           owner.signRaw(t, []byte(`{"v":1,"purpose":"relay-collaboration-scope","scope_id":"scope-one","holder_node_id":"node-a","owner_node_id":"owner-mac","revision":1,"created_at":"2026-11-05T00:00:00Z","members":[],"extra":1}`)),
		"wrong purpose":           owner.signRaw(t, []byte(`{"v":1,"purpose":"other","scope_id":"scope-one","holder_node_id":"node-a","owner_node_id":"owner-mac","revision":1,"created_at":"2026-11-05T00:00:00Z","members":[]}`)),
	} {
		if _, err := communicationVerifyScope(rec, trusted, "node-a"); err == nil {
			t.Fatal("accepted invalid scope record:", name)
		}
	}
	// Owner-only administration: provider credentials and actor panes are refused.
	for _, r := range []CommunicationRequest{
		{Operation: "route_scope_set", Scope: &good, ClientToken: "token"},
		{Operation: "route_scope_set", Scope: &good, ActorPaneID: testGroupA},
	} {
		if _, err := communicationRouteOperation(root, "node-a", r); err == nil || !strings.Contains(err.Error(), "owner administration required") {
			t.Fatal("provider-credential scope write accepted", err)
		}
	}
	if _, err := communicationScopeSet(root, "node-a", CommunicationRequest{Operation: "route_scope_set", Scope: &good, ClientToken: "token"}); err == nil {
		t.Fatal("direct reducer accepted a provider credential")
	}
	if _, err := os.Stat(communicationScopePath(root)); err == nil {
		t.Fatal("scope written by rejected request")
	}
	// Records are monotonic: an equal or lower revision never replaces.
	setScope(t, root, "node-a", owner.sign(t, "node-a", 2, scopePair()...))
	for _, revision := range []uint64{1, 2} {
		rec := owner.sign(t, "node-a", revision, scopePair()...)
		if _, err := communicationRouteOperation(root, "node-a", CommunicationRequest{Operation: "route_scope_set", Scope: &rec}); err == nil {
			t.Fatal("stale scope revision accepted", revision)
		}
	}
	setScope(t, root, "node-a", owner.sign(t, "node-a", 3))
	if _, ok := communicationScopeAllows(root, "node-a", "node-a", testGroupA, "node-b", testGroupB); ok {
		t.Fatal("revoked scope still allows the pair")
	}
}

func TestScopeEstablishOrphanPeerHalfConverges(t *testing.T) {
	id := remotePairID("node-a", testGroupA, "node-b", testGroupB)
	// First attempt: the peer confirms and saves, then the proposer's locked
	// re-check fails because its source conversation changed in flight.
	orphan := func(t *testing.T) (*scopeFixture, []byte, func(string, string)) {
		f := scopeFixtureNew(t, false)
		var n atomic.Int32
		var session atomic.Value
		session.Store("source-conversation")
		f.ahooks.observe = func(pane string) communicationMember {
			s := session.Load().(string)
			if n.Add(1) == 2 {
				s = "changed-in-flight"
			}
			return communicationMember{PaneID: pane, Provider: "codex", SessionID: s, Endpoint: map[string]any{"transport": "fixture"}}
		}
		if _, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks); err == nil {
			t.Fatal("proposer commit should have failed")
		}
		if len(linkFiles(t, f.b)) != 1 || len(linkFiles(t, f.a)) != 0 || f.calls.Load() != 0 {
			t.Fatal("expected peer-only half and no delivery")
		}
		if _, err := os.Stat(remoteOutboundPath(f.a, f.req.MessageID)); err == nil {
			t.Fatal("outbound claim written")
		}
		before, err := os.ReadFile(remoteLinkPath(f.b, id))
		if err != nil {
			t.Fatal(err)
		}
		n.Store(100) // later calls are never the failing second call
		return f, before, func(provider, s string) { session.Store(s) }
	}
	auditLines := func(t *testing.T, root string) int {
		data, err := os.ReadFile(filepath.Join(root, "scope-establish-"+id+".jsonl"))
		if err != nil {
			t.Fatal(err)
		}
		return strings.Count(string(data), "\n")
	}
	t.Run("retry converges", func(t *testing.T) {
		f, before, _ := orphan(t)
		result, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks)
		if err != nil || result["status"] != "accepted" || result["replay_permitted"] != false || result["message_id"] != testGroupID || f.calls.Load() != 1 {
			t.Fatal(result, err, f.calls.Load())
		}
		after, _ := os.ReadFile(remoteLinkPath(f.b, id))
		if !bytes.Equal(before, after) || auditLines(t, f.b) != 1 {
			t.Fatal("peer half rewritten instead of answering current")
		}
		la, err := readRemoteLink(f.a, "node-a", id)
		if err != nil || la.Revision != 1 || auditLines(t, f.a) != 1 {
			t.Fatal("proposer half not saved once", err)
		}
	})
	t.Run("changed source conversation is refused", func(t *testing.T) {
		f, before, change := orphan(t)
		change("codex", "different-conversation")
		if _, err := communicationSendRemote(f.a, "node-a", f.req, f.ahooks); err == nil {
			t.Fatal("retry with a substituted conversation accepted")
		}
		after, _ := os.ReadFile(remoteLinkPath(f.b, id))
		if !bytes.Equal(before, after) || len(linkFiles(t, f.a)) != 0 || f.calls.Load() != 0 {
			t.Fatal("state changed by refused retry")
		}
		if _, err := os.Stat(remoteOutboundPath(f.a, f.req.MessageID)); err == nil {
			t.Fatal("outbound claim written")
		}
	})
}

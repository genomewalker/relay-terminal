package daemon

import (
	"testing"
	"time"
)

const scopePaneA = "1652a003-70e9-4614-addb-68564fa8383b"
const scopePaneB = "5a30d83a-5222-48f3-93c7-42fa687d901b"
const scopePaneC = "800c06ef-203f-4401-bf7a-c67b15985f33"

// pinScopeSigner trusts one host's certificate as a scope signer on root.
func pinScopeSigner(t *testing.T, root, node, certPEM string) {
	t.Helper()
	cert, err := peerCertificate(certPEM, node)
	if err != nil {
		t.Fatal(err)
	}
	set := communicationTrustSet{Version: 1, Nodes: []communicationTrustedNode{{NodeID: node, CertificatePEM: certPEM,
		CertificateSHA256: peerFingerprint(cert), SignsMessages: true, SignsScopes: true}}}
	if err := communicationAtomic(communicationTrustPath(root), set); err != nil {
		t.Fatal(err)
	}
}

// Per-pair scopes: the exact pair is allowed, in either order, and nothing else.
func TestPerPairScopeAllowsExactPairOnly(t *testing.T) {
	a, certA := peerFixture(t, "node-a")
	b, certB := peerFixture(t, "node-b")
	pinScopeSigner(t, a, "node-a", certA)
	pinScopeSigner(t, b, "node-a", certA)
	_ = certB
	paneA := communicationScopeMember{NodeID: "node-a", PaneID: scopePaneA}
	paneB := communicationScopeMember{NodeID: "node-b", PaneID: scopePaneB}
	now := time.Now()
	body := communicationPairScopeBody("pair-scope-1", "node-a", "node-a", 1, now, paneA, paneB)
	record, err := communicationSignScope(a, "node-a", body)
	if err != nil {
		t.Fatal(err)
	}
	trusted, err := communicationTrustedNodes(a, defaultCommunicationSigningDeps(a, "node-a"), "node-a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := communicationScopeStorePair(a, "node-a", record, trusted); err != nil {
		t.Fatal("store holder record", err)
	}
	if id, ok := communicationScopeAllows(a, "node-a", "node-a", scopePaneA, "node-b", scopePaneB); !ok || id != "pair-scope-1" {
		t.Fatal("exact pair not allowed")
	}
	if _, ok := communicationScopeAllows(a, "node-a", "node-b", scopePaneB, "node-a", scopePaneA); !ok {
		t.Fatal("the pair is order-dependent")
	}
	if _, ok := communicationScopeAllows(a, "node-a", "node-a", scopePaneC, "node-b", scopePaneB); ok {
		t.Fatal("a pane outside the pair was allowed")
	}
	if _, ok := communicationScopeAllows(a, "node-a", "node-a", scopePaneA, "node-b", scopePaneC); ok {
		t.Fatal("a session outside the pair was allowed")
	}
	// The same revision again never replaces it.
	if _, err := communicationScopeStorePair(a, "node-a", record, trusted); err == nil {
		t.Fatal("an equal revision replaced the pair's record")
	}
	// The peer's record for the same pair is stored on the peer's own host.
	peerTrusted, err := communicationTrustedNodes(b, defaultCommunicationSigningDeps(b, "node-b"), "node-b")
	if err != nil {
		t.Fatal(err)
	}
	peerRecord, err := communicationSignScope(a, "node-a", communicationPairScopeBody("pair-scope-1", "node-b", "node-a", 1, now, paneA, paneB))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := communicationScopeStorePair(b, "node-b", peerRecord, peerTrusted); err != nil {
		t.Fatal("peer holder record", err)
	}
	if _, ok := communicationScopeAllows(b, "node-b", "node-a", scopePaneA, "node-b", scopePaneB); !ok {
		t.Fatal("the peer does not allow its pair")
	}
}

// The single legacy scope-record.json keeps working for the pair it names.
func TestLegacyScopeRecordStillAllowsItsPair(t *testing.T) {
	root, certA := peerFixture(t, "node-a")
	pinScopeSigner(t, root, "node-a", certA)
	paneA := communicationScopeMember{NodeID: "node-a", PaneID: scopePaneA}
	paneB := communicationScopeMember{NodeID: "node-b", PaneID: scopePaneB}
	body := communicationPairScopeBody("legacy-scope", "node-a", "node-a", 1, time.Now(), paneA, paneB)
	record, err := communicationSignScope(root, "node-a", body)
	if err != nil {
		t.Fatal(err)
	}
	if err := communicationAtomic(communicationScopePath(root), record); err != nil {
		t.Fatal(err)
	}
	if id, ok := communicationScopeAllows(root, "node-a", "node-a", scopePaneA, "node-b", scopePaneB); !ok || id != "legacy-scope" {
		t.Fatal("legacy scope no longer allows its pair")
	}
	if _, ok := communicationScopeAllows(root, "node-a", "node-a", scopePaneC, "node-b", scopePaneB); ok {
		t.Fatal("legacy scope allowed another pair")
	}
}

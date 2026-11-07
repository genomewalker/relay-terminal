package daemon

import "testing"

// The scope-signing pin is an owner decision, audited, and revocable. A client
// cannot make it, and an unpinned signer's scope is refused on the peer.
func TestTrustScopePinIsOwnerOnlyAuditedAndRevocable(t *testing.T) {
	root, cert := peerFixture(t, "node-a")
	pinScopeSigner(t, root, "node-a", cert)
	c, err := peerCertificate(cert, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	fingerprint := peerFingerprint(c)
	if _, err := communicationTrustScopePin(root, "node-a", CommunicationRequest{Operation: "route_trust_scope_pin", ClientToken: "provider",
		TrustPin: &communicationTrustPin{NodeID: "node-a", CertificateSHA256: fingerprint, SignsScopes: true, Approval: "approval-1"}},
		defaultCommunicationSigningDeps(root, "node-a")); err == nil {
		t.Fatal("a provider credential changed the scope pin")
	}
	if _, err := communicationTrustScopePin(root, "node-a", CommunicationRequest{Operation: "route_trust_scope_pin",
		TrustPin: &communicationTrustPin{NodeID: "node-z", CertificateSHA256: "0000000000000000000000000000000000000000000000000000000000000000", SignsScopes: true, Approval: "approval-2"}},
		defaultCommunicationSigningDeps(root, "node-a")); err == nil {
		t.Fatal("an unknown host was pinned for scopes")
	}
	revoked, err := communicationTrustScopePin(root, "node-a", CommunicationRequest{Operation: "route_trust_scope_pin",
		TrustPin: &communicationTrustPin{NodeID: "node-a", CertificateSHA256: fingerprint, SignsScopes: false, Approval: "approval-3"}},
		defaultCommunicationSigningDeps(root, "node-a"))
	if err != nil || revoked["status"] != "revoked" {
		t.Fatal("revoke failed", revoked, err)
	}
	trusted, err := communicationTrustedNodes(root, defaultCommunicationSigningDeps(root, "node-a"), "node-a")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range trusted {
		if entry.CertificateSHA256 == fingerprint && entry.SignsScopes {
			t.Fatal("revoked pin still signs scopes")
		}
	}
	pinned, err := communicationTrustScopePin(root, "node-a", CommunicationRequest{Operation: "route_trust_scope_pin",
		TrustPin: &communicationTrustPin{NodeID: "node-a", CertificateSHA256: fingerprint, SignsScopes: true, Approval: "approval-4"}},
		defaultCommunicationSigningDeps(root, "node-a"))
	if err != nil || pinned["status"] != "pinned" {
		t.Fatal("pin failed", pinned, err)
	}
}

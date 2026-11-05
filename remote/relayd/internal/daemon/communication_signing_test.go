package daemon

import (
	"crypto/ed25519"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

const (
	signerNode    = "aaaaaaaaaaaaaaaa"
	receiverNode  = "bbbbbbbbbbbbbbbb"
	signedMessage = "7e1c2f0a-3b9d-4c58-8a61-1f4e3d2c7b90"
)

type memoryKeyStore struct {
	host     ed25519.PrivateKey
	cert     *x509.Certificate
	sessions map[string]ed25519.PrivateKey
	deleted  []string
}

func (m *memoryKeyStore) HostKey() (ed25519.PrivateKey, *x509.Certificate, error) {
	if m.host == nil {
		return nil, nil, errors.New("host signing identity unavailable")
	}
	return m.host, m.cert, nil
}
func (m *memoryKeyStore) SessionKey(id string) (ed25519.PrivateKey, error) {
	key, ok := m.sessions[id]
	if !ok {
		return nil, os.ErrNotExist
	}
	return key, nil
}
func (m *memoryKeyStore) PutSessionKey(id string, key ed25519.PrivateKey) error {
	m.sessions[id] = key
	return nil
}
func (m *memoryKeyStore) DeleteSessionKey(id string) error {
	delete(m.sessions, id)
	m.deleted = append(m.deleted, id)
	return nil
}

type signingHostFixture struct {
	root    string
	node    string
	keys    *memoryKeyStore
	pem     string
	member  communicationMember
	clock   time.Time
	sent    []map[string]any
	sendErr error
}

func newSigningHost(t *testing.T, node string) *signingHostFixture {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	identity, err := newPeerIdentity(node)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.X509KeyPair([]byte(identity.CertificatePEM), []byte(identity.PrivateKeyPEM))
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	return &signingHostFixture{root: root, node: node, pem: identity.CertificatePEM,
		keys:   &memoryKeyStore{host: pair.PrivateKey.(ed25519.PrivateKey), cert: cert, sessions: map[string]ed25519.PrivateKey{}},
		member: sourceFixture("codex_app_server_message"), clock: time.Now().UTC()}
}

func (h *signingHostFixture) deps() communicationSigningDeps {
	return communicationSigningDeps{keys: h.keys, now: func() time.Time { return h.clock },
		observe: func(pane string) communicationMember {
			if pane == sourceFixturePane {
				return h.member
			}
			if pane == targetFixturePane {
				return communicationMember{PaneID: pane, PID: 5151, Start: "target", Provider: "claude", SessionID: "target-session",
					Endpoint: map[string]any{"transport": "native_peer_socket", "socketPath": "/tmp/target.sock"}}
			}
			return communicationMember{PaneID: pane, Unavailable: "not observed"}
		},
		send: func(pane string, packet map[string]any) (map[string]any, error) {
			h.sent = append(h.sent, packet)
			if h.sendErr != nil {
				return nil, h.sendErr
			}
			return map[string]any{"status": "written_to_socket", "acknowledgement": "not_implied"}, nil
		}}
}

func (h *signingHostFixture) trusted() communicationTrustedNode {
	return communicationTrustedNode{NodeID: h.node, CertificatePEM: h.pem, CertificateSHA256: peerFingerprint(h.keys.cert)}
}

func (h *signingHostFixture) trust(t *testing.T, nodes ...communicationTrustedNode) {
	t.Helper()
	if _, err := communicationNodeTrustSet(h.root, h.node, CommunicationRequest{Operation: "node_trust_set", TrustedNodes: nodes}); err != nil {
		t.Fatal(err)
	}
}

func signRequest(text string) CommunicationRequest {
	return CommunicationRequest{Operation: "sign", SourcePaneID: sourceFixturePane, ActorPaneID: sourceFixturePane,
		PaneID: targetFixturePane, MessageID: signedMessage, Text: text, ClientID: "caller-a", actorVerified: true}
}

func deliverRequest(envelope, text string) CommunicationRequest {
	return CommunicationRequest{Operation: "deliver_signed", SourceSignature: envelope, SourcePaneID: sourceFixturePane,
		PaneID: targetFixturePane, MessageID: signedMessage, Text: text}
}

func (h *signingHostFixture) sign(t *testing.T, r CommunicationRequest) string {
	t.Helper()
	result, err := communicationSign(h.root, h.node, r, h.deps())
	if err != nil {
		t.Fatal(err)
	}
	return result["source_signature"].(string)
}

func signedPair(t *testing.T) (*signingHostFixture, *signingHostFixture) {
	t.Helper()
	signer, receiver := newSigningHost(t, signerNode), newSigningHost(t, receiverNode)
	receiver.trust(t, signer.trusted())
	return signer, receiver
}

func decodeEnvelope(t *testing.T, encoded string) communicationSignedEnvelope {
	t.Helper()
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	var envelope communicationSignedEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		t.Fatal(err)
	}
	return envelope
}

func encodeEnvelope(t *testing.T, envelope communicationSignedEnvelope) string {
	t.Helper()
	data, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(data)
}

// rewrite decodes one signed part, lets mutate change it, and re-encodes it
// without re-signing, as a broker would have to.
func rewrite[T any](t *testing.T, part string, mutate func(*T)) string {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(part)
	if err != nil {
		t.Fatal(err)
	}
	var value T
	if err := json.Unmarshal(raw, &value); err != nil {
		t.Fatal(err)
	}
	mutate(&value)
	raw, err = json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(raw)
}

func TestSignRequiresKernelVerifiedCaller(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	signer := newSigningHost(t, signerNode)
	for name, mutate := range map[string]func(*CommunicationRequest){
		"claimed source":        func(r *CommunicationRequest) { r.actorVerified = false },
		"no actor":              func(r *CommunicationRequest) { r.ActorPaneID = "" },
		"actor is another pane": func(r *CommunicationRequest) { r.ActorPaneID = targetFixturePane },
		"no target":             func(r *CommunicationRequest) { r.PaneID = "" },
		"to itself":             func(r *CommunicationRequest) { r.PaneID = sourceFixturePane },
		"empty text":            func(r *CommunicationRequest) { r.Text = "" },
	} {
		r := signRequest("hello")
		mutate(&r)
		if _, err := communicationSign(signer.root, signer.node, r, signer.deps()); err == nil {
			t.Errorf("%s: signed", name)
		}
	}
	// JSON can neither verify the actor nor supply observed sender fields.
	var decoded CommunicationRequest
	packet := `{"operation":"sign","actor_pane_id":"` + sourceFixturePane + `","source_pane_id":"` + sourceFixturePane +
		`","pane_id":"` + targetFixturePane + `","message_id":"` + signedMessage + `","text":"hello","actorVerified":true}`
	if err := json.Unmarshal([]byte(packet), &decoded); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationSign(signer.root, signer.node, decoded, signer.deps()); err == nil {
		t.Fatal("a JSON packet was signed")
	}
	signer.member.Provider = "shell"
	if _, err := communicationSign(signer.root, signer.node, signRequest("hello"), signer.deps()); err == nil {
		t.Fatal("signed for a non-agent provider")
	}
	if len(signer.keys.sessions) != 0 {
		t.Fatal("refused requests minted session keys")
	}
}

func TestSignRequiresHostIdentity(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	signer := newSigningHost(t, signerNode)
	signer.keys.host = nil
	if _, err := communicationSign(signer.root, signer.node, signRequest("hello"), signer.deps()); err == nil {
		t.Fatal("signed without a host identity")
	}
}

func TestSignedMessageDeliversOnlyVerifiedSender(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	signer, receiver := signedPair(t)
	envelope := signer.sign(t, signRequest("hello"))
	result, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(envelope, "hello"), receiver.deps())
	if err != nil {
		t.Fatal(err)
	}
	if result["source_authentication"] != "source_signed" || result["status"] != "written_to_socket" ||
		result["source_node_id"] != signerNode || result["submitting_client_id"] != "caller-a" {
		t.Fatalf("receipt = %v", result)
	}
	if len(receiver.sent) != 1 {
		t.Fatalf("%d deliveries", len(receiver.sent))
	}
	source := receiver.sent[0]["source"].(map[string]any)
	want := map[string]any{"authentication": "source_signed", "hostID": signerNode, "paneID": sourceFixturePane,
		"sessionID": "sender-thread", "provider": "codex", "permissionClass": "bypass",
		"nodeCertificateSHA256": peerFingerprint(signer.keys.cert)}
	for key, value := range want {
		if source[key] != value {
			t.Fatalf("source[%s] = %v, want %v (%v)", key, source[key], value, source)
		}
	}
	if !communicationHexID.MatchString(source["certID"].(string)) {
		t.Fatal("missing certificate identity", source)
	}
	if _, ok := source["socketPath"]; ok {
		t.Fatal("a signed source carried a host-local socket")
	}
	if receiver.sent[0]["text"] != "hello" || receiver.sent[0]["targetPaneID"] != targetFixturePane {
		t.Fatal("delivery packet changed", receiver.sent[0])
	}
}

func TestSignedUnknownModeStaysUnasserted(t *testing.T) {
	withSenderPermissionClass(t, "")
	signer, receiver := signedPair(t)
	envelope := signer.sign(t, signRequest("hello"))
	if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(envelope, "hello"), receiver.deps()); err != nil {
		t.Fatal(err)
	}
	if _, ok := receiver.sent[0]["source"].(map[string]any)["permissionClass"]; ok {
		t.Fatal("an unknown mode was asserted")
	}
}

func TestDeliverSignedRejectsMismatchedDelivery(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	signer, receiver := signedPair(t)
	envelope := signer.sign(t, signRequest("hello"))
	for name, mutate := range map[string]func(*CommunicationRequest){
		"other text":       func(r *CommunicationRequest) { r.Text = "hello!" },
		"other target":     func(r *CommunicationRequest) { r.PaneID = "aaaaaaaa-6e69-4d1a-9c83-91a0a2dec1e9" },
		"other message":    func(r *CommunicationRequest) { r.MessageID = "6e7c1f0e-2b8a-4c39-9e61-0a4f3d2b7c18" },
		"claimed source":   func(r *CommunicationRequest) { r.SourcePaneID = "bbbbbbbb-6e69-4d1a-9c83-91a0a2dec1e9" },
		"no envelope":      func(r *CommunicationRequest) { r.SourceSignature = "" },
		"garbage envelope": func(r *CommunicationRequest) { r.SourceSignature = "not-base64!" },
		"provider token":   func(r *CommunicationRequest) { r.ClientToken = "provider-token" },
		"provider actor":   func(r *CommunicationRequest) { r.ActorPaneID = targetFixturePane },
	} {
		r := deliverRequest(envelope, "hello")
		mutate(&r)
		if _, err := communicationDeliverSigned(receiver.root, receiver.node, r, receiver.deps()); err == nil {
			t.Errorf("%s: delivered", name)
		}
	}
	if len(receiver.sent) != 0 {
		t.Fatalf("refused deliveries reached the provider: %v", receiver.sent)
	}
}

func TestDeliverSignedRejectsTamperedEnvelope(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	signer, receiver := signedPair(t)
	envelope := signer.sign(t, signRequest("hello"))
	impostor := newSigningHost(t, "cccccccccccccccc")
	for name, mutate := range map[string]func(*communicationSignedEnvelope){
		"statement source pane": func(e *communicationSignedEnvelope) {
			e.Statement = rewrite(t, e.Statement, func(s *communicationSignedStatement) { s.SourcePaneID = "bbbbbbbb-6e69-4d1a-9c83-91a0a2dec1e9" })
		},
		"statement permission": func(e *communicationSignedEnvelope) {
			e.Statement = rewrite(t, e.Statement, func(s *communicationSignedStatement) { s.PermissionClass = "prompting" })
		},
		"statement expiry": func(e *communicationSignedEnvelope) {
			e.Statement = rewrite(t, e.Statement, func(s *communicationSignedStatement) { s.ExpiresAt = s.ExpiresAt.Add(time.Hour) })
		},
		"certificate pane": func(e *communicationSignedEnvelope) {
			e.Certificate = rewrite(t, e.Certificate, func(c *communicationSessionCert) { c.PaneID = "bbbbbbbb-6e69-4d1a-9c83-91a0a2dec1e9" })
		},
		"certificate provider": func(e *communicationSignedEnvelope) {
			e.Certificate = rewrite(t, e.Certificate, func(c *communicationSessionCert) { c.Provider = "claude" })
		},
		"certificate key swapped": func(e *communicationSignedEnvelope) {
			e.Certificate = rewrite(t, e.Certificate, func(c *communicationSessionCert) {
				public, _, _ := ed25519.GenerateKey(nil)
				c.SessionPublicKey = base64.StdEncoding.EncodeToString(public)
			})
		},
		"signature swapped": func(e *communicationSignedEnvelope) { e.Signature = e.CertificateSignature },
		"unpinned host":     func(e *communicationSignedEnvelope) { e.NodeCertificatePEM = impostor.pem },
		"malformed host pem": func(e *communicationSignedEnvelope) {
			e.NodeCertificatePEM = strings.Replace(e.NodeCertificatePEM, "CERTIFICATE", "PUBLIC KEY", 2)
		},
	} {
		tampered := decodeEnvelope(t, envelope)
		mutate(&tampered)
		if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(encodeEnvelope(t, tampered), "hello"), receiver.deps()); err == nil {
			t.Errorf("%s: delivered", name)
		}
	}
	// Unknown fields are refused rather than ignored.
	raw, _ := base64.RawURLEncoding.DecodeString(envelope)
	var loose map[string]any
	_ = json.Unmarshal(raw, &loose)
	loose["authentication"] = "kernel_verified"
	data, _ := json.Marshal(loose)
	if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(base64.RawURLEncoding.EncodeToString(data), "hello"), receiver.deps()); err == nil {
		t.Error("an envelope with an injected authentication field was delivered")
	}
	if len(receiver.sent) != 0 {
		t.Fatalf("tampered envelopes reached the provider: %v", receiver.sent)
	}
}

func TestDeliverSignedRejectsHostsNotPinnedForThatNode(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	signer := newSigningHost(t, signerNode)
	receiver := newSigningHost(t, receiverNode)
	envelope := signer.sign(t, signRequest("hello"))
	// No trust set at all.
	if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(envelope, "hello"), receiver.deps()); err == nil {
		t.Fatal("delivered from an unpinned host")
	}
	// A host that signs its certificates as another pinned node's ID.
	impostor := newSigningHost(t, "cccccccccccccccc")
	receiver.trust(t, impostor.trusted())
	// The impostor's own key validly signs a certificate naming signerNode.
	result, err := communicationSign(impostor.root, signerNode, signRequest("hello"), impostor.deps())
	if err != nil {
		t.Fatal(err)
	}
	forged := result["source_signature"].(string)
	if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(forged, "hello"), receiver.deps()); err == nil {
		t.Fatal("a pinned host impersonated another node")
	}
	if len(receiver.sent) != 0 {
		t.Fatal("refused deliveries reached the provider")
	}
}

func TestDeliverSignedRejectsExpiredStatementAndCertificate(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	signer, receiver := signedPair(t)
	envelope := signer.sign(t, signRequest("hello"))
	receiver.clock = signer.clock.Add(communicationStatementTTL)
	if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(envelope, "hello"), receiver.deps()); err == nil {
		t.Fatal("an expired statement was delivered")
	}
	receiver.clock = signer.clock.Add(-communicationClockSkew - time.Minute)
	if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(envelope, "hello"), receiver.deps()); err == nil {
		t.Fatal("a statement from the future was delivered")
	}
	// A certificate past its lifetime fails even with a fresh statement.
	signer.clock = signer.clock.Add(communicationSessionCertTTL - communicationSessionRenew - time.Minute)
	late := signer.sign(t, signRequest("hello"))
	receiver.clock = signer.clock.Add(communicationSessionRenew + 2*time.Minute)
	if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(late, "hello"), receiver.deps()); err == nil {
		t.Fatal("a statement under an expired session certificate was delivered")
	}
	if len(receiver.sent) != 0 {
		t.Fatal("expired messages reached the provider")
	}
}

func TestDeliverSignedReplayDeliversOnce(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	signer, receiver := signedPair(t)
	envelope := signer.sign(t, signRequest("hello"))
	first, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(envelope, "hello"), receiver.deps())
	if err != nil {
		t.Fatal(err)
	}
	again, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(envelope, "hello"), receiver.deps())
	if err != nil || again["status"] != first["status"] {
		t.Fatalf("retry: %v %v", again, err)
	}
	// The same message ID re-signed for other text is refused, not re-delivered.
	other := signer.sign(t, signRequest("different"))
	if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(other, "different"), receiver.deps()); err == nil ||
		!strings.Contains(err.Error(), "conflicts") {
		t.Fatalf("conflicting reuse: %v", err)
	}
	if len(receiver.sent) != 1 {
		t.Fatalf("%d deliveries for one message", len(receiver.sent))
	}
}

func TestSessionCertificateFollowsIncarnation(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	signer, receiver := signedPair(t)
	certOf := func(envelope string) string {
		return decodeEnvelopeCertID(t, envelope)
	}
	first := certOf(signer.sign(t, signRequest("hello")))
	if again := certOf(signer.sign(t, signRequest("hello"))); again != first {
		t.Fatal("the same session minted a second certificate")
	}
	signer.member.PID, signer.member.Start = 4343, "restarted"
	stale := signer.sign(t, signRequest("hello"))
	rotated := certOf(stale)
	if rotated == first {
		t.Fatal("a replaced process kept its certificate")
	}
	if _, ok := signer.keys.sessions[first]; ok || len(signer.keys.deleted) == 0 || signer.keys.deleted[0] != first {
		t.Fatal("the replaced session key was not deleted")
	}
	signer.member.SessionID = "next-thread"
	if certOf(signer.sign(t, signRequest("hello"))) == rotated {
		t.Fatal("a new conversation kept its certificate")
	}
	// The receiver still verifies the earlier, already-signed message on its
	// own; it carries the session that signed it, not the current one.
	if _, err := communicationDeliverSigned(receiver.root, receiver.node, deliverRequest(stale, "hello"), receiver.deps()); err != nil {
		t.Fatal(err)
	}
	if receiver.sent[0]["source"].(map[string]any)["sessionID"] != "sender-thread" {
		t.Fatal("delivered under the wrong session")
	}
}

func decodeEnvelopeCertID(t *testing.T, encoded string) string {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(decodeEnvelope(t, encoded).Certificate)
	if err != nil {
		t.Fatal(err)
	}
	var cert communicationSessionCert
	if err := json.Unmarshal(raw, &cert); err != nil {
		t.Fatal(err)
	}
	return cert.CertID
}

func TestNodeTrustSetIsOwnerOnlyAndPinsExactCertificates(t *testing.T) {
	signer, receiver := newSigningHost(t, signerNode), newSigningHost(t, receiverNode)
	good := signer.trusted()
	for name, mutate := range map[string]func(*CommunicationRequest){
		"provider token":       func(r *CommunicationRequest) { r.ClientToken = "provider-token" },
		"provider actor":       func(r *CommunicationRequest) { r.ActorPaneID = sourceFixturePane },
		"wrong fingerprint":    func(r *CommunicationRequest) { r.TrustedNodes[0].CertificateSHA256 = strings.Repeat("0", 64) },
		"certificate for node": func(r *CommunicationRequest) { r.TrustedNodes[0].NodeID = "cccccccccccccccc" },
		"own node":             func(r *CommunicationRequest) { r.TrustedNodes[0].NodeID = receiverNode },
		"duplicate":            func(r *CommunicationRequest) { r.TrustedNodes = append(r.TrustedNodes, r.TrustedNodes[0]) },
	} {
		r := CommunicationRequest{Operation: "node_trust_set", TrustedNodes: []communicationTrustedNode{good}}
		mutate(&r)
		if _, err := communicationNodeTrustSet(receiver.root, receiver.node, r); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := os.Stat(communicationTrustPath(receiver.root)); !os.IsNotExist(err) {
		t.Fatal("a refused trust set was saved")
	}
	if _, err := communicationNodeIdentity(receiver.root, receiver.node, CommunicationRequest{ClientToken: "provider-token"}); err == nil {
		t.Fatal("a provider created the host identity")
	}
}

package daemon

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Signed pane messages let the receiving host check, by itself, which pane and
// session sent a message. The sender's relayd signs only for its own
// kernel-verified caller, with a key certified by this host's peer identity.
// Every broker in between (desktop, bridge, transport) carries opaque bytes.
//
// Not covered: a process running as the same user on the sending host can read
// key files. The keyStore interface lets those keys move to Keychain or the
// supervisor's memory without changing this protocol.

const (
	communicationSessionCertTTL  = 24 * time.Hour
	communicationSessionRenew    = 30 * time.Minute
	communicationStatementTTL    = 10 * time.Minute
	communicationClockSkew       = 2 * time.Minute
	communicationEnvelopeLimit   = 16 << 10
	communicationTrustedNodeCap  = 64
	communicationCertDomain      = "relay-session-cert-v1\x00"
	communicationStatementDomain = "relay-pane-message-v1\x00"
)

var communicationHexID = regexp.MustCompile(`^[0-9a-f]{32}$`)

// communicationKeyStore holds this host's signing material.
type communicationKeyStore interface {
	HostKey() (ed25519.PrivateKey, *x509.Certificate, error)
	SessionKey(certID string) (ed25519.PrivateKey, error)
	PutSessionKey(certID string, key ed25519.PrivateKey) error
	DeleteSessionKey(certID string) error
}

// communicationFileKeyStore keeps keys as private files in the communication
// root: the host key is the existing peer identity, session keys sit beside it.
type communicationFileKeyStore struct{ root, node string }

func (s communicationFileKeyStore) HostKey() (ed25519.PrivateKey, *x509.Certificate, error) {
	_, pair, err := peerIdentity(s.root, s.node)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil, errors.New("host signing identity unavailable; create it with node_identity")
		}
		return nil, nil, err
	}
	key, ok := pair.PrivateKey.(ed25519.PrivateKey)
	if !ok || len(pair.Certificate) != 1 {
		return nil, nil, errors.New("host signing identity is not an Ed25519 key")
	}
	cert, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, nil, err
	}
	return key, cert, nil
}

type communicationSessionKeyFile struct {
	Version int    `json:"version"`
	CertID  string `json:"cert_id"`
	Seed    string `json:"seed"`
}

func (s communicationFileKeyStore) sessionKeyPath(certID string) string {
	return filepath.Join(s.root, "session-key-"+certID+".json")
}

func (s communicationFileKeyStore) SessionKey(certID string) (ed25519.PrivateKey, error) {
	if !communicationHexID.MatchString(certID) {
		return nil, errors.New("invalid session certificate identity")
	}
	var record communicationSessionKeyFile
	if err := communicationRead(s.sessionKeyPath(certID), &record); err != nil {
		return nil, err
	}
	seed, err := base64.StdEncoding.DecodeString(record.Seed)
	if err != nil || record.Version != 1 || record.CertID != certID || len(seed) != ed25519.SeedSize {
		return nil, errors.New("invalid session key record")
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

func (s communicationFileKeyStore) PutSessionKey(certID string, key ed25519.PrivateKey) error {
	if !communicationHexID.MatchString(certID) || len(key) != ed25519.PrivateKeySize {
		return errors.New("invalid session key")
	}
	return communicationAtomic(s.sessionKeyPath(certID), communicationSessionKeyFile{Version: 1, CertID: certID,
		Seed: base64.StdEncoding.EncodeToString(key.Seed())})
}

func (s communicationFileKeyStore) DeleteSessionKey(certID string) error {
	if !communicationHexID.MatchString(certID) {
		return errors.New("invalid session certificate identity")
	}
	if err := os.Remove(s.sessionKeyPath(certID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// communicationSessionCert binds a session key to one observed incarnation.
type communicationSessionCert struct {
	Version          int       `json:"v"`
	Purpose          string    `json:"purpose"`
	CertID           string    `json:"cert_id"`
	NodeID           string    `json:"node_id"`
	PaneID           string    `json:"pane_id"`
	Provider         string    `json:"provider"`
	SessionID        string    `json:"session_id"`
	PID              int       `json:"pid"`
	Start            string    `json:"start"`
	SessionPublicKey string    `json:"session_public_key"`
	NodeCertSHA256   string    `json:"node_cert_sha256"`
	IssuedAt         time.Time `json:"issued_at"`
	ExpiresAt        time.Time `json:"expires_at"`
}

// communicationSignedStatement is the exact message the session key signs.
type communicationSignedStatement struct {
	Version         int       `json:"v"`
	Purpose         string    `json:"purpose"`
	MessageID       string    `json:"message_id"`
	SourceNodeID    string    `json:"source_node_id"`
	SourcePaneID    string    `json:"source_pane_id"`
	SourceSessionID string    `json:"source_session_id"`
	CertID          string    `json:"cert_id"`
	PermissionClass string    `json:"permission_class,omitempty"`
	TargetPaneID    string    `json:"target_pane_id"`
	TextSHA256      string    `json:"text_sha256"`
	ClientID        string    `json:"client_id,omitempty"`
	CreatedAt       time.Time `json:"created_at"`
	ExpiresAt       time.Time `json:"expires_at"`
}

// The signed bytes travel base64-encoded, so brokers may re-serialize the
// envelope without changing what was signed.
type communicationSignedEnvelope struct {
	Version              int    `json:"v"`
	Statement            string `json:"statement"`
	Signature            string `json:"signature"`
	Certificate          string `json:"certificate"`
	CertificateSignature string `json:"certificate_signature"`
	NodeCertificatePEM   string `json:"node_certificate_pem"`
}

// communicationSessionRecord remembers the current certificate for a pane.
type communicationSessionRecord struct {
	Version              int    `json:"version"`
	Certificate          string `json:"certificate"`
	CertificateSignature string `json:"certificate_signature"`
}

type communicationTrustedNode struct {
	NodeID            string `json:"node_id"`
	CertificatePEM    string `json:"certificate_pem"`
	CertificateSHA256 string `json:"certificate_sha256"`
	SignsMessages     bool   `json:"signs_messages,omitempty"`
}

type communicationTrustSet struct {
	Version int                        `json:"version"`
	Nodes   []communicationTrustedNode `json:"nodes"`
}

type communicationSigningDeps struct {
	keys    communicationKeyStore
	observe func(string) communicationMember
	send    func(string, map[string]any) (map[string]any, error)
	now     func() time.Time
}

func defaultCommunicationSigningDeps(root, node string) communicationSigningDeps {
	return communicationSigningDeps{keys: communicationFileKeyStore{root: root, node: node},
		observe: communicationObserve, send: communicationNative, now: time.Now}
}

func communicationStrictJSON(data []byte, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	if decoder.More() {
		return errors.New("trailing data")
	}
	return nil
}

func communicationSessionRecordPath(root, pane string) string {
	return filepath.Join(root, "session-cert-"+pane+".json")
}

// communicationSessionCertificate returns a valid certificate and key for the
// observed incarnation, replacing any certificate for an earlier one.
func communicationSessionCertificate(root, node string, source communicationMember, d communicationSigningDeps) (communicationSessionRecord, communicationSessionCert, ed25519.PrivateKey, error) {
	var empty communicationSessionRecord
	hostKey, hostCert, err := d.keys.HostKey()
	if err != nil {
		return empty, communicationSessionCert{}, nil, err
	}
	now := d.now().UTC()
	fingerprint := peerFingerprint(hostCert)
	path := communicationSessionRecordPath(root, source.PaneID)
	var record communicationSessionRecord
	if err := communicationRead(path, &record); err == nil {
		raw, decodeErr := base64.StdEncoding.DecodeString(record.Certificate)
		var cert communicationSessionCert
		if decodeErr == nil && communicationStrictJSON(raw, &cert) == nil {
			current := cert.NodeID == node && cert.PaneID == source.PaneID && cert.Provider == source.Provider &&
				cert.SessionID == source.SessionID && cert.PID == source.PID && cert.Start == source.Start &&
				cert.NodeCertSHA256 == fingerprint && now.Add(communicationSessionRenew).Before(cert.ExpiresAt)
			if current {
				if key, keyErr := d.keys.SessionKey(cert.CertID); keyErr == nil {
					return record, cert, key, nil
				}
			}
			if communicationHexID.MatchString(cert.CertID) {
				if err := d.keys.DeleteSessionKey(cert.CertID); err != nil {
					return empty, communicationSessionCert{}, nil, err
				}
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return empty, communicationSessionCert{}, nil, err
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return empty, communicationSessionCert{}, nil, err
	}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return empty, communicationSessionCert{}, nil, err
	}
	expires := now.Add(communicationSessionCertTTL)
	if hostCert.NotAfter.Before(expires) {
		expires = hostCert.NotAfter
	}
	if !now.Before(expires) {
		return empty, communicationSessionCert{}, nil, errors.New("host signing identity expired; rotate it")
	}
	cert := communicationSessionCert{Version: 1, Purpose: "relay-session-cert", CertID: hex.EncodeToString(id), NodeID: node,
		PaneID: source.PaneID, Provider: source.Provider, SessionID: source.SessionID, PID: source.PID, Start: source.Start,
		SessionPublicKey: base64.StdEncoding.EncodeToString(public), NodeCertSHA256: fingerprint, IssuedAt: now, ExpiresAt: expires}
	raw, err := json.Marshal(cert)
	if err != nil {
		return empty, communicationSessionCert{}, nil, err
	}
	if err := d.keys.PutSessionKey(cert.CertID, private); err != nil {
		return empty, communicationSessionCert{}, nil, err
	}
	record = communicationSessionRecord{Version: 1, Certificate: base64.StdEncoding.EncodeToString(raw),
		CertificateSignature: base64.StdEncoding.EncodeToString(ed25519.Sign(hostKey, append([]byte(communicationCertDomain), raw...)))}
	if err := communicationAtomic(path, record); err != nil {
		_ = d.keys.DeleteSessionKey(cert.CertID)
		return empty, communicationSessionCert{}, nil, err
	}
	return record, cert, private, nil
}

// communicationSign is called only while holding the communication lock, after
// ReconcileCommunicationActor and communicationAuthorize.
func communicationSign(root, node string, r CommunicationRequest, d communicationSigningDeps) (map[string]any, error) {
	if !communicationSourceVerified(r) {
		return nil, errors.New("signing requires the kernel-verified caller pane")
	}
	if !validSessionID.MatchString(r.PaneID) || r.PaneID == r.SourcePaneID || !validSessionID.MatchString(r.MessageID) {
		return nil, errors.New("exact target pane and message identity required")
	}
	if r.Text == "" || len(r.Text) > 16384 {
		return nil, errors.New("invalid collaborator message")
	}
	// Every sender field comes from this host's observation, never the request.
	source := d.observe(r.SourcePaneID)
	if source.Endpoint == nil || source.Unavailable != "" || source.PID <= 1 || source.Start == "" ||
		source.SessionID == "" || (source.Provider != "claude" && source.Provider != "codex") {
		return nil, errors.New("the sending pane has no verified native session")
	}
	source.PaneID = r.SourcePaneID
	record, cert, key, err := communicationSessionCertificate(root, node, source, d)
	if err != nil {
		return nil, err
	}
	_, hostCert, err := d.keys.HostKey()
	if err != nil {
		return nil, err
	}
	now := d.now().UTC()
	statement := communicationSignedStatement{Version: 1, Purpose: "relay-pane-message", MessageID: r.MessageID,
		SourceNodeID: node, SourcePaneID: r.SourcePaneID, SourceSessionID: source.SessionID, CertID: cert.CertID,
		PermissionClass: communicationAttestLiveMode(source), TargetPaneID: r.PaneID,
		TextSHA256: communicationTextDigest(r.Text), ClientID: r.ClientID, CreatedAt: now, ExpiresAt: now.Add(communicationStatementTTL)}
	raw, err := json.Marshal(statement)
	if err != nil {
		return nil, err
	}
	envelope := communicationSignedEnvelope{Version: 1, Statement: base64.StdEncoding.EncodeToString(raw),
		Signature:   base64.StdEncoding.EncodeToString(ed25519.Sign(key, append([]byte(communicationStatementDomain), raw...))),
		Certificate: record.Certificate, CertificateSignature: record.CertificateSignature,
		NodeCertificatePEM: communicationCertificatePEM(hostCert)}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		return nil, err
	}
	if len(encoded) > communicationEnvelopeLimit {
		return nil, errors.New("signed envelope exceeds limit")
	}
	return map[string]any{"source_signature": base64.RawURLEncoding.EncodeToString(encoded), "cert_id": cert.CertID,
		"expires_at": statement.ExpiresAt, "authority": "relayd"}, nil
}

func communicationCertificatePEM(cert *x509.Certificate) string {
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Raw}))
}

// communicationVerifiedSource is what a receiver may rely on after verification.
type communicationVerifiedSource struct {
	Statement   communicationSignedStatement
	Certificate communicationSessionCert
	NodeCertSHA string
}

// communicationVerifyEnvelope checks the whole chain against this host's
// pinned nodes. It trusts nothing in the envelope that it did not verify.
func communicationVerifyEnvelope(encoded string, trusted []communicationTrustedNode, now time.Time) (communicationVerifiedSource, error) {
	var empty communicationVerifiedSource
	if encoded == "" || len(encoded) > communicationEnvelopeLimit*2 {
		return empty, errors.New("signed envelope required")
	}
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(data) > communicationEnvelopeLimit {
		return empty, errors.New("malformed signed envelope")
	}
	var envelope communicationSignedEnvelope
	if err := communicationStrictJSON(data, &envelope); err != nil || envelope.Version != 1 {
		return empty, errors.New("malformed signed envelope")
	}
	// 1. The host certificate must be one this receiver pinned.
	block, rest := pem.Decode([]byte(envelope.NodeCertificatePEM))
	if block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 {
		return empty, errors.New("signed envelope host certificate malformed")
	}
	hostCert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return empty, errors.New("signed envelope host certificate malformed")
	}
	fingerprint := peerFingerprint(hostCert)
	var pinned *communicationTrustedNode
	for i := range trusted {
		if trusted[i].CertificateSHA256 == fingerprint {
			pinned = &trusted[i]
			break
		}
	}
	if pinned == nil {
		return empty, errors.New("signing host is not trusted on this host")
	}
	hostPublic, ok := hostCert.PublicKey.(ed25519.PublicKey)
	if !ok {
		return empty, errors.New("signing host key is not Ed25519")
	}
	// 2. The session certificate must be signed by that host and still valid.
	certRaw, err := base64.StdEncoding.DecodeString(envelope.Certificate)
	certSignature, sigErr := base64.StdEncoding.DecodeString(envelope.CertificateSignature)
	if err != nil || sigErr != nil || !ed25519.Verify(hostPublic, append([]byte(communicationCertDomain), certRaw...), certSignature) {
		return empty, errors.New("session certificate signature invalid")
	}
	var cert communicationSessionCert
	if err := communicationStrictJSON(certRaw, &cert); err != nil || cert.Version != 1 || cert.Purpose != "relay-session-cert" {
		return empty, errors.New("session certificate malformed")
	}
	if cert.NodeID != pinned.NodeID || cert.NodeCertSHA256 != fingerprint || !communicationHexID.MatchString(cert.CertID) {
		return empty, errors.New("session certificate does not belong to the signing host")
	}
	if now.Add(communicationClockSkew).Before(cert.IssuedAt) || !now.Before(cert.ExpiresAt) ||
		cert.IssuedAt.Before(hostCert.NotBefore) || cert.ExpiresAt.After(hostCert.NotAfter) {
		return empty, errors.New("session certificate expired or outside host validity")
	}
	sessionPublic, err := base64.StdEncoding.DecodeString(cert.SessionPublicKey)
	if err != nil || len(sessionPublic) != ed25519.PublicKeySize {
		return empty, errors.New("session certificate key malformed")
	}
	// 3. The statement must be signed by that session key.
	statementRaw, err := base64.StdEncoding.DecodeString(envelope.Statement)
	signature, sigErr := base64.StdEncoding.DecodeString(envelope.Signature)
	if err != nil || sigErr != nil ||
		!ed25519.Verify(ed25519.PublicKey(sessionPublic), append([]byte(communicationStatementDomain), statementRaw...), signature) {
		return empty, errors.New("message signature invalid")
	}
	var statement communicationSignedStatement
	if err := communicationStrictJSON(statementRaw, &statement); err != nil || statement.Version != 1 || statement.Purpose != "relay-pane-message" {
		return empty, errors.New("signed statement malformed")
	}
	// 4. The statement's source must be exactly the certified session.
	if statement.SourceNodeID != cert.NodeID || statement.SourcePaneID != cert.PaneID ||
		statement.SourceSessionID != cert.SessionID || statement.CertID != cert.CertID {
		return empty, errors.New("signed statement does not match its session certificate")
	}
	if now.Add(communicationClockSkew).Before(statement.CreatedAt) || !now.Before(statement.ExpiresAt) ||
		statement.ExpiresAt.Sub(statement.CreatedAt) > communicationStatementTTL {
		return empty, errors.New("signed statement expired")
	}
	if statement.PermissionClass != "" && statement.PermissionClass != "bypass" && statement.PermissionClass != "prompting" {
		return empty, errors.New("signed statement permission class invalid")
	}
	return communicationVerifiedSource{Statement: statement, Certificate: cert, NodeCertSHA: fingerprint}, nil
}

func communicationTrustPath(root string) string { return filepath.Join(root, "trusted-nodes.json") }

// communicationTrustedNodes is the pinned set plus this host's own identity.
func communicationTrustedNodes(root string, d communicationSigningDeps, node string) ([]communicationTrustedNode, error) {
	var set communicationTrustSet
	if err := communicationRead(communicationTrustPath(root), &set); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	nodes := append([]communicationTrustedNode{}, set.Nodes...)
	if _, cert, err := d.keys.HostKey(); err == nil {
		nodes = append(nodes, communicationTrustedNode{NodeID: node, CertificateSHA256: peerFingerprint(cert), SignsMessages: true})
	}
	return nodes, nil
}

// communicationDeliverSigned is owner administration over the host transport.
// It delivers a message only as far as its signature proves the sender.
func communicationDeliverSigned(root, node string, r CommunicationRequest, d communicationSigningDeps) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	if !validSessionID.MatchString(r.PaneID) || !validSessionID.MatchString(r.MessageID) ||
		len(r.Text) == 0 || len(r.Text) > 16384 || strings.TrimSpace(r.Text) == "" {
		return nil, errors.New("a target pane, message UUID and 1-16384 bytes of text are required")
	}
	trusted, err := communicationTrustedNodes(root, d, node)
	if err != nil {
		return nil, err
	}
	verified, err := communicationVerifyEnvelope(r.SourceSignature, trusted, d.now().UTC())
	if err != nil {
		return nil, err
	}
	statement := verified.Statement
	// 5. The statement must describe exactly this delivery.
	if statement.TargetPaneID != r.PaneID || statement.MessageID != r.MessageID ||
		statement.TextSHA256 != communicationTextDigest(r.Text) ||
		(r.SourcePaneID != "" && r.SourcePaneID != statement.SourcePaneID) {
		return nil, errors.New("signed statement does not match this delivery")
	}
	identity, _ := json.Marshal(struct{ Host, Source, Target, Message, Text string }{
		verified.NodeCertSHA, statement.SourcePaneID, statement.TargetPaneID, statement.MessageID, communicationTextDigest(r.Text)})
	sum := sha256.Sum256(identity)
	fingerprint := hex.EncodeToString(sum[:])
	key := sha256.Sum256([]byte(verified.NodeCertSHA + "\n" + statement.MessageID))
	receiptPath := filepath.Join(root, "signed-message-"+hex.EncodeToString(key[:])+".json")
	var receipt communicationReceipt
	if err := communicationRead(receiptPath, &receipt); err == nil {
		if receipt.Fingerprint != fingerprint {
			return nil, errors.New("message identity conflicts with a previous request")
		}
		return receipt.Result, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	target := d.observe(r.PaneID)
	if target.Endpoint == nil || target.Unavailable != "" {
		return nil, communicationUnverifiedEndpoint("the target pane has no verified native communication endpoint", communicationMember{}, target)
	}
	source := communicationSignedSourcePacket(verified)
	receipt = communicationReceipt{Version: 1, Fingerprint: fingerprint, CreatedAt: d.now().UTC(), Result: map[string]any{
		"message_id": statement.MessageID, "source_pane_id": statement.SourcePaneID, "pane_id": statement.TargetPaneID,
		"status": "outcome_unknown", "replay_permitted": false, "source_authentication": "source_signed",
		"source_node_id": statement.SourceNodeID, "source_cert_id": statement.CertID,
		"source_node_certificate_sha256": verified.NodeCertSHA, "submitting_client_id": statement.ClientID,
		"authority": "relayd", "desktop_required": false}}
	// Persist the claim before the only native delivery.
	if err := communicationAtomic(receiptPath, receipt); err != nil {
		return nil, err
	}
	packet := map[string]any{"operation": "send", "expected": target.Endpoint, "messageID": statement.MessageID,
		"targetPaneID": statement.TargetPaneID, "text": r.Text, "submittingClientID": statement.ClientID, "source": source}
	if statement.ClientID == "" {
		packet["submittingClientID"] = "legacy-unattributed"
	}
	result, err := d.send(r.PaneID, packet)
	for k, v := range communicationNativeOutcome(result, err) {
		receipt.Result[k] = v
	}
	if err := communicationAtomic(receiptPath, receipt); err != nil {
		return nil, err
	}
	return receipt.Result, nil
}

// communicationSignedSourcePacket is the sender packet for a verified signed
// statement, built from verified fields only: nothing a broker or peer sent can
// add or change an authentication claim or the permission class.
func communicationSignedSourcePacket(verified communicationVerifiedSource) map[string]any {
	statement := verified.Statement
	source := map[string]any{"authentication": "source_signed", "hostID": statement.SourceNodeID,
		"paneID": statement.SourcePaneID, "sessionID": statement.SourceSessionID, "provider": verified.Certificate.Provider,
		"certID": statement.CertID, "nodeCertificateSHA256": verified.NodeCertSHA}
	if statement.PermissionClass != "" {
		source["permissionClass"] = statement.PermissionClass
	}
	return source
}

// communicationNodeIdentity is owner administration: it returns this host's
// public signing certificate, creating the peer identity if none exists.
func communicationNodeIdentity(root, node string, r CommunicationRequest) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	return communicationPeerConfiguration(root, node, CommunicationRequest{Operation: "route_identity_create"})
}

// communicationNodeTrustSet is owner administration: it replaces the set of
// other hosts whose signed messages this host accepts.
func communicationNodeTrustSet(root, node string, r CommunicationRequest) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	if len(r.TrustedNodes) > communicationTrustedNodeCap {
		return nil, errors.New("trusted host limit exceeded")
	}
	set := communicationTrustSet{Version: 1, Nodes: []communicationTrustedNode{}}
	seen := map[string]bool{}
	for _, entry := range r.TrustedNodes {
		entry.NodeID, entry.CertificateSHA256 = strings.ToLower(entry.NodeID), strings.ToLower(entry.CertificateSHA256)
		if !canonicalRouteToken(entry.NodeID) || entry.NodeID == node || seen[entry.CertificateSHA256] {
			return nil, errors.New("invalid or duplicate trusted host")
		}
		// Expired certificates stay acceptable as pins; session certificate
		// expiry and the pin itself bound what they can still authorize.
		cert, err := peerCertificateValidation(entry.CertificatePEM, entry.NodeID, false)
		if err != nil || peerFingerprint(cert) != entry.CertificateSHA256 {
			return nil, errors.New("trusted host certificate does not match its fingerprint")
		}
		seen[entry.CertificateSHA256] = true
		set.Nodes = append(set.Nodes, entry)
	}
	if err := communicationAtomic(communicationTrustPath(root), set); err != nil {
		return nil, err
	}
	if err := communicationEvent(root, node, "communication_trusted_hosts_set", nil); err != nil {
		return nil, errors.New("trusted hosts saved but event append failed; inspect before recovery")
	}
	return map[string]any{"trusted_hosts": len(set.Nodes), "authority": "relayd"}, nil
}

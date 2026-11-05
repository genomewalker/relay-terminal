package daemon

// A nonce-bound Work-source observation reuses the communication node's
// existing signing identity. This is not a continuous admission fence: it is
// deliberately not registered on the peer listener until transition barriers
// and receipt recovery are integrated.
import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"reflect"
	"strings"
	"time"
)

const communicationWorkObservationDomain = "relay-work-source-observation-v1\x00"
const communicationWorkObservationTTL = 10 * time.Second

type communicationWorkObservation struct {
	Version        int       `json:"version"`
	Purpose        string    `json:"purpose"`
	SourceNode     string    `json:"source_node"`
	TargetNode     string    `json:"target_node"`
	LinkID         string    `json:"link_id"`
	SourceRevision uint64    `json:"source_revision"`
	TargetRevision uint64    `json:"target_revision"`
	MessageID      string    `json:"message_id"`
	Fingerprint    string    `json:"fingerprint"`
	ProofSHA256    string    `json:"proof_sha256"`
	Nonce          string    `json:"nonce"`
	PID            int       `json:"pid"`
	Start          string    `json:"start"`
	IssuedAt       time.Time `json:"issued_at"`
	ExpiresAt      time.Time `json:"expires_at"`
}
type communicationWorkObservationEnvelope struct {
	Version     int    `json:"version"`
	Body        string `json:"body"`
	Signature   string `json:"signature"`
	Certificate string `json:"certificate"`
}

func communicationWorkProofDigest(proof string) string {
	x := sha256.Sum256([]byte(proof))
	return hex.EncodeToString(x[:])
}

func communicationCallerActive(root, id string) error {
	var policy communicationPolicy
	if err := communicationRead(communicationPolicyPath(root), &policy); err != nil {
		return err
	}
	if err := communicationValidatePolicy(policy); err != nil {
		return err
	}
	for _, c := range policy.Callers {
		if strings.EqualFold(c.ID, id) {
			if c.Paused {
				return errors.New("caller paused")
			}
			return nil
		}
	}
	return errors.New("registered caller unavailable")
}

// communicationAuthorizeTypedObservation must run under the communication
// metadata lock. peerCertificate comes from the authenticated TLS connection.
func communicationAuthorizeTypedObservation(ctx context.Context, root, node, peerCertificate string, m communicationTypedWorkMessage, d communicationSigningDeps) (communicationVerifiedSource, ed25519.PrivateKey, *x509.Certificate, error) {
	var empty communicationVerifiedSource
	if err := ctx.Err(); err != nil {
		return empty, nil, nil, err
	}
	link, err := communicationReadTypedActiveLink(ctx, root, node, m.LinkID)
	if err != nil {
		return empty, nil, nil, err
	}
	if link.Local.Kind != "pane" || link.Peer.Kind != "work" || link.PeerCertificateSHA256 != peerCertificate ||
		!communicationEndpointEqual(link.Local, m.Source) || !communicationEndpointEqual(link.Peer, m.Target) || link.Revision != m.SourceLinkRevision || link.PeerRevision != m.TargetLinkRevision {
		return empty, nil, nil, errors.New("reciprocal relationship changed")
	}
	if err := communicationCallerActive(root, m.CallerID); err != nil {
		return empty, nil, nil, err
	}
	var receipt communicationTypedOutboundReceipt
	if err := communicationRead(remoteOutboundPath(root, m.MessageID), &receipt); err != nil || receipt.Version != 2 || receipt.NodeID != node || receipt.LinkID != link.ID || receipt.MessageID != m.MessageID || receipt.Fingerprint != m.Fingerprint || receipt.RouteID != link.RouteID || receipt.RouteRevision != link.RouteRevision || receipt.PeerCertificateSHA256 != peerCertificate || receipt.Result == nil {
		return empty, nil, nil, errors.New("outbound claim unavailable")
	}
	key, hostCert, err := d.keys.HostKey()
	if err != nil || hostCert == nil {
		return empty, nil, nil, errors.New("source host identity unavailable")
	}
	trusted := []communicationTrustedNode{{NodeID: node, CertificateSHA256: peerFingerprint(hostCert)}}
	verified, err := communicationVerifyWorkMessage(m.SourceSignature, trusted, d.now().UTC(), m.Source.NodeID, m.Source.PaneID, m.Source.Provider, m.Source.SessionID, m.Target.NodeID, m.MessageID, m.LinkID, m.SourceLinkRevision, m.TargetLinkRevision, []byte(m.Text), *m.Target.Work)
	if err != nil || verified.Statement.ClientID != m.CallerID {
		return empty, nil, nil, errors.New("source proof changed")
	}
	return verified, key, hostCert, nil
}

// The saved reciprocal relationship and outbound claim are authenticated before
// observing a pane, and rechecked under the same lock before signing. Local
// process observations cannot prevent a subsequent source transition.
func communicationSignTypedWorkObservation(ctx context.Context, root, node, peerCertificate, nonce string, m communicationTypedWorkMessage, d communicationSigningDeps) (string, error) {
	if d.observe == nil || d.keys == nil || d.now == nil || !remoteDigest(nonce) || !remoteDigest(peerCertificate) || m.Fingerprint == "" || m.Fingerprint != communicationTypedWorkFingerprint(m) || m.Source.NodeID != node {
		return "", errors.New("invalid observation request")
	}
	if err := communicationFanoutLocked(root, func() error {
		_, _, _, err := communicationAuthorizeTypedObservation(ctx, root, node, peerCertificate, m, d)
		return err
	}); err != nil {
		return "", err
	}
	before := d.observe(m.Source.PaneID)
	var encoded string
	err := communicationFanoutLocked(root, func() error {
		verified, key, hostCert, err := communicationAuthorizeTypedObservation(ctx, root, node, peerCertificate, m, d)
		if err != nil {
			return err
		}
		if before.Endpoint == nil || before.Unavailable != "" || before.Provider != m.Source.Provider || before.SessionID != m.Source.SessionID || before.PID != verified.Certificate.PID || before.Start != verified.Certificate.Start {
			return errors.New("source observation changed")
		}
		now := d.now().UTC()
		expires := now.Add(communicationWorkObservationTTL)
		if verified.Statement.ExpiresAt.Before(expires) {
			expires = verified.Statement.ExpiresAt
		}
		if hostCert.NotAfter.Before(expires) {
			expires = hostCert.NotAfter
		}
		if !now.Before(expires) {
			return errors.New("source observation expired")
		}
		observation := communicationWorkObservation{Version: 1, Purpose: "relay-work-source-observation", SourceNode: node, TargetNode: m.Target.NodeID, LinkID: m.LinkID, SourceRevision: m.SourceLinkRevision, TargetRevision: m.TargetLinkRevision, MessageID: m.MessageID, Fingerprint: m.Fingerprint, ProofSHA256: communicationWorkProofDigest(m.SourceSignature), Nonce: nonce, PID: before.PID, Start: before.Start, IssuedAt: now, ExpiresAt: expires}
		raw, err := json.Marshal(observation)
		if err != nil {
			return err
		}
		envelope := communicationWorkObservationEnvelope{Version: 1, Body: base64.StdEncoding.EncodeToString(raw), Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(key, append([]byte(communicationWorkObservationDomain), raw...))), Certificate: communicationCertificatePEM(hostCert)}
		data, err := json.Marshal(envelope)
		if err != nil || len(data) > communicationEnvelopeLimit {
			return errors.New("source observation too large")
		}
		encoded = base64.RawURLEncoding.EncodeToString(data)
		return nil
	})
	if err != nil {
		return "", err
	}
	after := d.observe(m.Source.PaneID)
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if after.Endpoint == nil || after.Unavailable != "" || after.Provider != before.Provider || after.SessionID != before.SessionID || after.PID != before.PID || after.Start != before.Start || !reflect.DeepEqual(after.Endpoint, before.Endpoint) {
		return "", errors.New("source changed after observation")
	}
	return encoded, nil
}

func communicationVerifyTypedWorkObservation(encoded, nonce string, link communicationTypedRemoteLink, m communicationTypedWorkMessage, now time.Time) error {
	if !remoteDigest(nonce) || len(encoded) == 0 || len(encoded) > 2*communicationEnvelopeLimit {
		return errors.New("invalid source observation")
	}
	if err := communicationVerifyTypedWorkDelivery(link, link.Local.NodeID, link.PeerCertificateSHA256, m, now); err != nil {
		return err
	}
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return err
	}
	var envelope communicationWorkObservationEnvelope
	if communicationStrictWorkJSON(raw, &envelope) != nil || envelope.Version != 1 {
		return errors.New("invalid source observation")
	}
	block, rest := pem.Decode([]byte(envelope.Certificate))
	if block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 {
		return errors.New("invalid source certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil || peerFingerprint(cert) != link.PeerCertificateSHA256 || now.Before(cert.NotBefore) || !now.Before(cert.NotAfter) {
		return errors.New("untrusted source certificate")
	}
	pub, ok := cert.PublicKey.(ed25519.PublicKey)
	if !ok {
		return errors.New("invalid source key")
	}
	body, err := base64.StdEncoding.DecodeString(envelope.Body)
	if err != nil {
		return err
	}
	sig, err := base64.StdEncoding.DecodeString(envelope.Signature)
	if err != nil || !ed25519.Verify(pub, append([]byte(communicationWorkObservationDomain), body...), sig) {
		return errors.New("source observation signature invalid")
	}
	var o communicationWorkObservation
	if communicationStrictWorkJSON(body, &o) != nil || o.Version != 1 || o.Purpose != "relay-work-source-observation" ||
		o.SourceNode != m.Source.NodeID || o.TargetNode != m.Target.NodeID || o.LinkID != m.LinkID || o.SourceRevision != m.SourceLinkRevision || o.TargetRevision != m.TargetLinkRevision ||
		o.MessageID != m.MessageID || o.Fingerprint != m.Fingerprint || o.ProofSHA256 != communicationWorkProofDigest(m.SourceSignature) || o.Nonce != nonce ||
		o.PID <= 1 || o.Start == "" || now.Add(2*time.Second).Before(o.IssuedAt) || !now.Before(o.ExpiresAt) || !o.IssuedAt.Before(o.ExpiresAt) || o.ExpiresAt.Sub(o.IssuedAt) > communicationWorkObservationTTL || o.ExpiresAt.After(cert.NotAfter) {
		return errors.New("source observation mismatch or expired")
	}
	source, err := communicationVerifyWorkMessage(m.SourceSignature, []communicationTrustedNode{{NodeID: link.Peer.NodeID, CertificateSHA256: link.PeerCertificateSHA256}}, now, m.Source.NodeID, m.Source.PaneID, m.Source.Provider, m.Source.SessionID, m.Target.NodeID, m.MessageID, m.LinkID, m.SourceLinkRevision, m.TargetLinkRevision, []byte(m.Text), *m.Target.Work)
	if err != nil || source.Certificate.PID != o.PID || source.Certificate.Start != o.Start || o.ExpiresAt.After(source.Statement.ExpiresAt) {
		return errors.New("source observation incarnation changed")
	}
	return nil
}

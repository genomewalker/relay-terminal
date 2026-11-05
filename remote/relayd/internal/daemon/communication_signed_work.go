package daemon

// Work-target signatures use the existing session certificate and signing
// authority, with a distinct purpose and exact typed target. They do not grant
// a relationship: the receiver must separately verify its saved link.
import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"time"
	"unicode/utf8"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

// The caller holds the common communication lock while the shared session
// certificate and its key are reused or rotated.
func communicationSignWork(root, node string, r CommunicationRequest, targetNode, linkID string, sourceRevision, targetRevision uint64, target nativemsg.WorkEndpoint, d communicationSigningDeps) (string, error) {
	if !communicationSourceVerified(r) || !canonicalRouteToken(targetNode) || targetNode == node || !remoteDigest(linkID) || sourceRevision == 0 || targetRevision == 0 || !validSessionID.MatchString(r.MessageID) || r.Text == "" || len(r.Text) > 16384 || !utf8.ValidString(r.Text) {
		return "", errors.New("verified source and message required")
	}
	if !target.Valid() {
		return "", errors.New("invalid Work target")
	}
	source := d.observe(r.SourcePaneID)
	if source.Endpoint == nil || source.Unavailable != "" || source.PID <= 1 || source.Start == "" || source.SessionID == "" || (source.Provider != "claude" && source.Provider != "codex") {
		return "", errors.New("the sending pane has no verified native session")
	}
	source.PaneID = r.SourcePaneID
	record, cert, key, err := communicationSessionCertificate(root, node, source, d)
	if err != nil {
		return "", err
	}
	_, hostCert, err := d.keys.HostKey()
	if err != nil {
		return "", err
	}
	now := d.now().UTC()
	statement := communicationSignedStatement{Version: 1, Purpose: "relay-work-message", MessageID: r.MessageID,
		SourceNodeID: node, SourcePaneID: r.SourcePaneID, SourceSessionID: source.SessionID, CertID: cert.CertID,
		PermissionClass: communicationAttestLiveMode(source), TargetNodeID: targetNode, WorkLinkID: linkID, WorkSourceRevision: sourceRevision, WorkTargetRevision: targetRevision, WorkTarget: &target,
		TextSHA256: communicationTextDigest(r.Text), ClientID: r.ClientID, CreatedAt: now, ExpiresAt: now.Add(communicationStatementTTL)}
	raw, err := json.Marshal(statement)
	if err != nil {
		return "", err
	}
	envelope := communicationSignedEnvelope{Version: 1, Statement: base64.StdEncoding.EncodeToString(raw),
		Signature:   base64.StdEncoding.EncodeToString(ed25519.Sign(key, append([]byte(communicationWorkStatementDomain), raw...))),
		Certificate: record.Certificate, CertificateSignature: record.CertificateSignature, NodeCertificatePEM: communicationCertificatePEM(hostCert)}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		return "", err
	}
	if len(encoded) > communicationEnvelopeLimit {
		return "", errors.New("signed envelope exceeds limit")
	}
	return base64.RawURLEncoding.EncodeToString(encoded), nil
}

// communicationVerifyWorkMessage verifies the proof against a previously
// authorized relationship and the actual request bytes. Signature verification
// alone is never permission to deliver.
func communicationVerifyWorkMessage(encoded string, trusted []communicationTrustedNode, now time.Time, sourceNode, sourcePane, sourceProvider, sourceSession, targetNode, messageID, linkID string, sourceRevision, targetRevision uint64, text []byte, target nativemsg.WorkEndpoint) (communicationVerifiedSource, error) {
	var empty communicationVerifiedSource
	if !canonicalRouteToken(sourceNode) || !canonicalRouteToken(targetNode) || sourceNode == targetNode || !remoteDigest(linkID) || sourceRevision == 0 || targetRevision == 0 || !validSessionID.MatchString(sourcePane) || (sourceProvider != "codex" && sourceProvider != "claude") || !validSessionID.MatchString(sourceSession) || !validSessionID.MatchString(messageID) || len(text) == 0 || len(text) > 16384 || !utf8.Valid(text) {
		return empty, errors.New("invalid expected Work message")
	}
	verified, err := communicationVerifyWorkEnvelope(encoded, trusted, now)
	if err != nil {
		return empty, err
	}
	s := verified.Statement
	if s.SourceNodeID != sourceNode || s.TargetNodeID != targetNode || s.WorkLinkID != linkID || s.WorkSourceRevision != sourceRevision || s.WorkTargetRevision != targetRevision || s.SourcePaneID != sourcePane || verified.Certificate.Provider != sourceProvider || s.SourceSessionID != sourceSession || s.MessageID != messageID || s.TextSHA256 != communicationTextDigest(string(text)) || s.WorkTarget == nil || *s.WorkTarget != target {
		return empty, errors.New("signed Work message does not match authorized relationship")
	}
	return verified, nil
}

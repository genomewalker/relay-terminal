package daemon

import (
	"bytes"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// A collaboration scope is an owner-signed list of exact (node_id, pane_id)
// members. The owner key (the Relay app on the Mac) signs one record per holder
// host; each relayd verifies it against an owner certificate pinned in its trust
// set (trusted-nodes.json, entry with signs_scopes) and re-verifies the stored
// record on every use, so a modified file or an unpinned key grants nothing.
// Records stay valid until a higher-revision record (possibly with no members)
// replaces them. Panes are pinned by ID only; conversations are observed live.

const (
	communicationScopeDomain    = "relay-scope-v1\x00"
	communicationScopePurpose   = "relay-collaboration-scope"
	communicationScopeMemberCap = 128
	communicationScopeLimit     = 32 << 10
)

type communicationScopeMember struct {
	NodeID string `json:"node_id"`
	PaneID string `json:"pane_id"`
}

type communicationScopeBody struct {
	Version      int                        `json:"v"`
	Purpose      string                     `json:"purpose"`
	ScopeID      string                     `json:"scope_id"`
	HolderNodeID string                     `json:"holder_node_id"`
	OwnerNodeID  string                     `json:"owner_node_id"`
	Revision     uint64                     `json:"revision"`
	CreatedAt    time.Time                  `json:"created_at"`
	Members      []communicationScopeMember `json:"members"`
}

// Body is the base64 (standard) encoding of the exact JSON bytes that were
// signed; Signature is base64 Ed25519 over communicationScopeDomain+body bytes.
type communicationScopeRecord struct {
	Version             int    `json:"version"`
	Body                string `json:"body"`
	OwnerCertificatePEM string `json:"owner_certificate_pem"`
	Signature           string `json:"signature"`
}

func communicationScopePath(root string) string { return filepath.Join(root, "scope-record.json") }

func communicationScopeKey(m communicationScopeMember) string { return m.NodeID + ":" + m.PaneID }

// communicationVerifyScope checks the signature chain and that the record is
// addressed to this holder host. It trusts nothing it did not verify.
func communicationVerifyScope(rec communicationScopeRecord, trusted []communicationTrustedNode, node string) (communicationScopeBody, error) {
	var empty communicationScopeBody
	if rec.Version != 1 || rec.Body == "" || rec.Signature == "" || rec.OwnerCertificatePEM == "" || len(rec.Body) > communicationScopeLimit*2 {
		return empty, errors.New("signed scope record required")
	}
	block, rest := pem.Decode([]byte(rec.OwnerCertificatePEM))
	if block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 {
		return empty, errors.New("scope owner certificate malformed")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return empty, errors.New("scope owner certificate malformed")
	}
	fingerprint := peerFingerprint(cert)
	var pinned *communicationTrustedNode
	for i := range trusted {
		if trusted[i].CertificateSHA256 == fingerprint && trusted[i].SignsScopes {
			pinned = &trusted[i]
			break
		}
	}
	if pinned == nil {
		return empty, errors.New("scope owner is not pinned on this host")
	}
	public, ok := cert.PublicKey.(ed25519.PublicKey)
	if !ok {
		return empty, errors.New("scope owner key is not Ed25519")
	}
	raw, err := base64.StdEncoding.DecodeString(rec.Body)
	signature, sigErr := base64.StdEncoding.DecodeString(rec.Signature)
	if err != nil || sigErr != nil || len(raw) > communicationScopeLimit || len(signature) != ed25519.SignatureSize ||
		!ed25519.Verify(public, append([]byte(communicationScopeDomain), raw...), signature) {
		return empty, errors.New("scope signature invalid")
	}
	var body communicationScopeBody
	if err := communicationStrictJSON(raw, &body); err != nil || body.Version != 1 || body.Purpose != communicationScopePurpose {
		return empty, errors.New("scope record malformed")
	}
	if !canonicalRouteToken(body.ScopeID) || body.Revision == 0 || body.OwnerNodeID != pinned.NodeID || body.HolderNodeID != node || len(body.Members) > communicationScopeMemberCap {
		return empty, errors.New("scope record is not addressed to this host or owner")
	}
	previous, onHolder := "", false
	for _, member := range body.Members {
		key := communicationScopeKey(member)
		if !canonicalRouteToken(member.NodeID) || !canonicalRouteToken(member.PaneID) || key <= previous {
			return empty, errors.New("scope members must be exact, sorted and unique")
		}
		previous = key
		onHolder = onHolder || member.NodeID == node
	}
	if len(body.Members) != 0 && !onHolder {
		return empty, errors.New("scope record lists no member on this host")
	}
	return body, nil
}

// communicationScopeLoad returns the verified stored scope. A missing file is
// (zero, false, nil); a present file that no longer verifies is an error.
func communicationScopeLoad(root, node string) (communicationScopeBody, bool, error) {
	var rec communicationScopeRecord
	if err := communicationRead(communicationScopePath(root), &rec); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return communicationScopeBody{}, false, nil
		}
		return communicationScopeBody{}, false, err
	}
	trusted, err := communicationTrustedNodes(root, defaultCommunicationSigningDeps(root, node), node)
	if err != nil {
		return communicationScopeBody{}, false, err
	}
	body, err := communicationVerifyScope(rec, trusted, node)
	if err != nil {
		return communicationScopeBody{}, false, err
	}
	return body, true, nil
}

// communicationScopeAllows reports whether the exact pair is in the verified
// scope held by this host. Any failure to verify means not allowed.
func communicationScopeAllows(root, node, nodeA, paneA, nodeB, paneB string) (scopeID string, ok bool) {
	body, found, err := communicationScopeLoad(root, node)
	if err != nil || !found || nodeA == nodeB {
		return "", false
	}
	a, b := false, false
	for _, member := range body.Members {
		a = a || (member.NodeID == nodeA && member.PaneID == paneA)
		b = b || (member.NodeID == nodeB && member.PaneID == paneB)
	}
	return body.ScopeID, a && b
}

// communicationScopeSet is owner administration (reached only through the
// route_ operation gate, which rejects provider credentials and actor panes).
// Records are monotonic: a stale or equal revision never replaces a newer one.
func communicationScopeSet(root, node string, r CommunicationRequest) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	if r.Scope == nil {
		return nil, errors.New("signed scope record required")
	}
	trusted, err := communicationTrustedNodes(root, defaultCommunicationSigningDeps(root, node), node)
	if err != nil {
		return nil, err
	}
	body, err := communicationVerifyScope(*r.Scope, trusted, node)
	if err != nil {
		return nil, err
	}
	if current, found, err := communicationScopeLoad(root, node); err == nil && found &&
		(body.Revision <= current.Revision || body.ScopeID != current.ScopeID) {
		return nil, errors.New("scope revision conflict")
	}
	if err := communicationAtomic(communicationScopePath(root), *r.Scope); err != nil {
		return nil, err
	}
	if err := communicationEvent(root, node, "communication_scope_saved", []map[string]string{{"scope_id": body.ScopeID}}); err != nil {
		return nil, errors.New("scope saved but event append failed; read current revision before recovery")
	}
	return map[string]any{"scope_id": body.ScopeID, "revision": body.Revision, "members": len(body.Members), "authority": "relayd"}, nil
}

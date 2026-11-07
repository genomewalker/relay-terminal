package daemon

import (
	"errors"
	"os"
	"strings"
)

// communicationTrustPin is the owner's explicit decision about one pinned host
// certificate: whether it may sign collaboration scopes. Approval is the owner's
// Relay click; the record is audited, and revoking is the same operation.
type communicationTrustPin struct {
	NodeID            string `json:"node_id"`
	CertificateSHA256 string `json:"certificate_sha256"`
	SignsScopes       bool   `json:"signs_scopes"`
	Approval          string `json:"approval"`
}

// communicationTrustScopePin changes only the signs_scopes flag of a host
// certificate that is already pinned, or of this host's own certificate. It is
// owner administration: a provider credential, an actor pane, or a peer request
// never reaches it.
func communicationTrustScopePin(root, node string, r CommunicationRequest, d communicationSigningDeps) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	pin := r.TrustPin
	if pin == nil || !canonicalRouteToken(pin.NodeID) || !remoteDigest(pin.CertificateSHA256) || !canonicalRouteToken(strings.ToLower(pin.Approval)) {
		return nil, errors.New("a trust pin names a host, its certificate and the owner approval")
	}
	var set communicationTrustSet
	if err := communicationRead(communicationTrustPath(root), &set); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	_, cert, err := d.keys.HostKey()
	if err != nil {
		return nil, err
	}
	self := pin.NodeID == node && peerFingerprint(cert) == pin.CertificateSHA256
	found := false
	for i := range set.Nodes {
		if set.Nodes[i].NodeID == pin.NodeID && set.Nodes[i].CertificateSHA256 == pin.CertificateSHA256 {
			set.Nodes[i].SignsScopes = pin.SignsScopes
			found = true
		}
	}
	if !found {
		if !self {
			return nil, errors.New("only a pinned host or this host's own certificate can be pinned for scopes")
		}
		set.Nodes = append(set.Nodes, communicationTrustedNode{NodeID: node, CertificateSHA256: pin.CertificateSHA256, SignsScopes: pin.SignsScopes})
	}
	set.Version = 1
	if err := communicationAtomic(communicationTrustPath(root), set); err != nil {
		return nil, err
	}
	if err := communicationEvent(root, node, "communication_trust_scope_pin", []map[string]string{{"node_id": pin.NodeID,
		"certificate_sha256": pin.CertificateSHA256, "signs_scopes": map[bool]string{true: "true", false: "false"}[pin.SignsScopes], "approval": pin.Approval}}); err != nil {
		return nil, errors.New("trust pin saved but event append failed; inspect before recovery")
	}
	status := "pinned"
	if !pin.SignsScopes {
		status = "revoked"
	}
	return map[string]any{"status": status, "node_id": pin.NodeID, "certificate_sha256": pin.CertificateSHA256, "authority": "relayd"}, nil
}

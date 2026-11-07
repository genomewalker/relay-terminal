package daemon

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// desktopCapabilityTTL bounds an owner capability. It never outlives its request.
const desktopCapabilityTTL = 5 * time.Minute

// communicationDesktopCapability is the owner's single-use authority to establish
// one pair, minted by one Approve click. It binds exactly the request, the desktop
// session and its registration, the pane, the peer host and its certificate, and
// the callers the owner approved. It is consumed before any network use, so a
// failed attempt cannot be retried with it.
type communicationDesktopCapability struct {
	Version     int                      `json:"version"`
	ID          string                   `json:"id"`
	RequestID   string                   `json:"request_id"`
	SessionID   string                   `json:"session_id"`
	AccountRoot string                   `json:"account_root"`
	PaneID      string                   `json:"pane_id"`
	PeerNodeID  string                   `json:"peer_node_id"`
	PeerCertSHA string                   `json:"peer_certificate_sha256"`
	Callers     []string                 `json:"callers"`
	ScopeID     string                   `json:"scope_id"`
	PeerScope   communicationScopeRecord `json:"peer_scope"`
	CreatedAt   time.Time                `json:"created_at"`
	ExpiresAt   time.Time                `json:"expires_at"`
	Consumed    bool                     `json:"consumed"`
}

func desktopCapabilityPath(root, id string) string {
	return filepath.Join(root, "desktop-capability-"+id+".json")
}

// communicationDesktopCapabilityMint records a new capability for one approved pair.
func communicationDesktopCapabilityMint(root string, request communicationDesktopLinkRequest, callers []string, scopeID string,
	peerScope communicationScopeRecord, peerCert string, now time.Time) (string, error) {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	expires := now.Add(desktopCapabilityTTL)
	if expires.After(request.ExpiresAt) {
		expires = request.ExpiresAt
	}
	if !now.Before(expires) {
		return "", errors.New("the desktop link request has no remaining lifetime")
	}
	capability := communicationDesktopCapability{Version: 1, ID: hex.EncodeToString(raw[:]), RequestID: request.ID,
		SessionID: request.SessionID, AccountRoot: request.AccountRoot, PaneID: request.PaneID, PeerNodeID: request.PeerNodeID,
		PeerCertSHA: peerCert, Callers: append([]string(nil), callers...), ScopeID: scopeID, PeerScope: peerScope,
		CreatedAt: now.UTC(), ExpiresAt: expires.UTC()}
	if err := communicationAtomic(desktopCapabilityPath(root, capability.ID), capability); err != nil {
		return "", err
	}
	return capability.ID, nil
}

// communicationDesktopLinkEstablish spends one owner capability to establish its
// pair. Every bound field must match the request exactly, the capability must be
// unspent and unexpired, and the session registration must be the one it was
// minted for. Only then is the capability consumed and the pair established.
func communicationDesktopLinkEstablish(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	if !remoteDigest(r.OwnerCapability) {
		return nil, errors.New("an owner capability is required")
	}
	var capability communicationDesktopCapability
	if err := communicationRead(desktopCapabilityPath(root, r.OwnerCapability), &capability); err != nil {
		return nil, errors.New("no owner capability")
	}
	callers := append([]string(nil), r.AllowedCallers...)
	sort.Strings(callers)
	err := communicationFanoutLocked(root, func() error {
		if capability.Version != 1 || capability.ID != r.OwnerCapability {
			return errors.New("invalid owner capability")
		}
		if capability.Consumed {
			return errors.New("owner capability already used")
		}
		if !desktopLinkNow().Before(capability.ExpiresAt) {
			return errors.New("owner capability expired")
		}
		expected := append([]string(nil), capability.Callers...)
		sort.Strings(expected)
		if r.RequestID != capability.RequestID || r.SourcePaneID != capability.SessionID || r.PaneID != capability.PaneID ||
			r.PeerNodeID != capability.PeerNodeID || !sameCallerSet(callers, expected) {
			return errors.New("owner capability does not bind this request")
		}
		endpoint, err := readClaudeSessionEndpoint(root, capability.SessionID)
		if err != nil || endpoint.AccountRoot != capability.AccountRoot {
			return errors.New("the desktop session registration changed; request it again")
		}
		capability.Consumed = true
		return communicationAtomic(desktopCapabilityPath(root, capability.ID), capability)
	})
	if err != nil {
		return nil, err
	}
	route, binding, cert, err := establishRoute(root, node, capability.PeerNodeID, capability.PeerCertSHA)
	if err != nil {
		return nil, err
	}
	peerScope := capability.PeerScope
	plan := &establishPlan{route: route, binding: binding, cert: peerFingerprint(cert), scopeID: capability.ScopeID,
		caller: capability.Callers[0], approved: true, scopeRecord: &peerScope, desktopAccount: capability.AccountRoot}
	run := CommunicationRequest{Operation: "route_desktop_link_establish", SourcePaneID: capability.SessionID, PaneID: capability.PaneID,
		PeerNodeID: capability.PeerNodeID}
	link, err := communicationEstablishRun(root, node, run, plan, hooks)
	if err != nil {
		return nil, err
	}
	if err := os.Remove(desktopLinkRequestPath(root, capability.RequestID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	return map[string]any{"link": link, "status": "established", "authority": "relayd"}, nil
}

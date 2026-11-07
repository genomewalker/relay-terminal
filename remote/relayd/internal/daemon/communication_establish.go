package daemon

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// Scope-gated establishment of a reciprocal v1 pair. When two panes are both
// members of the owner-signed scope held by BOTH hosts, the sending relayd
// proposes the pair over the pinned mutual-TLS peer wire (operation
// "establish"), the peer validates against its own scope copy and live
// recipient observation, and each host saves revision 1 of its half. Nothing is
// established for any other pair; callers then see today's behavior unchanged.

const (
	establishWireVersion  = 4
	establishLegacyCaller = "legacy-unattributed"
)

type communicationEstablishWire struct {
	Version            int                             `json:"version"`
	Operation          string                          `json:"operation"`
	MessageID          string                          `json:"message_id"`
	SourceNodeID       string                          `json:"source_node_id"`
	TargetNodeID       string                          `json:"target_node_id"`
	SourcePaneID       string                          `json:"source_pane_id"`
	TargetPaneID       string                          `json:"target_pane_id"`
	CallerID           string                          `json:"caller_id"`
	SourceConversation communicationPinnedConversation `json:"source_conversation"`
	ScopeID            string                          `json:"scope_id"`
	// ScopeRecord carries the holder's owner-signed record of the pair, so the
	// peer can hold its own copy. Absent for the pre-existing establish shape.
	ScopeRecord *communicationScopeRecord `json:"scope_record,omitempty"`
	// ReplyCallerID is the caller the proposer admits for replies from the peer's
	// pane. Empty for a pair established with one caller label.
	ReplyCallerID string `json:"reply_caller_id,omitempty"`
	Fingerprint   string `json:"fingerprint"`
}

func establishFingerprint(m communicationEstablishWire) string {
	m.Fingerprint = ""
	data, _ := json.Marshal(m)
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func validEstablishWire(m communicationEstablishWire, node string) bool {
	return m.Version == establishWireVersion && m.Operation == "establish" && canonicalRouteToken(node) && m.TargetNodeID == node &&
		canonicalRouteToken(m.SourceNodeID) && m.SourceNodeID != node && canonicalRouteToken(m.SourcePaneID) && canonicalRouteToken(m.TargetPaneID) &&
		canonicalRouteToken(m.CallerID) && m.CallerID != establishLegacyCaller && (m.ReplyCallerID == "" || canonicalRouteToken(m.ReplyCallerID)) && canonicalRouteToken(m.MessageID) && canonicalRouteToken(m.ScopeID) &&
		validRemoteConversation(m.SourceConversation) && m.Fingerprint == establishFingerprint(m)
}

func establishWireDetected(data []byte) bool {
	var header struct {
		Version   int    `json:"version"`
		Operation string `json:"operation"`
	}
	return json.Unmarshal(data, &header) == nil && header.Version == establishWireVersion && header.Operation == "establish"
}

type communicationEstablishAudit struct {
	Time          time.Time `json:"time"`
	LinkID        string    `json:"link_id"`
	Side          string    `json:"side"`
	Status        string    `json:"status"`
	ScopeID       string    `json:"scope_id"`
	PeerNodeID    string    `json:"peer_node_id"`
	LocalPaneID   string    `json:"local_pane_id"`
	PeerPaneID    string    `json:"peer_pane_id"`
	CallerID      string    `json:"caller_id"`
	PeerCertSHA   string    `json:"peer_certificate_sha256"`
	MessageID     string    `json:"establish_message_id,omitempty"`
	LinkRevisions [2]uint64 `json:"link_revisions"`
}

func appendEstablishAudit(root string, a communicationEstablishAudit) error {
	data, err := json.Marshal(a)
	if err != nil {
		return err
	}
	f, err := OpenPrivateFile(filepath.Join(root, "scope-establish-"+a.LinkID+".jsonl"), os.O_CREATE|os.O_WRONLY|os.O_APPEND)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err = f.Write(append(data, '\n')); err == nil {
		err = f.Sync()
	}
	return err
}

// establishRoute finds the one active route to peer and requires its pinned
// certificate to match the expected fingerprint (when given).
func establishRoute(root, node, peer, wantCert string) (communicationRoute, CommunicationPeerBinding, *x509.Certificate, error) {
	var found communicationRoute
	paths, err := filepath.Glob(filepath.Join(root, "route-*.json"))
	if err != nil {
		return found, CommunicationPeerBinding{}, nil, err
	}
	matches := 0
	for _, path := range paths {
		var route communicationRoute
		if err := communicationRead(path, &route); err != nil {
			return found, CommunicationPeerBinding{}, nil, err
		}
		if validCommunicationRoute(route, node) && !route.Retired && route.PeerNodeID == peer {
			found = route
			matches++
		}
	}
	if matches != 1 {
		return found, CommunicationPeerBinding{}, nil, errors.New("exactly one active reviewed route to the peer required")
	}
	route, binding, cert, err := activePeerRoute(root, node, found.ID)
	if err != nil {
		return route, binding, nil, err
	}
	if wantCert != "" && peerFingerprint(cert) != wantCert {
		return route, binding, nil, errors.New("unreviewed peer certificate")
	}
	return route, binding, cert, nil
}

// remoteLinkSamePins reports whether two halves describe the identical
// reviewed relationship (everything except timestamps and the retired flag).
func remoteLinkSamePins(a, b CommunicationRemoteLink) bool {
	if a.Retired || b.Retired || len(a.AllowedPeerCallers) != len(b.AllowedPeerCallers) {
		return false
	}
	for i := range a.AllowedPeerCallers {
		if a.AllowedPeerCallers[i] != b.AllowedPeerCallers[i] {
			return false
		}
	}
	return a.Version == b.Version && a.ID == b.ID && a.NodeID == b.NodeID && a.PeerNodeID == b.PeerNodeID && a.LocalPaneID == b.LocalPaneID &&
		a.PeerPaneID == b.PeerPaneID && a.RouteID == b.RouteID && a.RouteRevision == b.RouteRevision && a.PeerCertificateSHA256 == b.PeerCertificateSHA256 &&
		a.LocalConversation == b.LocalConversation && a.PeerConversation == b.PeerConversation && a.PeerRevision == b.PeerRevision && a.Revision == b.Revision
}

// communicationEstablishCommit saves a new revision-1 half under the metadata
// lock, applying the same validation route_link_set applies. An existing link is
// never replaced: identical pins are idempotent success, anything else refuses.
func communicationEstablishCommit(root, node string, requested CommunicationRemoteLink, scopeID, side, messageID string) (CommunicationRemoteLink, string, error) {
	requested.Version, requested.NodeID = 1, node
	requested.Revision, requested.PeerRevision = 1, 1
	requested.ID = remotePairID(node, requested.LocalPaneID, requested.PeerNodeID, requested.PeerPaneID)
	previous, err := readRemoteLink(root, node, requested.ID)
	if err == nil {
		if remoteLinkSamePins(previous, requested) {
			return previous, "current", nil
		}
		return previous, "", errors.New("relationship changed; verified transition required")
	}
	if !errors.Is(err, os.ErrNotExist) {
		return requested, "", err
	}
	paths, err := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
	if err != nil {
		return requested, "", err
	}
	if len(paths) >= 256 {
		return requested, "", errors.New("remote pair limit reached")
	}
	route, _, cert, err := activePeerRoute(root, node, requested.RouteID)
	if err != nil {
		return requested, "", err
	}
	if route.PeerNodeID != requested.PeerNodeID || route.Revision != requested.RouteRevision || peerFingerprint(cert) != requested.PeerCertificateSHA256 {
		return requested, "", errors.New("reviewed peer route changed")
	}
	now := time.Now().UTC()
	requested.CreatedAt, requested.UpdatedAt, requested.Retired = now, now, false
	if !validRemoteLink(requested, node) {
		return requested, "", errors.New("invalid reviewed remote pair")
	}
	if err := communicationAtomic(remoteLinkPath(root, requested.ID), requested); err != nil {
		return requested, "", err
	}
	if err := communicationEvent(root, node, "communication_remote_pair_saved", []map[string]string{{"link_id": requested.ID, "peer_node_id": requested.PeerNodeID, "origin": "scope_establish"}}); err != nil {
		return requested, "", errors.New("remote pair saved but event append failed; read current revision before recovery")
	}
	if err := appendEstablishAudit(root, communicationEstablishAudit{Time: now, LinkID: requested.ID, Side: side, Status: "established", ScopeID: scopeID, PeerNodeID: requested.PeerNodeID,
		LocalPaneID: requested.LocalPaneID, PeerPaneID: requested.PeerPaneID, CallerID: requested.AllowedPeerCallers[0], PeerCertSHA: requested.PeerCertificateSHA256,
		MessageID: messageID, LinkRevisions: [2]uint64{requested.Revision, requested.PeerRevision}}); err != nil {
		return requested, "established", errors.New("remote pair saved but audit append failed; read current state before recovery")
	}
	return requested, "established", nil
}

func establishObservedPin(observe func(string) communicationMember, pane string) (communicationPinnedConversation, bool) {
	live := observe(pane)
	pin := communicationPin(live)
	return pin, communicationPinMatches(pin, live) && validRemoteConversation(pin)
}

// establishPlan is what the sending side verified under its lock.
type establishPlan struct {
	route   communicationRoute
	binding CommunicationPeerBinding
	cert    string
	scopeID string
	caller  string
	// approved marks an establishment authorized by a consumed owner capability,
	// not by a caller token. desktopAccount is recorded on the saved half.
	approved       bool
	scopeRecord    *communicationScopeRecord
	desktopAccount string
	replyCaller    string
}

// communicationEstablishPrepare decides, under the caller's metadata lock,
// whether a missing link may be established. ok=false means "behave exactly as
// before" (the caller returns the original missing-link error).
func communicationEstablishPrepare(root, node string, r CommunicationRequest, caller string) (plan *establishPlan, ok bool) {
	if r.Operation != "remote_send" || r.ExpectedRemoteLinkRevision != 0 || r.ClientToken == "" || caller == establishLegacyCaller || !canonicalRouteToken(caller) ||
		!canonicalRouteToken(r.PeerNodeID) || r.PeerNodeID == node || r.LinkID != remotePairID(node, r.SourcePaneID, r.PeerNodeID, r.PaneID) {
		return nil, false
	}
	scopeID, allowed := communicationScopeAllows(root, node, node, r.SourcePaneID, r.PeerNodeID, r.PaneID)
	if !allowed {
		return nil, false
	}
	route, binding, cert, err := establishRoute(root, node, r.PeerNodeID, "")
	if err != nil {
		return nil, false
	}
	return &establishPlan{route: route, binding: binding, cert: peerFingerprint(cert), scopeID: scopeID, caller: caller}, true
}

// communicationEstablishRun proposes the pair to the peer and saves this host's
// half. It never runs under the metadata lock while the network is in use.
func communicationEstablishRun(root, node string, r CommunicationRequest, plan *establishPlan, hooks communicationGroupNative) (CommunicationRemoteLink, error) {
	var empty CommunicationRemoteLink
	local, ok := establishObservedPin(hooks.observe, r.SourcePaneID)
	if !ok {
		return empty, errors.New("source conversation unavailable; pair not established")
	}
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return empty, err
	}
	m := communicationEstablishWire{Version: establishWireVersion, Operation: "establish", MessageID: hex.EncodeToString(id[:]), SourceNodeID: node, TargetNodeID: r.PeerNodeID,
		SourcePaneID: r.SourcePaneID, TargetPaneID: r.PaneID, CallerID: plan.caller, SourceConversation: local, ScopeID: plan.scopeID, ScopeRecord: plan.scopeRecord, ReplyCallerID: plan.replyCaller}
	m.Fingerprint = establishFingerprint(m)
	body, _ := json.Marshal(m)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	data, err := remotePeerPost(ctx, root, node, plan.binding, body)
	if err != nil {
		return empty, errors.New("peer did not confirm the pair; nothing established here")
	}
	var reply struct {
		Status             string                          `json:"status"`
		MessageID          string                          `json:"message_id"`
		LinkID             string                          `json:"link_id"`
		Fingerprint        string                          `json:"fingerprint"`
		TargetConversation communicationPinnedConversation `json:"target_conversation"`
	}
	linkID := remotePairID(node, r.SourcePaneID, r.PeerNodeID, r.PaneID)
	if json.Unmarshal(data, &reply) != nil || reply.MessageID != m.MessageID || reply.LinkID != linkID || reply.Fingerprint != m.Fingerprint ||
		(reply.Status != "established" && reply.Status != "current") || !validRemoteConversation(reply.TargetConversation) {
		return empty, errors.New("peer pair confirmation unavailable; nothing established here")
	}
	// Re-check everything that could have changed while the request was in flight.
	var link CommunicationRemoteLink
	err = communicationFanoutLocked(root, func() error {
		identity := plan.caller
		var err error
		if !plan.approved {
			identity, err = communicationAuthorize(root, r)
			if err != nil {
				return err
			}
		}
		if identity != plan.caller {
			return errors.New("submitting caller identity changed")
		}
		if scope, allowed := communicationScopeAllows(root, node, node, r.SourcePaneID, r.PeerNodeID, r.PaneID); !allowed || scope != plan.scopeID {
			return errors.New("collaboration scope no longer allows this pair")
		}
		route, _, cert, err := establishRoute(root, node, r.PeerNodeID, plan.cert)
		if err != nil {
			return err
		}
		if route.ID != plan.route.ID || route.Revision != plan.route.Revision || peerFingerprint(cert) != plan.cert {
			return errors.New("reviewed peer route changed")
		}
		if now, ok := establishObservedPin(hooks.observe, r.SourcePaneID); !ok || now != local {
			return errors.New("source conversation changed; pair not established")
		}
		requested := CommunicationRemoteLink{PeerNodeID: r.PeerNodeID, LocalPaneID: r.SourcePaneID, PeerPaneID: r.PaneID, RouteID: route.ID, RouteRevision: route.Revision,
			PeerCertificateSHA256: plan.cert, LocalConversation: local, PeerConversation: reply.TargetConversation, AllowedPeerCallers: establishReplyAllowed(plan), DesktopAccountRoot: plan.desktopAccount}
		link, _, err = communicationEstablishCommit(root, node, requested, plan.scopeID, "proposer", m.MessageID)
		return err
	})
	if err != nil {
		return empty, err
	}
	return link, nil
}

// communicationReceiveEstablish is the accepting side. It runs only for a
// request that arrived over the pinned mutual-TLS channel (peerCert).
func communicationReceiveEstablish(root, node, peerCert string, m communicationEstablishWire, hooks communicationGroupNative) (map[string]any, error) {
	if !validEstablishWire(m, node) || !remoteDigest(peerCert) {
		return nil, errors.New("invalid establish request")
	}
	if m.ScopeRecord != nil {
		// The holder's own signed record of exactly this pair, verified against this
		// host's pinned signers before it is stored as this host's copy.
		if err := communicationFanoutLocked(root, func() error {
			trusted, err := communicationTrustedNodes(root, defaultCommunicationSigningDeps(root, node), node)
			if err != nil {
				return err
			}
			body, err := communicationVerifyScope(*m.ScopeRecord, trusted, node)
			if err != nil {
				return err
			}
			first, second, ok := communicationScopeExactPair(body)
			source := communicationScopeMember{NodeID: m.SourceNodeID, PaneID: m.SourcePaneID}
			target := communicationScopeMember{NodeID: node, PaneID: m.TargetPaneID}
			if !ok || !((first == source && second == target) || (first == target && second == source)) {
				return errors.New("scope record names another pair")
			}
			_, err = communicationScopeStorePair(root, node, *m.ScopeRecord, trusted)
			return err
		}); err != nil {
			return nil, err
		}
	}
	check := func() (communicationRoute, string, error) {
		scopeID, allowed := communicationScopeAllows(root, node, m.SourceNodeID, m.SourcePaneID, node, m.TargetPaneID)
		if !allowed {
			return communicationRoute{}, "", errors.New("unreviewed pair")
		}
		route, _, cert, err := establishRoute(root, node, m.SourceNodeID, peerCert)
		if err != nil {
			return route, "", err
		}
		if peerFingerprint(cert) != peerCert {
			return route, "", errors.New("unreviewed peer certificate")
		}
		return route, scopeID, nil
	}
	if err := communicationFanoutLocked(root, func() error { _, _, err := check(); return err }); err != nil {
		return nil, err
	}
	local, ok := establishObservedPin(hooks.observe, m.TargetPaneID)
	if !ok {
		return nil, errors.New("recipient conversation unavailable")
	}
	var link CommunicationRemoteLink
	status := ""
	err := communicationFanoutLocked(root, func() error {
		route, scopeID, err := check()
		if err != nil {
			return err
		}
		requested := CommunicationRemoteLink{PeerNodeID: m.SourceNodeID, LocalPaneID: m.TargetPaneID, PeerPaneID: m.SourcePaneID, RouteID: route.ID, RouteRevision: route.Revision,
			PeerCertificateSHA256: peerCert, LocalConversation: local, PeerConversation: m.SourceConversation, AllowedPeerCallers: []string{m.CallerID}}
		link, status, err = communicationEstablishCommit(root, node, requested, scopeID, "acceptor", m.MessageID)
		return err
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": status, "message_id": m.MessageID, "link_id": link.ID, "fingerprint": m.Fingerprint, "target_conversation": link.LocalConversation,
		"target_link_revision": link.Revision, "replay_permitted": false, "authority": "relayd"}, nil
}

func handleEstablishWire(w http.ResponseWriter, root, node, peerCert string, data []byte, hooks communicationGroupNative) {
	var m communicationEstablishWire
	if communicationStrictJSON(data, &m) != nil {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}
	result, err := communicationReceiveEstablish(root, node, peerCert, m, hooks)
	if err != nil {
		http.Error(w, "establish request rejected", http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}

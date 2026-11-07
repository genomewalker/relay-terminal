package daemon

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Desktop link approval over a route carried by the Relay host channel. There
// is no HTTPS peer to probe or post to, so the app carries one signed exchange
// during the owner's Approve click:
//
//  1. route_desktop_link_approve (this host) spends the owner capability and
//     returns a proposal signed with this host's peer identity key, addressed
//     to the peer node, with a fresh random message ID. It saves only a private
//     pending record of what it proposed.
//  2. deliver_signed_desktop_establish (the peer's relayd) verifies the
//     envelope against the key it pins for the sending node, refuses an
//     envelope addressed to any other node or outside the freshness window,
//     runs the same establish receiver as the HTTPS path, and returns its
//     answer signed with its own key.
//  3. route_desktop_link_settle (this host) spends the pending record once,
//     verifies the reply against the peer's pinned key, requires it to repeat
//     the message ID and fingerprint and to be current, and re-checks route,
//     revision and key before saving this host's half.
//
// The signed reply to a fresh proposal is the live identity proof the HTTPS
// probe gives. The app can delay or drop the exchange; it cannot forge, alter,
// replay or redirect it.
const (
	desktopNativeEstablishKind = "desktop-establish"
	desktopNativeReplyKind     = "desktop-establish-reply"
	desktopNativePendingKeep   = time.Hour
)

type desktopNativeEstablish struct {
	Wire       communicationEstablishWire `json:"wire"`
	PeerNodeID string                     `json:"peer_node_id"`
	SentAt     time.Time                  `json:"sent_at"`
}

type desktopNativeEstablishReply struct {
	ProposerNodeID string         `json:"proposer_node_id"`
	Reply          establishReply `json:"reply"`
	RepliedAt      time.Time      `json:"replied_at"`
}

type desktopNativePending struct {
	Version        int                             `json:"version"`
	MessageID      string                          `json:"message_id"`
	Fingerprint    string                          `json:"fingerprint"`
	RequestID      string                          `json:"request_id"`
	SessionID      string                          `json:"session_id"`
	PaneID         string                          `json:"pane_id"`
	PeerNodeID     string                          `json:"peer_node_id"`
	RouteID        string                          `json:"route_id"`
	RouteRevision  uint64                          `json:"route_revision"`
	PeerCertSHA    string                          `json:"peer_certificate_sha256"`
	ScopeID        string                          `json:"scope_id"`
	Caller         string                          `json:"caller"`
	ReplyCaller    string                          `json:"reply_caller,omitempty"`
	DesktopAccount string                          `json:"desktop_account"`
	Local          communicationPinnedConversation `json:"local_conversation"`
	Created        time.Time                       `json:"created"`
}

func desktopNativePendingPath(root, id string) string {
	return filepath.Join(root, "desktop-native-establish-"+id+".json")
}

// desktopNativeCurrent reports whether a signed timestamp is inside the host
// channel freshness window.
func desktopNativeCurrent(at time.Time) bool {
	age := workNativeNow().Sub(at)
	return !at.IsZero() && age <= workNativeFreshness && age >= -workNativeClockSkew
}

// desktopNativeDispatch saves what this host proposes and returns the signed
// proposal for the app to carry. Nothing is established here yet.
func desktopNativeDispatch(root, node, requestID string, run CommunicationRequest, plan *establishPlan, hooks communicationGroupNative) (map[string]any, error) {
	local, ok := establishObservedPin(hooks.observe, run.SourcePaneID)
	if !ok {
		return nil, errors.New("source conversation unavailable; pair not established")
	}
	m, err := establishWireFor(node, run, plan, local)
	if err != nil {
		return nil, err
	}
	now := workNativeNow()
	payload, err := json.Marshal(desktopNativeEstablish{Wire: m, PeerNodeID: run.PeerNodeID, SentAt: now})
	if err != nil {
		return nil, err
	}
	var envelope string
	err = communicationFanoutLocked(root, func() error {
		if e := desktopNativePrune(root, now); e != nil {
			return e
		}
		var e error
		if envelope, e = workNativeSign(root, node, desktopNativeEstablishKind, payload); e != nil {
			return e
		}
		return communicationAtomic(desktopNativePendingPath(root, m.MessageID), desktopNativePending{Version: 1, MessageID: m.MessageID, Fingerprint: m.Fingerprint,
			RequestID: requestID, SessionID: run.SourcePaneID, PaneID: run.PaneID, PeerNodeID: run.PeerNodeID, RouteID: plan.route.ID, RouteRevision: plan.route.Revision,
			PeerCertSHA: plan.cert, ScopeID: plan.scopeID, Caller: plan.caller, ReplyCaller: plan.replyCaller, DesktopAccount: plan.desktopAccount, Local: local, Created: now})
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": "dispatch", "carrier": "relay_host_channel", "request_id": requestID, "message_id": m.MessageID,
		"peer_node_id": run.PeerNodeID, "establish_envelope": envelope, "authority": "relayd"}, nil
}

// desktopNativePrune removes pending proposals that can no longer settle.
// Called under the lock.
func desktopNativePrune(root string, now time.Time) error {
	paths, err := filepath.Glob(filepath.Join(root, "desktop-native-establish-*.json"))
	if err != nil {
		return err
	}
	for _, path := range paths {
		var p desktopNativePending
		if communicationRead(path, &p) != nil || now.Sub(p.Created) > desktopNativePendingKeep {
			if e := os.Remove(path); e != nil && !errors.Is(e, os.ErrNotExist) {
				return e
			}
		}
	}
	return nil
}

// communicationDesktopNativeReceive is the peer's half: it accepts a proposal
// only from the node its pinned host-channel route names as the signer, and
// only when the proposal is addressed to this node.
//
// Receive is not single-use: within the freshness window a carrier can replay
// the same signed proposal. That is accepted as idempotent, since the establish
// receiver answers an identical pair "current" and saves nothing new, and the
// approving host settles each proposal at most once.
func communicationDesktopNativeReceive(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	text := r.EstablishEnvelope
	var env workNativeEnvelope
	if len(text) == 0 || len(text) > workNativeEnvLimit || communicationStrictWorkJSONLimit([]byte(text), &env, workNativeEnvLimit) != nil {
		return nil, errors.New("invalid desktop establish envelope")
	}
	sender := env.Node
	if !canonicalRouteToken(sender) || sender == node {
		return nil, errors.New("desktop establish envelope names no other sending host")
	}
	var pin string
	err := communicationFanoutLocked(root, func() error {
		_, binding, cert, e := establishRoute(root, node, sender, "")
		if e != nil {
			return errors.New("no active route to the sending host: " + e.Error())
		}
		if binding.Endpoint != workNativeEndpoint {
			return errors.New("the route to the sending host is not carried by the Relay host channel")
		}
		pin = peerFingerprint(cert)
		return nil
	})
	if err != nil {
		return nil, err
	}
	payload, _, err := workNativeVerify(text, desktopNativeEstablishKind, sender, pin)
	if err != nil {
		return nil, err
	}
	var proposal desktopNativeEstablish
	if communicationStrictWorkJSONLimit(payload, &proposal, workNativeWireLimit) != nil {
		return nil, errors.New("invalid desktop establish proposal")
	}
	if proposal.PeerNodeID != node || proposal.Wire.TargetNodeID != node {
		return nil, errors.New("desktop establish proposal is addressed to another host")
	}
	if proposal.Wire.SourceNodeID != sender {
		return nil, errors.New("desktop establish proposal does not match its signer")
	}
	if !desktopNativeCurrent(proposal.SentAt) {
		return nil, errors.New("desktop establish proposal is not current")
	}
	result, err := communicationReceiveEstablish(root, node, pin, proposal.Wire, hooks)
	if err != nil {
		return nil, err
	}
	reply := establishReply{MessageID: proposal.Wire.MessageID, Fingerprint: proposal.Wire.Fingerprint}
	reply.Status, _ = result["status"].(string)
	reply.LinkID, _ = result["link_id"].(string)
	reply.TargetConversation, _ = result["target_conversation"].(communicationPinnedConversation)
	body, err := json.Marshal(desktopNativeEstablishReply{ProposerNodeID: sender, Reply: reply, RepliedAt: workNativeNow()})
	if err != nil {
		return nil, err
	}
	var envelope string
	if err := communicationFanoutLocked(root, func() error {
		var e error
		envelope, e = workNativeSign(root, node, desktopNativeReplyKind, body)
		return e
	}); err != nil {
		return nil, err
	}
	return map[string]any{"status": "delivered_reply", "message_id": proposal.Wire.MessageID, "establish_reply": envelope, "authority": "relayd"}, nil
}

// communicationDesktopNativeSettle spends the pending proposal once and saves
// this host's half only for a current reply, signed by the pinned peer key,
// to exactly that proposal, over the unchanged route.
func communicationDesktopNativeSettle(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	id := strings.ToLower(r.MessageID)
	if !canonicalRouteToken(id) {
		return nil, errors.New("desktop establish message ID required")
	}
	var p desktopNativePending
	err := communicationFanoutLocked(root, func() error {
		path := desktopNativePendingPath(root, id)
		if e := communicationRead(path, &p); e != nil {
			return errors.New("no pending desktop establish for this message; approve the request again")
		}
		// Single use: a replayed or second reply finds nothing to settle.
		if e := os.Remove(path); e != nil {
			return e
		}
		if p.Version != 1 || p.MessageID != id {
			return errors.New("invalid pending desktop establish")
		}
		if !desktopNativeCurrent(p.Created) {
			return errors.New("the desktop establish proposal expired before its reply; approve the request again")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	payload, _, err := workNativeVerify(r.EstablishReply, desktopNativeReplyKind, p.PeerNodeID, p.PeerCertSHA)
	if err != nil {
		return nil, err
	}
	var reply desktopNativeEstablishReply
	if communicationStrictWorkJSONLimit(payload, &reply, workNativeWireLimit) != nil {
		return nil, errors.New("invalid desktop establish reply")
	}
	if reply.ProposerNodeID != node || reply.Reply.MessageID != p.MessageID || reply.Reply.Fingerprint != p.Fingerprint {
		return nil, errors.New("desktop establish reply does not answer this proposal")
	}
	if !desktopNativeCurrent(reply.RepliedAt) {
		return nil, errors.New("desktop establish reply is not current")
	}
	run := CommunicationRequest{Operation: "route_desktop_link_establish", SourcePaneID: p.SessionID, PaneID: p.PaneID, PeerNodeID: p.PeerNodeID}
	plan := &establishPlan{route: communicationRoute{ID: p.RouteID, Revision: p.RouteRevision}, cert: p.PeerCertSHA, scopeID: p.ScopeID,
		caller: p.Caller, replyCaller: p.ReplyCaller, approved: true, desktopAccount: p.DesktopAccount}
	link, err := establishConfirm(root, node, run, plan, p.MessageID, p.Fingerprint, p.Local, reply.Reply, hooks)
	if err != nil {
		return nil, err
	}
	if err := os.Remove(desktopLinkRequestPath(root, p.RequestID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	return map[string]any{"link": link, "status": "established", "carrier": "relay_host_channel", "authority": "relayd"}, nil
}

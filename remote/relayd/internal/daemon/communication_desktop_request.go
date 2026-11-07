package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// desktopLinkRequestTTL bounds how long a request waits for the owner.
const desktopLinkRequestTTL = 10 * time.Minute

// desktopLinkNow is the clock for request expiry; tests replace it.
var desktopLinkNow = func() time.Time { return time.Now().UTC() }

// communicationDesktopLinkRequest is a verified Claude desktop session's request
// for a route link to one exact pane. It is only a request: no link exists until
// the owner approves it through route_desktop_link_approve, before ExpiresAt.
type communicationDesktopLinkRequest struct {
	Version     int    `json:"version"`
	ID          string `json:"id"`
	SessionID   string `json:"session_id"`
	AccountRoot string `json:"account_root"`
	PaneID      string `json:"pane_id"`
	// PeerNodeID is the host of the pane, verified live during approval.
	PeerNodeID string    `json:"peer_node_id"`
	CreatedAt  time.Time `json:"created_at"`
	ExpiresAt  time.Time `json:"expires_at"`
}

func desktopLinkRequestID(session, pane string) string {
	sum := sha256.Sum256([]byte("desktop-link-request\n" + session + "\n" + pane))
	return hex.EncodeToString(sum[:])
}

func desktopLinkRequestPath(root, id string) string {
	return filepath.Join(root, "desktop-link-request-"+id+".json")
}

// communicationDesktopLinkRequestOp records a pending request. The sender is the
// kernel-verified session, which must hold an active desktop registration.
func communicationDesktopLinkRequestOp(root, node string, r CommunicationRequest, now time.Time) (map[string]any, error) {
	session := strings.ToLower(r.SourcePaneID)
	pane := strings.ToLower(r.PaneID)
	if !r.actorVerified || !strings.EqualFold(r.ActorPaneID, r.SourcePaneID) {
		return nil, errors.New("a desktop link request needs the verified sender session")
	}
	if !nativeClaudeSessionID.MatchString(session) {
		return nil, errors.New("a desktop link request is made only by a Claude desktop session")
	}
	if !validSessionID.MatchString(pane) || pane == session {
		return nil, errors.New("a desktop link request names one other pane")
	}
	peerNode := strings.ToLower(r.PeerNodeID)
	if !canonicalRouteToken(peerNode) {
		return nil, errors.New("a desktop link request names the host of its pane")
	}
	endpoint, err := readClaudeSessionEndpoint(root, session)
	if err != nil {
		return nil, errors.New("this Claude session is not registered as a desktop session")
	}
	request := communicationDesktopLinkRequest{Version: 1, ID: desktopLinkRequestID(session, pane), SessionID: session,
		AccountRoot: endpoint.AccountRoot, PaneID: pane, PeerNodeID: peerNode, CreatedAt: now, ExpiresAt: now.Add(desktopLinkRequestTTL)}
	var linked *CommunicationRemoteLink
	err = communicationFanoutLocked(root, func() error {
		if _, err := communicationAuthorize(root, r); err != nil {
			return err
		}
		if err := pruneDesktopLinkRequests(root, now); err != nil {
			return err
		}
		// The owner already approved this exact pair: report it, and clear any
		// request a repeated call left for a second, redundant approval.
		if link, ok := desktopSessionActiveLink(root, node, session, peerNode, pane, endpoint.AccountRoot); ok {
			linked = &link
			if err := os.Remove(desktopLinkRequestPath(root, request.ID)); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
			return nil
		}
		if err := clearDesktopLinkRejection(root, request.ID); err != nil {
			return err
		}
		return communicationAtomic(desktopLinkRequestPath(root, request.ID), request)
	})
	if err != nil {
		return nil, err
	}
	if linked != nil {
		return desktopLinkedReply(*linked, request.ID), nil
	}
	return map[string]any{"status": "pending_approval", "request_id": request.ID, "expires_at": request.ExpiresAt, "authority": "relayd",
		"note": "No link exists until the owner approves this request in Relay on the Mac, before it expires."}, nil
}

// desktopSessionActiveLink returns the active route link that pins this desktop
// session as its local conversation and names exactly this pane on this host.
// The link ID is derived from the pair, so nothing is chosen between. A link
// approved under another Claude account registration is not reported, since
// replies over it are refused.
func desktopSessionActiveLink(root, node, session, peerNode, pane, accountRoot string) (CommunicationRemoteLink, bool) {
	link, err := readRemoteLink(root, node, remotePairID(node, session, peerNode, pane))
	if err != nil || link.Retired || !strings.EqualFold(link.LocalPaneID, session) || !strings.EqualFold(link.PeerPaneID, pane) ||
		link.PeerNodeID != peerNode || link.LocalConversation.Provider != "claude" || !strings.EqualFold(link.LocalConversation.SessionID, session) {
		return CommunicationRemoteLink{}, false
	}
	if link.DesktopAccountRoot != "" && link.DesktopAccountRoot != accountRoot {
		return CommunicationRemoteLink{}, false
	}
	return link, true
}

// desktopLinkedReply is what a desktop session sees for an approved pair.
func desktopLinkedReply(link CommunicationRemoteLink, requestID string) map[string]any {
	return map[string]any{"status": "linked", "link_id": link.ID, "request_id": requestID, "session_id": strings.ToLower(link.LocalPaneID),
		"pane_id": strings.ToLower(link.PeerPaneID), "peer_node_id": link.PeerNodeID, "revision": link.Revision, "authority": "relayd",
		"note": "The owner approved this link. Send with relay_message_pane naming pane_id."}
}

// readDesktopLinkRequest returns the live request with this ID. An expired one
// is removed, so it can never be approved later.
func readDesktopLinkRequest(root, id string, now time.Time) (communicationDesktopLinkRequest, error) {
	var request communicationDesktopLinkRequest
	if !remoteDigest(id) {
		return request, errors.New("no pending desktop link request")
	}
	if err := communicationRead(desktopLinkRequestPath(root, id), &request); err != nil {
		return request, errors.New("no pending desktop link request")
	}
	if request.Version != 1 || request.ID != id || !nativeClaudeSessionID.MatchString(request.SessionID) || !validSessionID.MatchString(request.PaneID) {
		return request, errors.New("invalid desktop link request")
	}
	if !now.Before(request.ExpiresAt) {
		_ = os.Remove(desktopLinkRequestPath(root, id))
		return request, errors.New("the desktop link request expired; ask again")
	}
	return request, nil
}

// desktopLinkListing is one pending request as the owner sees it: the request
// and the callers the saved pair would admit. Refusal names why it cannot be
// approved yet, and nothing is guessed.
type desktopLinkListing struct {
	communicationDesktopLinkRequest
	ProposedCallers []string `json:"proposed_callers"`
	Refusal         string   `json:"refusal,omitempty"`
	// Carrier names a route the app must carry during approval: the peer host
	// is then resolved before anything is spent. Empty for an HTTPS route.
	Carrier string `json:"carrier,omitempty"`
}

// communicationDesktopLinkList returns the owner's pending, unexpired requests.
func communicationDesktopLinkList(root, node string, now time.Time) (map[string]any, error) {
	paths, err := filepath.Glob(filepath.Join(root, "desktop-link-request-*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	listing := []desktopLinkListing{}
	for _, path := range paths {
		id := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(path), "desktop-link-request-"), ".json")
		request, err := readDesktopLinkRequest(root, id, now)
		if err != nil {
			continue
		}
		item := desktopLinkListing{communicationDesktopLinkRequest: request, ProposedCallers: []string{}}
		if peer, err := communicationDesktopLinkPeer(root, node, request); err == nil {
			item.ProposedCallers = append(item.ProposedCallers, peer.AllowedPeerCallers...)
		} else if _, binding, _, routeErr := establishRoute(root, node, request.PeerNodeID, ""); routeErr != nil {
			item.Refusal = "no active route to the requested host: " + routeErr.Error()
		} else {
			if binding.Endpoint == workNativeEndpoint {
				item.Carrier = "relay_host_channel"
			}
			// No reviewed pane link: the pair is established under its own scope, with
			// the two directional callers the owner approves as shown.
			item.ProposedCallers = directionalPairCallers(request.SessionID, request.PaneID)
		}
		listing = append(listing, item)
	}
	return map[string]any{"requests": listing, "authority": "relayd", "desktop_required": false}, nil
}

// communicationDesktopLinkPeer takes the route, certificate, peer revision and
// peer conversation pin for a pane from a saved route link to that same pane.
// That link was reviewed when it was made, so nothing here is guessed. No such
// link is an explicit refusal.
func communicationDesktopLinkPeer(root, node string, request communicationDesktopLinkRequest) (CommunicationRemoteLink, error) {
	var empty CommunicationRemoteLink
	paths, err := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
	if err != nil {
		return empty, err
	}
	for _, path := range paths {
		var known CommunicationRemoteLink
		if communicationRead(path, &known) != nil || known.Retired || known.NodeID != node || known.Version != 1 {
			continue
		}
		if strings.EqualFold(known.PeerPaneID, request.PaneID) && known.PeerConversation.SessionID != "" && known.PeerConversation.Provider != "" {
			return CommunicationRemoteLink{PeerNodeID: known.PeerNodeID, RouteID: known.RouteID, RouteRevision: known.RouteRevision,
				PeerCertificateSHA256: known.PeerCertificateSHA256, PeerConversation: known.PeerConversation,
				AllowedPeerCallers: known.AllowedPeerCallers}, nil
		}
	}
	return empty, errors.New("no reviewed route link to this pane supplies its route and conversation pin; pair the pane once from its host first")
}

// communicationDesktopLinkApprove creates the pinned route link for a pending
// request, through the reviewed route_link_set path. Only the owner's
// authenticated route may approve. The approval must name exactly the requested
// session and pane. The route and peer pin come from a saved link to that pane,
// and the session's registration must still be the one the request recorded.
func communicationDesktopLinkApprove(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	request, err := readDesktopLinkRequest(root, r.RequestID, desktopLinkNow())
	if err != nil {
		return nil, err
	}
	if strings.ToLower(r.SourcePaneID) != request.SessionID || strings.ToLower(r.PaneID) != request.PaneID {
		return nil, errors.New("the approval names another pair than the request")
	}
	endpoint, err := readClaudeSessionEndpoint(root, request.SessionID)
	if err != nil || endpoint.AccountRoot != request.AccountRoot {
		return nil, errors.New("the desktop session registration changed; request it again")
	}
	peer, err := communicationDesktopLinkPeer(root, node, request)
	if err != nil {
		// No reviewed pane link to take the pin from: establish the pair from the
		// owner-signed pair scope, under the capability this click mints.
		return communicationDesktopLinkApproveScoped(root, node, r, request, hooks)
	}
	if request.PeerNodeID != peer.PeerNodeID {
		return nil, errors.New("the request names another host than the reviewed pair")
	}
	if r.AllowedCallers == nil || !sameCallerSet(r.AllowedCallers, peer.AllowedPeerCallers) {
		return nil, errors.New("approve the exact callers the pair would admit: " + strings.Join(peer.AllowedPeerCallers, ", "))
	}
	link := peer
	link.Version = 1
	link.AllowedPeerCallers = append([]string(nil), r.AllowedCallers...)
	link.NodeID, link.LocalPaneID, link.PeerPaneID = node, request.SessionID, request.PaneID
	link.LocalConversation = communicationPinnedConversation{Provider: "claude", SessionID: request.SessionID}
	link.DesktopAccountRoot = request.AccountRoot
	link.ID = remotePairID(node, request.SessionID, peer.PeerNodeID, request.PaneID)
	// A new pair starts at revision 1 on the peer; the peer pins this revision.
	link.PeerRevision = 1
	if r.RemoteLink != nil && (!strings.EqualFold(r.RemoteLink.LocalPaneID, request.SessionID) || !strings.EqualFold(r.RemoteLink.PeerPaneID, request.PaneID) ||
		r.RemoteLink.LocalConversation != link.LocalConversation) {
		return nil, errors.New("the reviewed link names another pair than the request")
	}
	// An active link for this pair is refused; a retired one is re-established from its revision.
	expected := uint64(0)
	if prior, priorErr := readRemoteLink(root, node, link.ID); priorErr == nil {
		if !prior.Retired {
			// The request is redundant: drop it so it is not offered again.
			_ = os.Remove(desktopLinkRequestPath(root, request.ID))
			return nil, errors.New("this pair is already linked")
		}
		expected = prior.Revision
	} else if !errors.Is(priorErr, os.ErrNotExist) {
		return nil, priorErr
	}
	result, err := communicationRemoteLinkSet(root, node, CommunicationRequest{Operation: "route_link_set", RemoteLink: &link, ExpectedRemoteLinkRevision: expected}, hooks)
	if err != nil {
		return nil, err
	}
	if err := os.Remove(desktopLinkRequestPath(root, request.ID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	result["desktop_request_id"] = request.ID
	return result, nil
}

// communicationDesktopLinkReject removes a pending request, so it can never be
// approved. Only the owner's authenticated route may reject.
func communicationDesktopLinkReject(root string, r CommunicationRequest) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	if !remoteDigest(r.RequestID) {
		return nil, errors.New("no pending desktop link request")
	}
	var request communicationDesktopLinkRequest
	readErr := communicationRead(desktopLinkRequestPath(root, r.RequestID), &request)
	if err := os.Remove(desktopLinkRequestPath(root, r.RequestID)); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, errors.New("no pending desktop link request")
		}
		return nil, err
	}
	// The session may poll its request; it then reads rejected, not an absence.
	if readErr == nil && request.ID == r.RequestID && nativeClaudeSessionID.MatchString(request.SessionID) {
		if err := recordDesktopLinkRejection(root, request, desktopLinkNow()); err != nil {
			return nil, err
		}
	}
	return map[string]any{"status": "rejected", "request_id": r.RequestID, "authority": "relayd"}, nil
}

// pruneDesktopLinkRequests removes every expired request file. It runs at write
// time, so expired requests never accumulate, and reads still refuse them.
func pruneDesktopLinkRequests(root string, now time.Time) error {
	paths, err := filepath.Glob(filepath.Join(root, "desktop-link-request-*.json"))
	if err != nil {
		return err
	}
	for _, path := range paths {
		var request communicationDesktopLinkRequest
		if communicationRead(path, &request) != nil || !now.Before(request.ExpiresAt) {
			if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
	}
	rejections, err := filepath.Glob(filepath.Join(root, "desktop-link-rejected-*.json"))
	if err != nil {
		return err
	}
	for _, path := range rejections {
		var rejection desktopLinkRejection
		if communicationRead(path, &rejection) != nil || !now.Before(rejection.ExpiresAt) {
			if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
	}
	return nil
}

// sameCallerSet reports whether two caller lists name the same callers, in any order.
func sameCallerSet(a, b []string) bool {
	if len(a) != len(b) || len(a) == 0 {
		return false
	}
	seen := map[string]int{}
	for _, value := range a {
		seen[value]++
	}
	for _, value := range b {
		if seen[value] == 0 {
			return false
		}
		seen[value]--
	}
	return true
}

// communicationDesktopLinkApproveScoped is the approval of a pair that no reviewed
// pane link covers. The owner's click signs this pair's scope for both hosts,
// mints one capability bound to exactly this request, and spends it to establish
// the pair over the pinned wire. Anything unverifiable refuses by name first.
func communicationDesktopLinkApproveScoped(root, node string, r CommunicationRequest, request communicationDesktopLinkRequest, hooks communicationGroupNative) (map[string]any, error) {
	peerNode := request.PeerNodeID
	if !canonicalRouteToken(peerNode) || peerNode == node {
		return nil, errors.New("this request names no other host to establish the pair with")
	}
	if !sameCallerSet(r.AllowedCallers, directionalPairCallers(request.SessionID, request.PaneID)) {
		return nil, errors.New("approve the pair's two callers as shown: the desktop's outbound and the pane's reply caller")
	}
	route, binding, cert, err := establishRoute(root, node, peerNode, "")
	if err != nil {
		return nil, errors.New("no active route to the requested host: " + err.Error())
	}
	if binding.PeerNodeID != peerNode {
		return nil, errors.New("the route to the requested host names another host")
	}
	// The host's identity is taken live over the pinned transport, not from files.
	// Over the Relay host channel the establish exchange itself is that proof:
	// a fresh proposal answered by a reply signed with the pinned host key,
	// checked by route_desktop_link_settle before anything is saved here.
	if binding.Endpoint != workNativeEndpoint {
		if _, err := communicationPeerProbe(root, node, CommunicationRequest{Operation: "route_probe", RouteID: route.ID,
			ExpectedRouteRevision: route.Revision}); err != nil {
			return nil, errors.New("the requested host's live identity was not verified: " + err.Error())
		}
	}
	a := communicationScopeMember{NodeID: node, PaneID: request.SessionID}
	b := communicationScopeMember{NodeID: peerNode, PaneID: request.PaneID}
	scopeID := "pair-" + communicationScopePairKey(a, b)
	revision := uint64(1)
	if prior, found, err := communicationScopePairLoad(root, node, a, b); err != nil {
		return nil, err
	} else if found {
		revision = prior.Revision + 1
	}
	now := desktopLinkNow()
	recordA, err := communicationSignScope(root, node, communicationPairScopeBody(scopeID, node, node, revision, now, a, b))
	if err != nil {
		return nil, err
	}
	recordB, err := communicationSignScope(root, node, communicationPairScopeBody(scopeID, peerNode, node, revision, now, a, b))
	if err != nil {
		return nil, err
	}
	trusted, err := communicationTrustedNodes(root, defaultCommunicationSigningDeps(root, node), node)
	if err != nil {
		return nil, err
	}
	if _, err := communicationScopeStorePair(root, node, recordA, trusted); err != nil {
		return nil, errors.New("this host does not pin its own certificate for scope signing: " + err.Error())
	}
	capabilityID, err := communicationDesktopCapabilityMint(root, request, directionalDesktopCaller(request.SessionID), directionalPaneCaller(request.PaneID), scopeID, recordB, peerFingerprint(cert), now)
	if err != nil {
		return nil, err
	}
	return communicationDesktopLinkEstablish(root, node, CommunicationRequest{Operation: "route_desktop_link_establish",
		RequestID: request.ID, SourcePaneID: request.SessionID, PaneID: request.PaneID, PeerNodeID: peerNode,
		AllowedCallers: r.AllowedCallers, OwnerCapability: capabilityID}, hooks)
}

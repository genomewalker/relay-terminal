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
	Version     int       `json:"version"`
	ID          string    `json:"id"`
	SessionID   string    `json:"session_id"`
	AccountRoot string    `json:"account_root"`
	PaneID      string    `json:"pane_id"`
	CreatedAt   time.Time `json:"created_at"`
	ExpiresAt   time.Time `json:"expires_at"`
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
func communicationDesktopLinkRequestOp(root string, r CommunicationRequest, now time.Time) (map[string]any, error) {
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
	endpoint, err := readClaudeSessionEndpoint(root, session)
	if err != nil {
		return nil, errors.New("this Claude session is not registered as a desktop session")
	}
	request := communicationDesktopLinkRequest{Version: 1, ID: desktopLinkRequestID(session, pane), SessionID: session,
		AccountRoot: endpoint.AccountRoot, PaneID: pane, CreatedAt: now, ExpiresAt: now.Add(desktopLinkRequestTTL)}
	err = communicationFanoutLocked(root, func() error {
		if _, err := communicationAuthorize(root, r); err != nil {
			return err
		}
		return communicationAtomic(desktopLinkRequestPath(root, request.ID), request)
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": "pending_approval", "request_id": request.ID, "expires_at": request.ExpiresAt, "authority": "relayd",
		"note": "No link exists until the owner approves this request in Relay on the Mac, before it expires."}, nil
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

// communicationDesktopLinkList returns the owner's pending, unexpired requests.
func communicationDesktopLinkList(root string, now time.Time) (map[string]any, error) {
	paths, err := filepath.Glob(filepath.Join(root, "desktop-link-request-*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	requests := []communicationDesktopLinkRequest{}
	for _, path := range paths {
		id := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(path), "desktop-link-request-"), ".json")
		if request, err := readDesktopLinkRequest(root, id, now); err == nil {
			requests = append(requests, request)
		}
	}
	return map[string]any{"requests": requests, "authority": "relayd", "desktop_required": false}, nil
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
		return nil, err
	}
	link := peer
	link.Version = 1
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
	result, err := communicationRemoteLinkSet(root, node, CommunicationRequest{Operation: "route_link_set", RemoteLink: &link}, hooks)
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
	if err := os.Remove(desktopLinkRequestPath(root, r.RequestID)); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, errors.New("no pending desktop link request")
		}
		return nil, err
	}
	return map[string]any{"status": "rejected", "request_id": r.RequestID, "authority": "relayd"}, nil
}

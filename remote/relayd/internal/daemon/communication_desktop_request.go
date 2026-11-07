package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// communicationDesktopLinkRequest is a verified Claude desktop session's request
// for a route link to one exact pane. It is only a request: no link exists until
// the owner approves it through route_desktop_link_approve.
type communicationDesktopLinkRequest struct {
	Version     int       `json:"version"`
	ID          string    `json:"id"`
	SessionID   string    `json:"session_id"`
	AccountRoot string    `json:"account_root"`
	PaneID      string    `json:"pane_id"`
	CreatedAt   time.Time `json:"created_at"`
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
		AccountRoot: endpoint.AccountRoot, PaneID: pane, CreatedAt: now}
	err = communicationFanoutLocked(root, func() error {
		if _, err := communicationAuthorize(root, r); err != nil {
			return err
		}
		return communicationAtomic(desktopLinkRequestPath(root, request.ID), request)
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": "pending_approval", "request_id": request.ID, "authority": "relayd",
		"note": "No link exists until the owner approves this request in Relay on the Mac."}, nil
}

// communicationDesktopLinkApprove creates the pinned route link for a pending
// request, through the same reviewed route_link_set path. The approval must name
// exactly the requested session and pane, and the session's registration must
// still be the one the request recorded.
func communicationDesktopLinkApprove(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	// Only the owner's authenticated route may approve; a client never can.
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	if r.RemoteLink == nil || !remoteDigest(r.RequestID) {
		return nil, errors.New("an approval names a pending request and its reviewed link")
	}
	var request communicationDesktopLinkRequest
	if err := communicationRead(desktopLinkRequestPath(root, r.RequestID), &request); err != nil {
		return nil, errors.New("no pending desktop link request")
	}
	link := *r.RemoteLink
	if strings.ToLower(link.LocalPaneID) != request.SessionID || strings.ToLower(link.PeerPaneID) != request.PaneID ||
		link.LocalConversation != (communicationPinnedConversation{Provider: "claude", SessionID: request.SessionID}) {
		return nil, errors.New("the approval names another pair than the request")
	}
	endpoint, err := readClaudeSessionEndpoint(root, request.SessionID)
	if err != nil || endpoint.AccountRoot != request.AccountRoot {
		return nil, errors.New("the desktop session registration changed; request it again")
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

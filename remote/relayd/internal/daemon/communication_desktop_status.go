package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// desktopLinkRejection records that the owner rejected one session's request,
// so the session can read that outcome instead of an unexplained absence.
type desktopLinkRejection struct {
	Version   int       `json:"version"`
	ID        string    `json:"id"`
	SessionID string    `json:"session_id"`
	ExpiresAt time.Time `json:"expires_at"`
}

func desktopLinkRejectionPath(root, id string) string {
	return filepath.Join(root, "desktop-link-rejected-"+id+".json")
}

// communicationDesktopLinkStatus reads the outcome of the calling session's own
// request: pending_approval, linked, rejected, expired or not_found. The request
// ID is derived from the session, so another session's request never matches,
// and a pending request of another session reads as not_found.
func communicationDesktopLinkStatus(root, node string, r CommunicationRequest, now time.Time) (map[string]any, error) {
	session := strings.ToLower(r.SourcePaneID)
	if !r.actorVerified || !strings.EqualFold(r.ActorPaneID, r.SourcePaneID) || !nativeClaudeSessionID.MatchString(session) {
		return nil, errors.New("a desktop link request is read only by the verified session that made it")
	}
	id := r.RequestID
	if !remoteDigest(id) {
		return nil, errors.New("request_id must be 64 lowercase hex characters")
	}
	if _, err := communicationAuthorize(root, r); err != nil {
		return nil, err
	}
	endpoint, err := readClaudeSessionEndpoint(root, session)
	if err != nil {
		return nil, errors.New("this Claude session is not registered as a desktop session")
	}
	reply := func(status, note string) map[string]any {
		return map[string]any{"status": status, "request_id": id, "authority": "relayd", "note": note}
	}
	var request communicationDesktopLinkRequest
	if communicationRead(desktopLinkRequestPath(root, id), &request) == nil && request.ID == id && request.SessionID == session {
		if link, ok := desktopSessionActiveLink(root, node, session, request.PeerNodeID, request.PaneID, endpoint.AccountRoot); ok {
			return desktopLinkedReply(link, id), nil
		}
		if !now.Before(request.ExpiresAt) {
			return reply("expired", "The owner did not approve this request before it expired. Call relay_link_panes again to ask once more."), nil
		}
		out := reply("pending_approval", "Waiting for the owner to approve this request in Relay on the Mac.")
		out["expires_at"], out["pane_id"], out["peer_node_id"] = request.ExpiresAt, request.PaneID, request.PeerNodeID
		return out, nil
	}
	// No pending request: the link it asked for, if approved, names the pane.
	paths, err := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
	if err != nil {
		return nil, err
	}
	for _, path := range paths {
		var known CommunicationRemoteLink
		if communicationRead(path, &known) != nil || known.NodeID != node || !strings.EqualFold(known.LocalPaneID, session) ||
			desktopLinkRequestID(session, strings.ToLower(known.PeerPaneID)) != id {
			continue
		}
		if link, ok := desktopSessionActiveLink(root, node, session, known.PeerNodeID, strings.ToLower(known.PeerPaneID), endpoint.AccountRoot); ok {
			return desktopLinkedReply(link, id), nil
		}
	}
	var rejection desktopLinkRejection
	if communicationRead(desktopLinkRejectionPath(root, id), &rejection) == nil && rejection.ID == id && rejection.SessionID == session && now.Before(rejection.ExpiresAt) {
		return reply("rejected", "The owner rejected this request. Nothing was linked."), nil
	}
	return reply("not_found", "No pending request, rejection or link matches this request_id for this session; it may have expired. Call relay_link_panes again to ask once more."), nil
}

// recordDesktopLinkRejection keeps a rejection readable by its session for as
// long as a request would have waited.
func recordDesktopLinkRejection(root string, request communicationDesktopLinkRequest, now time.Time) error {
	return communicationAtomic(desktopLinkRejectionPath(root, request.ID), desktopLinkRejection{Version: 1, ID: request.ID,
		SessionID: request.SessionID, ExpiresAt: now.Add(desktopLinkRequestTTL)})
}

// clearDesktopLinkRejection forgets an earlier rejection when the session asks again.
func clearDesktopLinkRejection(root, id string) error {
	if err := os.Remove(desktopLinkRejectionPath(root, id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// desktopSessionLinkEntry is one approved link as its desktop session sees it.
type desktopSessionLinkEntry struct {
	LinkID     string    `json:"link_id"`
	PaneID     string    `json:"pane_id"`
	PeerNodeID string    `json:"peer_node_id"`
	RouteID    string    `json:"route_id"`
	Revision   uint64    `json:"revision"`
	CreatedAt  time.Time `json:"created_at"`
}

// desktopSessionOwnLinks returns the active route links whose local side is the
// calling verified, registered desktop session. ok is false for any other caller.
func desktopSessionOwnLinks(root, node string, r CommunicationRequest) ([]desktopSessionLinkEntry, bool) {
	session := strings.ToLower(r.ActorPaneID)
	if !r.actorVerified || !nativeClaudeSessionID.MatchString(session) {
		return nil, false
	}
	endpoint, err := readClaudeSessionEndpoint(root, session)
	if err != nil {
		return nil, false
	}
	paths, _ := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
	own := []desktopSessionLinkEntry{}
	for _, path := range paths {
		var known CommunicationRemoteLink
		if communicationRead(path, &known) != nil || known.NodeID != node || !strings.EqualFold(known.LocalPaneID, session) {
			continue
		}
		if link, ok := desktopSessionActiveLink(root, node, session, known.PeerNodeID, strings.ToLower(known.PeerPaneID), endpoint.AccountRoot); ok {
			own = append(own, desktopSessionLinkEntry{LinkID: link.ID, PaneID: strings.ToLower(link.PeerPaneID), PeerNodeID: link.PeerNodeID,
				RouteID: link.RouteID, Revision: link.Revision, CreatedAt: link.CreatedAt})
		}
	}
	return own, true
}

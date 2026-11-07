package daemon

import (
	"testing"
	"time"
)

func desktopStatus(root, session, id string, verified bool) (map[string]any, error) {
	return communicationDesktopLinkStatus(root, "node-a", CommunicationRequest{Operation: "desktop_link_status", SourcePaneID: session,
		ActorPaneID: session, actorVerified: verified, ClientToken: remoteSenderToken, RequestID: id}, time.Now().UTC())
}

// The requesting session reads its own request through pending, linked and
// rejected; another or unverified session never reads it.
func TestDesktopLinkStatusIsReadByItsSession(t *testing.T) {
	a, _, proposed, _, hooks := requestFixture(t)
	id := desktopLinkRequestID(desktopAlias, testGroupB)
	if got, err := desktopStatus(a, desktopAlias, id, true); err != nil || got["status"] != "not_found" {
		t.Fatal("status before any request", got, err)
	}
	if err := desktopRequest(a, desktopAlias); err != nil {
		t.Fatal(err)
	}
	if got, err := desktopStatus(a, desktopAlias, id, true); err != nil || got["status"] != "pending_approval" || got["pane_id"] != testGroupB {
		t.Fatal("pending status", got, err)
	}
	other := "00000000-0000-4000-8000-00000000d00d"
	if got, err := desktopStatus(a, other, id, true); err == nil && got["status"] != "not_found" {
		t.Fatal("another session read the request", got)
	}
	if _, err := desktopStatus(a, desktopAlias, id, false); err == nil {
		t.Fatal("an unverified caller read the request")
	}
	if _, err := desktopStatus(a, desktopAlias, "F998"+id[4:], true); err == nil {
		t.Fatal("a non-canonical request_id was accepted")
	}
	// Rejected stays readable, and a new request clears it.
	if _, err := communicationDesktopLinkReject(a, CommunicationRequest{Operation: "route_desktop_link_reject", RequestID: id}); err != nil {
		t.Fatal(err)
	}
	if got, err := desktopStatus(a, desktopAlias, id, true); err != nil || got["status"] != "rejected" {
		t.Fatal("rejected status", got, err)
	}
	if got, _ := desktopStatus(a, other, id, true); got["status"] == "rejected" {
		t.Fatal("another session read the rejection", got)
	}
	if err := desktopRequest(a, desktopAlias); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationDesktopLinkApprove(a, "node-a", CommunicationRequest{Operation: "route_desktop_link_approve", AllowedCallers: []string{"receiver"},
		RequestID: id, SourcePaneID: desktopAlias, PaneID: testGroupB, RemoteLink: &proposed}, hooks); err != nil {
		t.Fatal("approve", err)
	}
	got, err := desktopStatus(a, desktopAlias, id, true)
	if err != nil || got["status"] != "linked" || got["link_id"] == nil {
		t.Fatal("linked status", got, err)
	}
	if got, _ := desktopStatus(a, other, id, true); got["status"] == "linked" {
		t.Fatal("another session read the link", got)
	}
}

// A request past its expiry reads expired, not pending.
func TestDesktopLinkStatusExpired(t *testing.T) {
	a, _, _, _, _ := requestFixture(t)
	id := desktopLinkRequestID(desktopAlias, testGroupB)
	if _, err := communicationDesktopLinkRequestOp(a, "node-a", CommunicationRequest{Operation: "desktop_link_request", SourcePaneID: desktopAlias,
		PaneID: testGroupB, PeerNodeID: "node-b", ClientToken: remoteSenderToken, ActorPaneID: desktopAlias, actorVerified: true}, time.Now().UTC().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if got, err := desktopStatus(a, desktopAlias, id, true); err != nil || got["status"] != "expired" {
		t.Fatal("expired status", got, err)
	}
}

// The list for a desktop session holds its own approved links, and only for
// that verified session.
func TestDesktopSessionListsOwnLinks(t *testing.T) {
	a, _, proposed, _, hooks := requestFixture(t)
	result, err := communicationRemoteLinkSet(a, "node-a", CommunicationRequest{Operation: "route_link_set", RemoteLink: &proposed}, hooks)
	if err != nil {
		t.Fatal(err)
	}
	link := result["link"].(CommunicationRemoteLink)
	own, ok := desktopSessionOwnLinks(a, "node-a", CommunicationRequest{Operation: "list", ActorPaneID: desktopAlias, actorVerified: true})
	if !ok || len(own) != 1 || own[0].LinkID != link.ID || own[0].PaneID != testGroupB || own[0].PeerNodeID != "node-b" {
		t.Fatal("own link not listed", own, ok)
	}
	for _, r := range []CommunicationRequest{
		{Operation: "list", ActorPaneID: desktopAlias},
		{Operation: "list", ActorPaneID: "00000000-0000-4000-8000-00000000d00d", actorVerified: true},
		{Operation: "list", ActorPaneID: testGroupB, actorVerified: true},
	} {
		if own, ok := desktopSessionOwnLinks(a, "node-a", r); ok || len(own) != 0 {
			t.Fatal("another caller listed the session's links", r, own)
		}
	}
}

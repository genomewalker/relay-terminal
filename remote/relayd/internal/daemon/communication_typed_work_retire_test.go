package daemon

import (
	"context"
	"testing"
	"time"
)

// A typed (pane <-> Work) relationship had no owner retire path: route_link_retire
// read only v1 pairs, so a created Work link could not be revoked without
// editing state by hand (bc08, 2026-11-12).
func savedTypedLink(t *testing.T) (string, communicationTypedRemoteLink) {
	t.Helper()
	root, h, desired := typedLinkFixture(t)
	fence := func(context.Context, communicationEndpoint) (func() error, func(), error) {
		return func() error { return nil }, func() {}, nil
	}
	saved, err := communicationCreateTypedWorkLink(context.Background(), root, receiverNode, CommunicationRequest{}, desired, fence, func() time.Time { return h.clock })
	if err != nil {
		t.Fatal("create typed link", err)
	}
	return root, saved
}

func TestTypedWorkLinkOwnerRetireIsRevisionCheckedAndFinal(t *testing.T) {
	root, saved := savedTypedLink(t)
	retire := func(r CommunicationRequest) (map[string]any, error) {
		r.Operation, r.LinkID = "route_link_retire", saved.ID
		return communicationRemoteLinkOperation(root, receiverNode, r)
	}
	if _, err := retire(CommunicationRequest{ActorPaneID: sourceFixturePane, ExpectedRemoteLinkRevision: saved.Revision}); err == nil {
		t.Fatal("an agent pane retired an owner relationship")
	}
	if _, err := retire(CommunicationRequest{ClientToken: "client", ExpectedRemoteLinkRevision: saved.Revision}); err == nil {
		t.Fatal("a registered client retired an owner relationship")
	}
	if _, err := retire(CommunicationRequest{ExpectedRemoteLinkRevision: saved.Revision + 1}); err == nil {
		t.Fatal("stale revision accepted")
	}
	if current, err := readTypedRemoteLink(root, receiverNode, saved.ID); err != nil || current.Retired || current.Revision != saved.Revision {
		t.Fatal("refused retire changed the link", current, err)
	}
	result, err := retire(CommunicationRequest{ExpectedRemoteLinkRevision: saved.Revision})
	if err != nil {
		t.Fatal("owner retire", err)
	}
	got, ok := result["typed_link"].(communicationTypedRemoteLink)
	if !ok || !got.Retired || got.Revision != saved.Revision+1 {
		t.Fatal("retire result", result)
	}
	stored, err := readTypedRemoteLink(root, receiverNode, saved.ID)
	if err != nil || !stored.Retired || stored.Revision != saved.Revision+1 || !stored.CreatedAt.Equal(saved.CreatedAt) {
		t.Fatal("stored retired link", stored, err)
	}
	if _, err := communicationReadTypedActiveLink(context.Background(), root, receiverNode, saved.ID); err == nil {
		t.Fatal("retired link still active for send and re-pin")
	}
	wire := workWire{LinkID: saved.ID, Source: saved.Peer, Target: saved.Local, SourceRevision: saved.PeerRevision, TargetRevision: stored.Revision, Caller: "caller"}
	if workLinkMatchesWire(stored, wire, true) {
		t.Fatal("retired link still admits inbound messages")
	}
	if _, err := retire(CommunicationRequest{ExpectedRemoteLinkRevision: stored.Revision}); err == nil {
		t.Fatal("retired link retired twice")
	}
	listed, err := communicationRemoteLinkOperation(root, receiverNode, CommunicationRequest{Operation: "route_link_list"})
	if err != nil {
		t.Fatal(err)
	}
	if typed := listed["typed_links"].([]communicationTypedRemoteLink); len(typed) != 1 || !typed[0].Retired {
		t.Fatal("list does not show the retired link", typed)
	}
}

func TestRouteLinkRetireUnknownTypedIDIsNotFound(t *testing.T) {
	root, saved := savedTypedLink(t)
	other := []byte(saved.ID)
	if other[0] == 'a' {
		other[0] = 'b'
	} else {
		other[0] = 'a'
	}
	_, err := communicationRemoteLinkOperation(root, receiverNode, CommunicationRequest{Operation: "route_link_retire", LinkID: string(other), ExpectedRemoteLinkRevision: 1})
	if err == nil || err.Error() != "remote pair not found" {
		t.Fatal("unknown id", err)
	}
}

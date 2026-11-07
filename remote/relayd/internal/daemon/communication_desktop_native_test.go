package daemon

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// nativeApproval runs the scoped fixture with both bindings switched to the
// Relay host channel, files the desktop request on node-a and approves it.
// The approval returns the signed proposal the app must carry.
func nativeApproval(t *testing.T) (scopedNodes, map[string]any) {
	t.Helper()
	f := scopedFixture(t, true)
	workNativeSetEndpoint(t, f.a, workNativeEndpoint)
	workNativeSetEndpoint(t, f.b, workNativeEndpoint)
	scopedRequest(t, f.a)
	result, err := scopedApprove(f.a, testGroupB, directionalPairCallers(desktopAlias, testGroupB), f.hooksA)
	if err != nil || result["status"] != "dispatch" || result["peer_node_id"] != "node-b" || result["establish_envelope"] == "" {
		t.Fatal("approve over the host channel", result, err)
	}
	return f, result
}

func nativeDeliver(f scopedNodes, envelope string) (map[string]any, error) {
	return communicationDesktopNativeReceive(f.b, "node-b", CommunicationRequest{Operation: "deliver_signed_desktop_establish", EstablishEnvelope: envelope}, f.hooksB)
}

func nativeSettle(f scopedNodes, id, reply string) (map[string]any, error) {
	return communicationDesktopNativeSettle(f.a, "node-a", CommunicationRequest{Operation: "route_desktop_link_settle", MessageID: id, EstablishReply: reply}, f.hooksA)
}

func nativeLinks(t *testing.T, root string) int {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
	if err != nil {
		t.Fatal(err)
	}
	return len(paths)
}

// nativeResign verifies an envelope, edits its payload and signs it again with
// the identity in root, so tests can present well-signed altered frames.
func nativeResign[T any](t *testing.T, envelope, kind, node, root string, edit func(*T)) string {
	t.Helper()
	payload, _, err := workNativeVerify(envelope, kind, node, "")
	if err != nil {
		t.Fatal(err)
	}
	var value T
	if err := json.Unmarshal(payload, &value); err != nil {
		t.Fatal(err)
	}
	edit(&value)
	body, _ := json.Marshal(value)
	signed, err := workNativeSign(root, node, kind, body)
	if err != nil {
		t.Fatal(err)
	}
	return signed
}

func nativeClock(t *testing.T, offset time.Duration) {
	t.Helper()
	previous := workNativeNow
	workNativeNow = func() time.Time { return time.Now().UTC().Add(offset) }
	t.Cleanup(func() { workNativeNow = previous })
}

// One Approve click over a route carried by the Relay host channel: the app
// carries the signed proposal to node-b and its signed reply back, and both
// halves of the pair are saved.
func TestApprovalOverHostChannelRouteEstablishesThePair(t *testing.T) {
	f, dispatch := nativeApproval(t)
	if nativeLinks(t, f.a) != 0 || nativeLinks(t, f.b) != 0 {
		t.Fatal("a link was saved before the peer answered")
	}
	delivered, err := nativeDeliver(f, dispatch["establish_envelope"].(string))
	if err != nil || delivered["message_id"] != dispatch["message_id"] {
		t.Fatal("deliver", delivered, err)
	}
	if nativeLinks(t, f.b) != 1 || nativeLinks(t, f.a) != 0 {
		t.Fatal("only the peer half may exist before settle")
	}
	result, err := nativeSettle(f, dispatch["message_id"].(string), delivered["establish_reply"].(string))
	if err != nil || result["status"] != "established" {
		t.Fatal("settle", result, err)
	}
	link := result["link"].(CommunicationRemoteLink)
	if link.DesktopAccountRoot != f.account || link.LocalPaneID != desktopAlias || link.PeerPaneID != testGroupB || link.PeerNodeID != "node-b" ||
		link.PeerCertificateSHA256 != scopedFingerprint(t, f.certB, "node-b") || link.PeerConversation.SessionID != "target-conversation" {
		t.Fatal("approved link does not pin the desktop session, pane and peer key", link)
	}
	if listing, err := communicationDesktopLinkList(f.a, "node-a", desktopLinkNow()); err != nil || len(listing["requests"].([]desktopLinkListing)) != 0 {
		t.Fatal("the approved request is still pending", listing, err)
	}
}

func scopedFingerprint(t *testing.T, certPEM, node string) string {
	t.Helper()
	cert, err := peerCertificate(certPEM, node)
	if err != nil {
		t.Fatal(err)
	}
	return peerFingerprint(cert)
}

// The peer saves nothing for an unverified sender or a misrouted proposal.
func TestHostChannelEstablishReceiverRefusals(t *testing.T) {
	t.Run("wrong sender key", func(t *testing.T) {
		f, dispatch := nativeApproval(t)
		impostor, _ := peerFixture(t, "node-a")
		forged := nativeResign(t, dispatch["establish_envelope"].(string), desktopNativeEstablishKind, "node-a", impostor, func(*desktopNativeEstablish) {})
		if _, err := nativeDeliver(f, forged); err == nil || !strings.Contains(err.Error(), "not the pinned peer") {
			t.Fatal("unpinned sender accepted", err)
		}
		if nativeLinks(t, f.b) != 0 {
			t.Fatal("peer saved a link for an unverified sender")
		}
	})
	t.Run("addressed to another host", func(t *testing.T) {
		f, dispatch := nativeApproval(t)
		misrouted := nativeResign(t, dispatch["establish_envelope"].(string), desktopNativeEstablishKind, "node-a", f.a, func(p *desktopNativeEstablish) { p.PeerNodeID = "node-c" })
		if _, err := nativeDeliver(f, misrouted); err == nil || !strings.Contains(err.Error(), "addressed to another host") {
			t.Fatal("misrouted proposal accepted", err)
		}
		if nativeLinks(t, f.b) != 0 {
			t.Fatal("peer saved a link for a misrouted proposal")
		}
	})
	t.Run("stale proposal", func(t *testing.T) {
		f, dispatch := nativeApproval(t)
		nativeClock(t, workNativeFreshness+time.Minute)
		if _, err := nativeDeliver(f, dispatch["establish_envelope"].(string)); err == nil || !strings.Contains(err.Error(), "not current") {
			t.Fatal("stale proposal accepted", err)
		}
		if nativeLinks(t, f.b) != 0 {
			t.Fatal("peer saved a link for a stale proposal")
		}
	})
	t.Run("route not on the host channel", func(t *testing.T) {
		f, dispatch := nativeApproval(t)
		workNativeSetEndpoint(t, f.b, "127.0.0.1:1")
		if _, err := nativeDeliver(f, dispatch["establish_envelope"].(string)); err == nil || !strings.Contains(err.Error(), "not carried by the Relay host channel") {
			t.Fatal("proposal accepted over an HTTPS route", err)
		}
	})
}

// The approving host saves nothing until the reply passes every check.
func TestHostChannelEstablishSettleRefusals(t *testing.T) {
	carried := func(t *testing.T) (scopedNodes, string, string) {
		f, dispatch := nativeApproval(t)
		delivered, err := nativeDeliver(f, dispatch["establish_envelope"].(string))
		if err != nil {
			t.Fatal("deliver", err)
		}
		return f, dispatch["message_id"].(string), delivered["establish_reply"].(string)
	}
	refused := func(t *testing.T, f scopedNodes, id, reply, want string) {
		t.Helper()
		if _, err := nativeSettle(f, id, reply); err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("settle accepted or refused for another reason: %v (want %q)", err, want)
		}
		if nativeLinks(t, f.a) != 0 {
			t.Fatal("approving host saved a link for a refused reply")
		}
	}
	t.Run("wrong signer", func(t *testing.T) {
		f, id, reply := carried(t)
		impostor, _ := peerFixture(t, "node-b")
		forged := nativeResign(t, reply, desktopNativeReplyKind, "node-b", impostor, func(*desktopNativeEstablishReply) {})
		refused(t, f, id, forged, "not the pinned peer")
	})
	t.Run("replayed reply", func(t *testing.T) {
		f, id, reply := carried(t)
		if _, err := nativeSettle(f, id, reply); err != nil {
			t.Fatal("first settle", err)
		}
		if _, err := nativeSettle(f, id, reply); err == nil || !strings.Contains(err.Error(), "no pending desktop establish") {
			t.Fatal("replayed reply accepted", err)
		}
	})
	t.Run("reply to another proposal", func(t *testing.T) {
		f, id, reply := carried(t)
		other := nativeResign(t, reply, desktopNativeReplyKind, "node-b", f.b, func(r *desktopNativeEstablishReply) { r.Reply.MessageID = strings.Repeat("ab", 16) })
		refused(t, f, id, other, "does not answer this proposal")
	})
	t.Run("stale timestamp", func(t *testing.T) {
		f, id, reply := carried(t)
		nativeClock(t, workNativeFreshness+time.Minute)
		refused(t, f, id, reply, "expired before its reply")
	})
	t.Run("stale reply timestamp", func(t *testing.T) {
		f, id, reply := carried(t)
		old := nativeResign(t, reply, desktopNativeReplyKind, "node-b", f.b, func(r *desktopNativeEstablishReply) {
			r.RepliedAt = r.RepliedAt.Add(-(workNativeFreshness + time.Minute))
		})
		refused(t, f, id, old, "reply is not current")
	})
	t.Run("route revision bump", func(t *testing.T) {
		f, id, reply := carried(t)
		if _, err := communicationRouteOperation(f.a, "node-a", CommunicationRequest{Operation: "route_set", RouteID: "route", PeerNodeID: "node-b",
			TransportBindingID: "binding", ExpectedRouteRevision: 1}); err != nil {
			t.Fatal("bump", err)
		}
		refused(t, f, id, reply, "reviewed peer route changed")
	})
	t.Run("never carried", func(t *testing.T) {
		// No connected host for the peer node: the app sends nothing, and the
		// approving host holds only the pending proposal.
		f, dispatch := nativeApproval(t)
		refused(t, f, dispatch["message_id"].(string), "", "invalid Work envelope")
	})
}

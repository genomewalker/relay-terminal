package daemon

import (
	"strings"
	"testing"
	"time"
)

// mintCapability mints an owner capability for the current request, without the
// Approve click, so each binding can be tested on its own.
func mintCapability(t *testing.T, f scopedNodes, now time.Time) string {
	t.Helper()
	scopedRequest(t, f.a)
	request, err := readDesktopLinkRequest(f.a, desktopLinkRequestID(desktopAlias, testGroupB), now)
	if err != nil {
		t.Fatal(err)
	}
	a := communicationScopeMember{NodeID: "node-a", PaneID: desktopAlias}
	b := communicationScopeMember{NodeID: "node-b", PaneID: testGroupB}
	scopeID := "pair-" + communicationScopePairKey(a, b)
	recordA, err := communicationSignScope(f.a, "node-a", communicationPairScopeBody(scopeID, "node-a", "node-a", 1, now, a, b))
	if err != nil {
		t.Fatal(err)
	}
	trusted, err := communicationTrustedNodes(f.a, defaultCommunicationSigningDeps(f.a, "node-a"), "node-a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := communicationScopeStorePair(f.a, "node-a", recordA, trusted); err != nil {
		t.Fatal(err)
	}
	recordB, err := communicationSignScope(f.a, "node-a", communicationPairScopeBody(scopeID, "node-b", "node-a", 1, now, a, b))
	if err != nil {
		t.Fatal(err)
	}
	cert, err := peerCertificate(f.certB, "node-b")
	if err != nil {
		t.Fatal(err)
	}
	id, err := communicationDesktopCapabilityMint(f.a, request, directionalDesktopCaller(desktopAlias), directionalPaneCaller(testGroupB), scopeID, recordB, peerFingerprint(cert), now)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func spend(f scopedNodes, id string, mutate func(*CommunicationRequest)) (map[string]any, error) {
	r := CommunicationRequest{Operation: "route_desktop_link_establish", RequestID: desktopLinkRequestID(desktopAlias, testGroupB),
		SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b", AllowedCallers: directionalPairCallers(desktopAlias, testGroupB), OwnerCapability: id}
	if mutate != nil {
		mutate(&r)
	}
	return communicationDesktopLinkEstablish(f.a, "node-a", r, f.hooksA)
}

// A capability admits exactly the pair it was minted for, is spent once, and is
// refused after its lifetime. A refused attempt does not spend it.
func TestCapabilityBindsExactlyAndSpendsOnce(t *testing.T) {
	f := scopedFixture(t, true)
	now := time.Now().UTC()
	original := desktopLinkNow
	desktopLinkNow = func() time.Time { return now }
	defer func() { desktopLinkNow = original }()
	id := mintCapability(t, f, now)
	mismatches := map[string]func(*CommunicationRequest){
		"other pane":      func(r *CommunicationRequest) { r.PaneID = "00000000-0000-4000-8000-00000000f00d" },
		"other session":   func(r *CommunicationRequest) { r.SourcePaneID = scopePaneC },
		"other peer node": func(r *CommunicationRequest) { r.PeerNodeID = "node-c" },
		"other callers":   func(r *CommunicationRequest) { r.AllowedCallers = []string{"sender", "receiver"} },
		"other request":   func(r *CommunicationRequest) { r.RequestID = strings.Repeat("0", 64) },
		"legacy label": func(r *CommunicationRequest) {
			r.AllowedCallers = []string{"sender", directionalPaneCaller(testGroupB)}
		},
		"client credential": func(r *CommunicationRequest) { r.ClientToken = remoteSenderToken },
		"actor pane":        func(r *CommunicationRequest) { r.ActorPaneID = desktopAlias },
	}
	for name, mutate := range mismatches {
		if _, err := spend(f, id, mutate); err == nil {
			t.Fatal("capability accepted a request that differs in: " + name)
		}
	}
	var stored communicationDesktopCapability
	if err := communicationRead(desktopCapabilityPath(f.a, id), &stored); err != nil || stored.Consumed {
		t.Fatal("a refused attempt spent the capability", err)
	}
	if _, err := spend(f, id, nil); err != nil {
		t.Fatal("the exact request was refused", err)
	}
	if _, err := spend(f, id, nil); err == nil || !strings.Contains(err.Error(), "already used") {
		t.Fatal("a spent capability was reused", err)
	}
}

// A capability is refused after its lifetime, even though nothing else changed.
func TestCapabilityExpires(t *testing.T) {
	f := scopedFixture(t, true)
	now := time.Now().UTC()
	id := mintCapability(t, f, now)
	original := desktopLinkNow
	desktopLinkNow = func() time.Time { return now.Add(desktopCapabilityTTL + time.Second) }
	defer func() { desktopLinkNow = original }()
	if _, err := spend(f, id, nil); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatal("an expired capability was spent", err)
	}
}

// Establishing through the operation accepts no caller credential at all.
func TestCapabilityOperationRefusesClientCallers(t *testing.T) {
	f := scopedFixture(t, true)
	id := mintCapability(t, f, time.Now().UTC())
	if _, err := spend(f, id, func(r *CommunicationRequest) { r.ClientToken = remoteSenderToken }); err == nil {
		t.Fatal("a client credential established a pair")
	}
	if _, err := communicationDesktopLinkEstablish(f.a, "node-a", CommunicationRequest{Operation: "route_desktop_link_establish", OwnerCapability: id}, f.hooksA); err == nil {
		t.Fatal("an incomplete request established a pair")
	}
}

// Concurrent spends of one capability: exactly one establishes the pair, and every
// other spend is refused as already used, never by a later check.
func TestConcurrentSpendsOfOneCapabilityEstablishOnce(t *testing.T) {
	f := scopedFixture(t, true)
	now := time.Now().UTC()
	original := desktopLinkNow
	desktopLinkNow = func() time.Time { return now }
	defer func() { desktopLinkNow = original }()
	id := mintCapability(t, f, now)
	const spends = 8
	type outcome struct{ err error }
	results := make(chan outcome, spends)
	start := make(chan struct{})
	for i := 0; i < spends; i++ {
		go func() {
			<-start
			_, err := spend(f, id, nil)
			results <- outcome{err}
		}()
	}
	close(start)
	successes, used := 0, 0
	for i := 0; i < spends; i++ {
		result := <-results
		switch {
		case result.err == nil:
			successes++
		case strings.Contains(result.err.Error(), "already used"):
			used++
		default:
			t.Fatal("a concurrent spend failed for another reason", result.err)
		}
	}
	if successes != 1 || used != spends-1 {
		t.Fatalf("successes=%d already_used=%d; want 1 and %d", successes, used, spends-1)
	}
}

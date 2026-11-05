package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func expiryFixture() (communicationLink, []CatalogPane, time.Time) {
	now := time.Date(2026, 10, 25, 6, 0, 0, 0, time.UTC)
	id, ids, _ := communicationPair(sourceFixturePane, targetFixturePane)
	link := communicationLink{Version: 1, ID: id, NodeID: "expiry-node", UpdatedAt: now.Add(-90 * 24 * time.Hour),
		Members: []communicationMember{{PaneID: ids[0]}, {PaneID: ids[1]}}}
	panes := []CatalogPane{{NodeID: link.NodeID, PaneID: ids[0], State: "missing"},
		{NodeID: link.NodeID, PaneID: ids[1], State: "running", Recoverable: true}}
	return link, panes, now
}

func TestCommunicationExpiryGraceActivityAndClock(t *testing.T) {
	link, panes, now := expiryFixture()
	first, expire := communicationLinkExpiry(link, link.NodeID, panes, now)
	if expire || first.InactiveSince == nil || !first.InactiveSince.Equal(now) {
		t.Fatal("historical link expired without a fresh observation grace")
	}
	if _, expire := communicationLinkExpiry(first, link.NodeID, panes, now.Add(communicationInactiveRetention-time.Nanosecond)); expire {
		t.Fatal("link expired before grace elapsed")
	}
	if _, expire := communicationLinkExpiry(first, link.NodeID, panes, now.Add(communicationInactiveRetention)); !expire {
		t.Fatal("stale link did not expire at exact grace boundary")
	}
	active := communicationLinkActivity(first, now.Add(6*24*time.Hour))
	if active.InactiveSince != nil || active.LastActivityAt == nil || !active.LastActivityAt.Equal(now.Add(6*24*time.Hour)) {
		t.Fatal("verified activity did not reset stale observation")
	}
	if _, expire := communicationLinkExpiry(active, link.NodeID, panes, now.Add(communicationInactiveRetention)); expire {
		t.Fatal("verified activity inherited earlier stale grace")
	}
	if reset, expire := communicationLinkExpiry(first, link.NodeID, panes, now.Add(-time.Hour)); expire || reset.InactiveSince == nil || !reset.InactiveSince.Equal(now.Add(-time.Hour)) {
		t.Fatal("clock reversal expired a link or retained a future observation")
	}
	first.LastActivityAt = timePtr(now.Add(6 * 24 * time.Hour))
	if _, expire := communicationLinkExpiry(first, link.NodeID, panes, now.Add(communicationInactiveRetention)); expire {
		t.Fatal("last activity did not fence expiry")
	}
	first.LastActivityAt = nil
	first.UpdatedAt = now.Add(6 * 24 * time.Hour)
	if _, expire := communicationLinkExpiry(first, link.NodeID, panes, now.Add(communicationInactiveRetention)); expire {
		t.Fatal("membership update did not fence expiry")
	}
}

func timePtr(value time.Time) *time.Time { return &value }

func TestCommunicationExpiryProtectsLiveUnknownRetainedAndForeign(t *testing.T) {
	for _, change := range []string{"live", "unknown", "retained", "foreign", "ambiguous", "unknown-state"} {
		t.Run(change, func(t *testing.T) {
			link, panes, now := expiryFixture()
			link.InactiveSince = timePtr(now.Add(-30 * 24 * time.Hour))
			switch change {
			case "live":
				panes[0].State, panes[0].Recoverable = "running", true
			case "unknown":
				panes = panes[1:]
			case "retained":
				panes[0].Retained = true
			case "foreign":
				panes[0].NodeID = "another-node"
			case "ambiguous":
				panes = append(panes, panes[0])
			case "unknown-state":
				panes[0].State = "unavailable"
			}
			next, expire := communicationLinkExpiry(link, link.NodeID, panes, now)
			if expire || next.InactiveSince != nil {
				t.Fatal("protected relationship expired or kept stale grace", change)
			}
		})
	}
}

// Every history through depth six includes both maintenance and other-actor
// state changes. This checks the real policy after every operation, with no
// fake clock deadline/tolerance and no shortened production retention.
func TestCommunicationExpiryBoundedInterleavings(t *testing.T) {
	link, initial, now := expiryFixture()
	count := 0
	states := map[string]bool{}
	var visit func(communicationLink, []CatalogPane, time.Time, int)
	visit = func(link communicationLink, panes []CatalogPane, now time.Time, depth int) {
		count++
		before := link
		next, expire := communicationLinkExpiry(link, link.NodeID, panes, now)
		protected := len(panes) != 2 || panes[0].Retained || panes[0].Recoverable
		if expire && (protected || before.InactiveSince == nil || now.Before(*before.InactiveSince) || now.Sub(*before.InactiveSince) < communicationInactiveRetention ||
			before.LastActivityAt != nil && now.Sub(*before.LastActivityAt) < communicationInactiveRetention || now.Sub(before.UpdatedAt) < communicationInactiveRetention) {
			t.Fatal("EXPIRY_SAFETY: protected or recent relationship expired")
		}
		if next.ID != before.ID || next.NodeID != before.NodeID || !next.UpdatedAt.Equal(before.UpdatedAt) || !sameCommunicationExpiryTime(next.LastActivityAt, before.LastActivityAt) {
			t.Fatal("EXPIRY_OWNERSHIP: lifecycle changed membership or activity")
		}
		key, _ := json.Marshal(struct {
			Link    communicationLink
			Panes   []CatalogPane
			Now     time.Time
			Expired bool
		}{next, panes, now, expire})
		states[string(key)] = true
		if depth == 0 {
			return
		}
		for action := 0; action < 7; action++ {
			copyPanes := append([]CatalogPane(nil), initial...)
			copyLink, clock := next, now
			switch action {
			case 0: // Other actor restores worker identity.
				copyPanes[0].State, copyPanes[0].Recoverable = "running", true
			case 1: // Another complete observation confirms missing worker.
			case 2: // Partial catalogue or network uncertainty.
				copyPanes = nil
			case 3: // Upgrade owns the old pane; hold.
				copyPanes[0].Retained = true
			case 4: // Maintenance clock advances the actual retention interval.
				clock = now.Add(communicationInactiveRetention)
				copyPanes = append([]CatalogPane(nil), panes...)
			case 5: // Other actor submits a verified message or explicitly relinks.
				copyLink = communicationLinkActivity(next, now)
			case 6: // Wall clock moves backward.
				clock = now.Add(-time.Hour)
			}
			visit(copyLink, copyPanes, clock, depth-1)
		}
	}
	visit(link, initial, now, 6)
	if count != 137257 || len(states) < 100 {
		t.Fatal("bounded exploration did not run", count, len(states))
	}
	t.Logf("EXPIRY_BOUND depth=6 alphabet=7 histories=%d distinct_states=%d; revalidation planning interleavings", count, len(states))
}

func expiryStore(t *testing.T) (string, communicationLink, []CatalogPane, time.Time, string) {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	link, panes, now := expiryFixture()
	path := filepath.Join(root, "link-"+link.ID+".json")
	if err := communicationAtomic(path, link); err != nil {
		t.Fatal(err)
	}
	return root, link, panes, now, path
}

func TestCommunicationExpiryArchivesExactBytesAndRetainsReceipts(t *testing.T) {
	root, link, panes, now, path := expiryStore(t)
	snapshot := func() (CatalogSnapshot, error) { return CatalogSnapshot{Panes: panes}, nil }
	for _, name := range []string{"message-fixture.json", "events.jsonl", "caller-policy.json"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("sentinel\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := communicationMaintainLinks(root, link.NodeID, now, snapshot); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := communicationMaintainLinks(root, link.NodeID, now.Add(communicationInactiveRetention), snapshot); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("expired active membership retained", err)
	}
	archives, _ := filepath.Glob(filepath.Join(root, ".expired-*.json"))
	if len(archives) != 1 {
		t.Fatal("expiry did not retain exactly one archive", archives)
	}
	archived, err := os.ReadFile(archives[0])
	if err != nil || !bytes.Equal(raw, archived) {
		t.Fatal("expiry changed archived bytes", err)
	}
	for _, name := range []string{"message-fixture.json", "caller-policy.json"} {
		data, err := os.ReadFile(filepath.Join(root, name))
		if err != nil || string(data) != "sentinel\n" {
			t.Fatal("expiry changed receipts or caller policy", name, err)
		}
	}
	if err := communicationMaintainLinks(root, link.NodeID, now.Add(30*24*time.Hour), snapshot); err != nil {
		t.Fatal(err)
	}
	after, _ := filepath.Glob(filepath.Join(root, ".expired-*.json"))
	if len(after) != 1 {
		t.Fatal("expiry replay duplicated archive")
	}
}

func TestCommunicationExpiryRechecksRecoveryAndRelink(t *testing.T) {
	for _, change := range []string{"recover", "relink", "catalog-error"} {
		t.Run(change, func(t *testing.T) {
			root, link, panes, now, path := expiryStore(t)
			link.InactiveSince = timePtr(now.Add(-communicationInactiveRetention))
			if err := communicationAtomic(path, link); err != nil {
				t.Fatal(err)
			}
			calls := 0
			snapshot := func() (CatalogSnapshot, error) {
				calls++
				if calls == 2 {
					switch change {
					case "recover":
						panes[0].State, panes[0].Recoverable = "running", true
					case "relink":
						link = communicationLinkActivity(link, now)
						if err := communicationAtomic(path, link); err != nil {
							t.Fatal(err)
						}
					case "catalog-error":
						return CatalogSnapshot{}, errors.New("catalog unavailable")
					}
				}
				return CatalogSnapshot{Panes: panes}, nil
			}
			if err := communicationMaintainLinks(root, link.NodeID, now, snapshot); err != nil {
				t.Fatal(err)
			}
			if calls != 2 {
				t.Fatal("expiry did not revalidate catalogue before commit", calls)
			}
			if _, err := os.Stat(path); err != nil {
				t.Fatal("expiry removed recovered or changed relationship", err)
			}
			archives, _ := filepath.Glob(filepath.Join(root, ".expired-*.json"))
			if len(archives) != 0 {
				t.Fatal("recovered or changed relationship archived")
			}
		})
	}
}

func TestCommunicationExpiryPartialCatalogueAndPrivateFiles(t *testing.T) {
	root, link, panes, now, path := expiryStore(t)
	raw, _ := os.ReadFile(path)
	if err := communicationMaintainLinks(root, link.NodeID, now, func() (CatalogSnapshot, error) { return CatalogSnapshot{}, errors.New("offline") }); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(raw, after) {
		t.Fatal("catalogue failure changed link")
	}
	bad := filepath.Join(root, "link-unsafe.json")
	if err := os.Symlink(path, bad); err != nil {
		t.Fatal(err)
	}
	if err := communicationMaintainLinks(root, link.NodeID, now, func() (CatalogSnapshot, error) { return CatalogSnapshot{Panes: panes}, nil }); err == nil {
		t.Fatal("expiry accepted symlink inventory")
	}
	after, _ = os.ReadFile(path)
	if !bytes.Equal(raw, after) {
		t.Fatal("failed preflight partially changed links")
	}
}

func TestCommunicationExpiryListRouteUsesMaintenance(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	root := communicationRoot()
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	link, _, now := expiryFixture()
	link.NodeID, _ = currentNodeIdentity()
	server := NewServer()
	stored := storedCatalog{Schema: catalogSchemaVersion, Panes: map[string]CatalogPane{}}
	for _, m := range link.Members {
		stored.Panes[m.PaneID] = CatalogPane{NodeID: link.NodeID, PaneID: m.PaneID, State: "missing", UpdatedAt: now}
	}
	if err := storeCatalog(server.catalogPath(), stored); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "link-"+link.ID+".json")
	if err := communicationAtomic(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecuteCommunication(CommunicationRequest{Operation: "list"}); err != nil {
		t.Fatal(err)
	}
	var observed communicationLink
	if err := communicationRead(path, &observed); err != nil || observed.InactiveSince == nil {
		t.Fatal("list route skipped expiry maintenance", err)
	}
}

func FuzzCommunicationExpiryLink(f *testing.F) {
	link, _, _ := expiryFixture()
	raw, _ := json.Marshal(link)
	f.Add(raw)
	f.Add([]byte("null"))
	f.Add([]byte("{}"))
	f.Add(raw[:len(raw)-1])
	f.Add([]byte(`{"version":1,"version":2}`))
	f.Add(make([]byte, (128<<10)+1))
	f.Fuzz(func(t *testing.T, raw []byte) {
		decoded, ok := decodeCommunicationExpiryLink(raw, "link-"+link.ID+".json", link.NodeID)
		if !ok {
			return
		}
		if len(raw) > 128<<10 || decoded.ID != link.ID || decoded.NodeID != link.NodeID || len(decoded.Members) != 2 {
			t.Fatal("expiry decoder admitted unbounded or foreign identity")
		}
		roundtrip, err := json.Marshal(decoded)
		if err != nil {
			t.Fatal(err)
		}
		again, valid := decodeCommunicationExpiryLink(roundtrip, "link-"+decoded.ID+".json", link.NodeID)
		if !valid || again.ID != decoded.ID || !sameCommunicationExpiryTime(again.InactiveSince, decoded.InactiveSince) || !sameCommunicationExpiryTime(again.LastActivityAt, decoded.LastActivityAt) {
			t.Fatal("expiry decoder roundtrip changed lifecycle or identity")
		}
		if _, ok := decodeCommunicationExpiryLink(raw, "../link-"+decoded.ID+".json", link.NodeID); ok {
			t.Fatal("expiry decoder allowed archive path escape")
		}
	})
}

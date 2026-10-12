package daemon

import (
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func routeFixture(t *testing.T) (string, CommunicationRequest) {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	return root, CommunicationRequest{Operation: "route_set", RouteID: "reviewed-route",
		PeerNodeID: "remote-node", TransportBindingID: "reviewed-binding"}
}

func TestCommunicationRouteDurableLifecycle(t *testing.T) {
	root, r := routeFixture(t)
	result, err := communicationRouteOperation(root, "local-node", r)
	if err != nil {
		t.Fatal(err)
	}
	route := result["route"].(communicationRoute)
	if route.Revision != 1 || result["delivery_enabled"] != false || result["connectivity"] != "unverified" {
		t.Fatal(result)
	}
	if _, err := communicationRouteOperation(root, "local-node", r); err == nil {
		t.Fatal("stale revision accepted")
	}
	r.ExpectedRouteRevision = 1
	r.Operation = "route_retire"
	result, err = communicationRouteOperation(root, "local-node", r)
	if err != nil || !result["route"].(communicationRoute).Retired {
		t.Fatal(result, err)
	}
	r.ExpectedRouteRevision, r.Operation = 2, "route_set"
	result, err = communicationRouteOperation(root, "local-node", r)
	if err != nil {
		t.Fatal(err)
	}
	updated := result["route"].(communicationRoute)
	if updated.Retired || updated.Revision != 3 || !updated.CreatedAt.Equal(route.CreatedAt) {
		t.Fatal(updated)
	}
	info, err := os.Stat(filepath.Join(root, "route-reviewed-route.json"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal(info, err)
	}
	listed, err := communicationRouteOperation(root, "local-node", CommunicationRequest{Operation: "route_list"})
	if err != nil || len(listed["routes"].([]communicationRoute)) != 1 {
		t.Fatal(listed, err)
	}
	data, err := os.ReadFile(filepath.Join(root, "events.jsonl"))
	if err != nil || strings.Count(string(data), "\n") != 3 {
		t.Fatal("missing transition events", err)
	}
}

func TestCommunicationRouteRejectsUnsafeTargetsAndProviderAdmin(t *testing.T) {
	root, r := routeFixture(t)
	for _, bad := range []CommunicationRequest{
		{Operation: "route_set", RouteID: "../escape", PeerNodeID: r.PeerNodeID, TransportBindingID: r.TransportBindingID},
		{Operation: "route_set", RouteID: r.RouteID, PeerNodeID: "local-node", TransportBindingID: r.TransportBindingID},
		{Operation: "route_set", RouteID: r.RouteID, PeerNodeID: r.PeerNodeID, TransportBindingID: "/tmp/socket"},
		{Operation: "route_set", RouteID: r.RouteID, PeerNodeID: r.PeerNodeID, TransportBindingID: "$(run)"},
	} {
		if _, err := communicationRouteOperation(root, "local-node", bad); err == nil {
			t.Fatal("unsafe route accepted", bad)
		}
	}
	for _, operation := range []string{"route_set", "route_retire", "route_get", "route_list"} {
		for _, provider := range []CommunicationRequest{{Operation: operation, ClientToken: "provider-token"}, {Operation: operation, ActorPaneID: testGroupA}} {
			if _, err := communicationAuthorize(root, provider); err == nil {
				t.Fatal("provider authorized transport administration")
			}
			if _, err := communicationRouteOperation(root, "local-node", provider); err == nil {
				t.Fatal("provider bypassed route reducer guard")
			}
		}
	}
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{LegacyPaused: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationAuthorize(root, r); err == nil {
		t.Fatal("paused owner mutation accepted")
	}
	if _, err := communicationAuthorize(root, CommunicationRequest{Operation: "route_list"}); err != nil {
		t.Fatal("paused owner cannot inspect", err)
	}
}

func TestCommunicationRoutePinsPeerBindingAndNode(t *testing.T) {
	root, r := routeFixture(t)
	if _, err := communicationRouteOperation(root, "local-node", r); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"peer", "binding"} {
		bad := r
		bad.ExpectedRouteRevision = 1
		if field == "peer" {
			bad.PeerNodeID = "other-peer"
		} else {
			bad.TransportBindingID = "other-binding"
		}
		if _, err := communicationRouteOperation(root, "local-node", bad); err == nil {
			t.Fatal("route target repointed", field)
		}
	}
	duplicate := r
	duplicate.RouteID = "duplicate-route"
	if _, err := communicationRouteOperation(root, "local-node", duplicate); err == nil {
		t.Fatal("duplicate active peer accepted")
	}
	for _, operation := range []string{"route_get", "route_list"} {
		if _, err := communicationRouteOperation(root, "other-node", CommunicationRequest{Operation: operation, RouteID: r.RouteID}); err == nil {
			t.Fatal("foreign node record accepted")
		}
	}
	var stored communicationRoute
	path := filepath.Join(root, "route-reviewed-route.json")
	if err := communicationRead(path, &stored); err != nil {
		t.Fatal(err)
	}
	stored.Revision = math.MaxUint64
	if err := communicationAtomic(path, stored); err != nil {
		t.Fatal(err)
	}
	r.ExpectedRouteRevision = math.MaxUint64
	if _, err := communicationRouteOperation(root, "local-node", r); err == nil {
		t.Fatal("revision overflow accepted")
	}
}

func TestCommunicationRouteRejectsCorruptAndExcessCatalogue(t *testing.T) {
	root, r := routeFixture(t)
	if _, err := communicationRouteOperation(root, "local-node", r); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "route-corrupt.json"), []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationReadRoutes(root, "local-node"); err == nil {
		t.Fatal("corrupt record accepted")
	}
	if err := os.Remove(filepath.Join(root, "route-corrupt.json")); err != nil {
		t.Fatal(err)
	}
	var route communicationRoute
	if err := communicationRead(filepath.Join(root, "route-reviewed-route.json"), &route); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < communicationMaxRoutes; i++ {
		// Retired records still consume the bound and preserve history.
		// Keep tokens within the daemon's session grammar.
		route.ID = testGroupID[:30] + string(rune('a'+i/26)) + string(rune('a'+i%26))
		route.Retired = true
		if err := communicationAtomic(filepath.Join(root, "route-"+route.ID+".json"), route); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := communicationReadRoutes(root, "local-node"); err == nil {
		t.Fatal("excess catalogue accepted")
	}
}

package desktoproute

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// baseRouteEvent and baseParseEvent copy the routeEvent struct and the ready
// branch of parseEvent exactly as they are at base dc2df26, so a frame from
// this build is proven to decode for an older local.
type baseRouteEvent struct {
	Type    string `json:"type"`
	State   string `json:"state"`
	Message string `json:"message"`
	ID      string `json:"id"`
	Sender  string `json:"sender"`
	Content string `json:"content"`
	Session string `json:"session"`
	PID     int    `json:"pid"`
	Start   string `json:"start"`
	Name    string `json:"name"`
	Drain   int    `json:"drain"`
}

func baseParseEvent(raw []byte) (baseRouteEvent, error) {
	var e baseRouteEvent
	if err := decodeJSON(raw, 131072, &e); err != nil {
		return e, err
	}
	switch e.Type {
	case "ready":
		if e.PID <= 1 || e.Start == "" || !identifier.MatchString(e.Name) {
			return e, errors.New("invalid ready event")
		}
	case "heartbeat", "identity_missing", "identity_changed", "identity_replacement", "transport_status", "rejected":
	default:
		return e, errors.New("unknown route event")
	}
	return e, nil
}

// readyFrame runs a real listener for the owner fixture and returns its first
// ready frame, as this build emits it.
func readyFrame(t *testing.T) []byte {
	t.Helper()
	home := privateTemp(t)
	acct := privateTemp(t)
	r, _ := ownerInAccount(t, home, acct, 123, "session")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	var out bytes.Buffer
	_ = r.run(ctx, []string{"listen", "123", "session", testOwnerStart, "reply"}, bytes.NewReader(nil), &out)
	for _, line := range bytes.Split(out.Bytes(), []byte("\n")) {
		if strings.Contains(string(line), `"type":"ready"`) {
			return line
		}
	}
	t.Fatalf("no ready frame: %s", out.String())
	return nil
}

func TestNewReadyFrameDecodesOnBaseParser(t *testing.T) {
	frame := readyFrame(t)
	if !strings.Contains(string(frame), `"account"`) {
		t.Fatalf("ready frame carries no account: %s", frame)
	}
	event, err := baseParseEvent(frame)
	if err != nil || event.Type != "ready" || event.PID <= 1 || event.Start == "" {
		t.Fatalf("base parser rejects new ready frame %s: %+v, %v", frame, event, err)
	}
}

// An older remote's ready frame has no account: the local skips the backfill
// and sends no account back.
func TestOldReadyFrameWithoutAccountIsSkipped(t *testing.T) {
	home := privateTemp(t)
	path := filepath.Join(home, "route.json")
	c := testRoute(home)
	if err := atomicJSON(path, c); err != nil {
		t.Fatal(err)
	}
	frame := []byte(`{"type":"ready","pid":4321,"start":"` + testOwnerStart + `","name":"relay-route","peer":"reply","drain":1}`)
	event, err := parseEvent(frame)
	if err != nil {
		t.Fatalf("new parser rejects old ready frame: %v", err)
	}
	updated, known, err := readyAccount(c, path, event)
	if err != nil || known || updated != c {
		t.Fatalf("old ready frame changed the route: %+v known %v, %v", updated, known, err)
	}
}

// The recorded account is an extra listen argument only for a remote known to
// accept it. Without that, the argv is the base five-element form an older
// remote accepts.
func TestRecordedAccountSentOnlyToKnownRemote(t *testing.T) {
	home := privateTemp(t)
	c := testRoute(home)
	c.RemoteAccount = privateTemp(t)
	r := &runtime{home: home}
	unknown := r.remoteArgs(listenConfig(c, false), "listen", nil)
	if len(unknown) != 7 {
		t.Fatalf("unknown remote got %d listen args, want base 7: %q", len(unknown), unknown)
	}
	known := r.remoteArgs(listenConfig(c, true), "listen", nil)
	if len(known) != 8 || known[7] != c.RemoteAccount {
		t.Fatalf("known remote args = %q", known)
	}
}

// A new ready frame from the exact owner backfills the account once.
func TestNewReadyFrameBackfillsAccount(t *testing.T) {
	home := privateTemp(t)
	acct := privateTemp(t)
	path := filepath.Join(home, "route.json")
	c := testRoute(home)
	if err := atomicJSON(path, c); err != nil {
		t.Fatal(err)
	}
	event := routeEvent{Type: "ready", PID: 4321, Start: testOwnerStart, Name: "relay-route", Account: acct}
	updated, known, err := readyAccount(c, path, event)
	if err != nil || !known || updated.RemoteAccount != acct {
		t.Fatalf("new ready frame: %+v known %v, %v", updated, known, err)
	}
}

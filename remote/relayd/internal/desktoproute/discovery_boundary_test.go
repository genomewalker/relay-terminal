package desktoproute

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/websocket"
)

func TestDiscoveryWorkLegacyBoundary(t *testing.T) {
	cases := []struct {
		name    string
		saved   bool
		ids     []string
		private bool
		wantErr bool
		wantID  string
	}{
		{"stale_work_legacy_empty", true, []string{}, false, true, ""},
		{"no_saved_work_legacy_empty", false, []string{}, false, true, ""},
		{"stale_same_id_conflict", true, []string{"same"}, false, true, ""},
		{"stale_work_other_legacy", true, []string{"other"}, false, false, "other"},
		{"no_saved_live_legacy", false, []string{"same"}, false, false, "same"},
		{"private_legacy_empty", false, []string{}, true, false, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			home := privateTemp(t)
			d := &nativeDesktop{home: home, inspect: func(int) (processInfo, error) { return processInfo{}, errors.New("fixture stale process") }}
			path := d.legacySocket()
			if tc.private {
				path = filepath.Join(home, "private.sock")
			}
			if tc.saved {
				if err := privateDirectory(d.workRoot(), true); err != nil {
					t.Fatal(err)
				}
				ref := workReference{Schema: 1, Thread: "same", Host: "local", Socket: d.workSocket(), AppPath: workApp, PID: 1234, Start: "Mon Jan 1 00:00:00 2024", Owner: "11111111-1111-4111-8111-111111111111"}
				if err := atomicJSON(filepath.Join(d.workRoot(), "same.json"), ref); err != nil {
					t.Fatal(err)
				}
			}
			var starts atomic.Int32
			listener := unixFixture(t, path)
			server := http.Server{Handler: websocket.Handler(func(ws *websocket.Conn) {
				defer ws.Close()
				for {
					var raw []byte
					if websocket.Message.Receive(ws, &raw) != nil {
						return
					}
					var req struct {
						ID     int    `json:"id"`
						Method string `json:"method"`
					}
					if json.Unmarshal(raw, &req) != nil {
						return
					}
					var result any
					switch req.Method {
					case "initialize":
						result = map[string]any{}
					case "thread/loaded/list":
						result = map[string]any{"data": tc.ids}
					case "thread/read":
						result = map[string]any{"thread": map[string]any{"id": tc.wantID, "name": "fixture", "status": map[string]string{"type": "active"}}}
					case "turn/start":
						starts.Add(1)
						result = map[string]any{"turn": map[string]string{"id": "unexpected"}}
					default:
						t.Errorf("unexpected method %q", req.Method)
						return
					}
					response, _ := json.Marshal(map[string]any{"id": req.ID, "result": result})
					if websocket.Message.Send(ws, string(response)) != nil {
						return
					}
				}
			})}
			go server.Serve(listener)
			t.Cleanup(func() { server.Close() })
			for _, details := range []bool{false, true} {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				rows, err := d.tasks(ctx, path, details)
				cancel()
				if tc.wantErr {
					want := errDesktopDiscoveryIncomplete
					if tc.name == "stale_same_id_conflict" {
						want = errDesktopIdentityConflict
					}
					if !errors.Is(err, want) {
						t.Errorf("details=%v expected %v, got rows=%v err=%v", details, want, rows, err)
					}
					var detail discoveryFailure
					if !errors.As(err, &detail) {
						t.Errorf("missing bounded diagnostic: %v", err)
					} else {
						work := workNoSaved
						if tc.saved {
							work = workSavedUnverified
						}
						legacy := legacyEmpty
						if tc.name == "stale_same_id_conflict" {
							legacy = legacyIdentityConflict
						}
						if detail != (discoveryFailure{work, legacy}) {
							t.Errorf("wrong diagnostic %+v", detail)
						}
					}
					continue
				}
				if err != nil {
					t.Errorf("details=%v unexpected %v", details, err)
					continue
				}
				if tc.wantID == "" {
					if len(rows) != 0 {
						t.Errorf("expected valid empty private list, got %v", rows)
					}
				} else if len(rows) != 1 || rows[0].ID != tc.wantID {
					t.Errorf("expected exact live legacy %s, got %v", tc.wantID, rows)
				}
			}
			if tc.name == "stale_same_id_conflict" {
				refPath := filepath.Join(d.workRoot(), "same.json")
				before, err := os.ReadFile(refPath)
				if err != nil {
					t.Fatal(err)
				}
				for _, prepare := range []bool{false, true} {
					if _, err := d.Inspect(context.Background(), path, "same", prepare); err == nil {
						t.Error("stale Work pin silently changed transport")
					}
				}
				if err := d.Verify(context.Background(), path, "same"); err == nil {
					t.Error("stale Work pin was verified")
				}
				result := d.Deliver(context.Background(), path, "same", Envelope{ID: "fixture-message", Sender: "fixture", Content: "fixture"})
				if result.Receipt != "not_sent" || starts.Load() != 0 {
					t.Errorf("unexpected delivery: %+v starts=%d", result, starts.Load())
				}
				after, err := os.ReadFile(refPath)
				if err != nil || !bytes.Equal(before, after) {
					t.Error("endpoint reference changed during conflict")
				}
			}
		})
	}
}

func TestDiscoveryUnavailableDoesNotExposeFilesystemDetails(t *testing.T) {
	for _, saved := range []bool{false, true} {
		t.Run(fmt.Sprintf("saved_%v", saved), func(t *testing.T) {
			home := privateTemp(t)
			d := &nativeDesktop{home: home, inspect: func(int) (processInfo, error) { return processInfo{}, errors.New("secret fixture") }}
			if saved {
				if err := privateDirectory(d.workRoot(), true); err != nil {
					t.Fatal(err)
				}
				ref := workReference{Schema: 1, Thread: "same", Host: "local", Socket: d.workSocket(), AppPath: workApp, PID: 1234, Start: "Mon Jan 1 00:00:00 2024", Owner: "11111111-1111-4111-8111-111111111111"}
				if err := atomicJSON(filepath.Join(d.workRoot(), "same.json"), ref); err != nil {
					t.Fatal(err)
				}
			}
			_, err := d.tasks(context.Background(), d.legacySocket(), true)
			expected := "relay-desktop-discovery-go-v1:no_saved_work_refs:unavailable"
			if saved {
				expected = "relay-desktop-discovery-go-v1:saved_work_unverified:unavailable"
			}
			if err == nil || err.Error() != expected || !errors.Is(err, errDesktopDiscoveryIncomplete) {
				t.Fatalf("unsafe diagnostic %v", err)
			}
		})
	}
	home := privateTemp(t)
	d := &nativeDesktop{home: home, inspect: inspectProcess}
	if err := os.MkdirAll(d.workRoot(), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(d.workRoot(), 0755); err != nil {
		t.Fatal(err)
	}
	_, err := d.tasks(context.Background(), d.legacySocket(), true)
	if err == nil || err.Error() != "relay-desktop-discovery-go-v1:work_discovery_unavailable:not_checked" {
		t.Fatalf("unsafe registry result %v", err)
	}
}

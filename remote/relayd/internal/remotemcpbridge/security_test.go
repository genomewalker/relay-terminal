package remotemcpbridge

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func fixtureBridge() (*Bridge, *int) {
	writes := 0
	return New("dandy-07", "fixture", func(_ context.Context, m, p string, _ []byte, _ string) (int, []byte, error) {
		if p == "/api/state" {
			return 200, encode(baseState()), nil
		}
		if m == "POST" && p != "/api/workspace/context" {
			writes++
		}
		return 200, []byte(`{"status":"fixture_only"}`), nil
	}), &writes
}
func TestBridgeAuthorizationSequences(t *testing.T) {
	histories, transitions := 0, 0
	for history := 0; history < 1296; history++ {
		b, writes := fixtureBridge()
		seen := map[string]bool{}
		expectedWrites := 0
		value := history
		for depth := 0; depth < 4; depth++ {
			op := value % 6
			value /= 6
			id := requestID
			method, path, token, payload := "GET", "/api/input-receipts/"+id, "fixture", any(nil)
			want := 403
			switch op {
			case 0:
				method = "POST"
				path = "/api/panes/" + targetPane + "/input-direct"
				token = "wrong"
				payload = map[string]any{"requestID": id}
				want = 401
			case 1, 2:
				if op == 2 {
					id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
				}
				method = "POST"
				path = "/api/panes/" + targetPane + "/input-direct"
				payload = map[string]any{"requestID": id}
				seen[id] = true
				expectedWrites++
				want = 200
			case 3, 4:
				if op == 4 {
					id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
					path = "/api/input-receipts/" + id
				}
				if seen[id] {
					want = 200
				}
			case 5:
				method = "POST"
				path = "/api/panes/" + foreignPane + "/input-direct"
				payload = map[string]any{"requestID": id}
			}
			got, _ := request(b, method, path, payload, token, "fixture_client")
			if got != want || *writes != expectedWrites || len(b.receipts) != len(seen) {
				t.Fatalf("bounded authority history=%d step=%d status %d/%d writes %d/%d receipts %d/%d", history, depth, got, want, *writes, expectedWrites, len(b.receipts), len(seen))
			}
			transitions++
		}
		histories++
	}
	t.Logf("real Bridge.Handle: depth4,6ops,%d histories,%d transitions", histories, transitions)
}
func TestBridgeTwoActorReceiptCap(t *testing.T) {
	for _, order := range [][4]int{{0, 0, 1, 1}, {0, 1, 0, 1}, {0, 1, 1, 0}, {1, 0, 0, 1}, {1, 0, 1, 0}, {1, 1, 0, 0}} {
		b, _ := fixtureBridge()
		for i := 0; i < 511; i++ {
			b.receipts[fmt.Sprint(i)] = true
		}
		steps := [2]int{}
		admitted := [2]bool{}
		ids := [2]string{requestID, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}
		for _, actor := range order {
			id := ids[actor]
			if steps[actor] == 0 {
				status, _ := request(b, "POST", "/api/panes/"+targetPane+"/input-direct", map[string]any{"requestID": id}, "fixture", "fixture_client")
				if status != 200 && status != 429 {
					t.Fatal("unexpected cap status")
				}
				admitted[actor] = status == 200
			} else {
				status, _ := request(b, "GET", "/api/input-receipts/"+id, nil, "fixture", "fixture_client")
				if (status == 200) != admitted[actor] {
					t.Fatal("receipt disclosure across rejected send")
				}
			}
			if len(b.receipts) > 512 {
				t.Fatal("receipt cap exceeded")
			}
			steps[actor]++
		}
		if admitted[0] == admitted[1] {
			t.Fatal("capacity must admit exactly one actor")
		}
	}
	t.Log("two actors, send/read each: all6interleavings,24transitions")
}
func TestBridgeConcurrentReceiptCap(t *testing.T) {
	b := New("dandy-07", "fixture", func(_ context.Context, m, p string, _ []byte, _ string) (int, []byte, error) {
		if p == "/api/state" {
			return 200, encode(baseState()), nil
		}
		return 200, []byte(`{}`), nil
	})
	for i := 0; i < 511; i++ {
		b.receipts[fmt.Sprint(i)] = true
	}
	start := make(chan struct{})
	codes := make(chan int, 2)
	var wg sync.WaitGroup
	for _, id := range []string{requestID, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"} {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			<-start
			s, _ := request(b, "POST", "/api/panes/"+targetPane+"/input-direct", map[string]any{"requestID": id}, "fixture", "fixture_client")
			codes <- s
		}(id)
	}
	close(start)
	wg.Wait()
	close(codes)
	count := 0
	for code := range codes {
		if code == 200 {
			count++
		} else if code != 429 {
			t.Fatal(code)
		}
	}
	if count != 1 || len(b.receipts) != 512 {
		t.Fatal("concurrent receipt capacity breached")
	}
}
func TestCapabilityFile(t *testing.T) {
	home := t.TempDir()
	token, e := LoadCapability(home, "dandy-07", 48473)
	if e != nil || len(token) < 32 {
		t.Fatalf("capability create: %v", e)
	}
	again, e := LoadCapability(home, "dandy-07", 48473)
	if e != nil || again != token {
		t.Fatal("capability not stable")
	}
	for _, host := range []string{"../outside", ".", "..", "a/b", "x\x00y", strings.Repeat("x", 129)} {
		if _, e := LoadCapability(home, host, 48473); e == nil {
			t.Fatal("host path traversal accepted")
		}
	}
	path := filepath.Join(home, ".local/share/relay/remote-mcp/dandy-07.json")
	_ = os.Chmod(path, 0644)
	if _, e = LoadCapability(home, "dandy-07", 48473); e == nil {
		t.Fatal("public capability accepted")
	}
	_ = os.Chmod(path, 0600)
	_ = os.Rename(path, path+".saved")
	_ = os.Symlink(path+".saved", path)
	if _, e = LoadCapability(home, "dandy-07", 48473); e == nil {
		t.Fatal("capability symlink accepted")
	}
	_ = os.Remove(path)
	_ = os.WriteFile(path, bytes.Repeat([]byte{'x'}, 4097), 0600)
	if _, e = LoadCapability(home, "dandy-07", 48473); e == nil {
		t.Fatal("oversized capability accepted")
	}
}
func TestHTTPDesktopAndSurface(t *testing.T) {
	called := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called++
		if r.Header.Get("x-relay-token") != "desktop-private" || r.Header.Get("X-Relay-Caller-Token") != "caller-safe" || r.URL.Path != "/api/example" || r.Method != "POST" {
			t.Error("desktop credential/caller/path/method mismatch")
		}
		raw, _ := io.ReadAll(r.Body)
		if string(raw) != "{}" {
			t.Error("body changed")
		}
		w.WriteHeader(409)
		_, _ = w.Write([]byte(`{"rejected":true}`))
	}))
	defer server.Close()
	d := HTTPDesktop{URL: server.URL, Token: func(context.Context) (string, error) { return "desktop-private", nil }}
	status, raw, e := d.Call(context.Background(), "POST", "/api/example", []byte(`{}`), "caller-safe")
	if e != nil || status != 409 || !strings.Contains(string(raw), "rejected") || called != 1 {
		t.Fatal("HTTP forwarding contract")
	}
	b, _ := fixtureBridge()
	w := httptest.NewRecorder()
	r := httptest.NewRequest("PUT", "/api/state", nil)
	b.ServeHTTP(w, r)
	if w.Code != 501 {
		t.Fatal("unsupported HTTP method accepted")
	}
	w = httptest.NewRecorder()
	r = httptest.NewRequest("GET", "/api/state", nil)
	r.Header.Set("x-relay-token", "fixture")
	b.ServeHTTP(w, r)
	if w.Code != 200 || w.Header().Get("Content-Type") != "application/json" {
		t.Fatal("HTTP state surface")
	}
}
func TestDesktopResponseBounds(t *testing.T) {
	b := New("dandy-07", "fixture", func(_ context.Context, m, p string, _ []byte, _ string) (int, []byte, error) {
		if p == "/api/state" {
			return 200, encode(baseState()), nil
		}
		return 200, bytes.Repeat([]byte{'x'}, ResponseLimit+1), nil
	})
	status, _ := request(b, "GET", "/api/control", nil, "fixture", "")
	if status != 403 {
		t.Fatal("empty caller must be rejected")
	}
	r := httptest.NewRequest("GET", "/api/control", nil)
	r.Header.Set("x-relay-token", "fixture")
	status, _ = b.Handle(r)
	if status != 502 {
		t.Fatal("oversized response accepted")
	}
}
func FuzzBridgeRequests(f *testing.F) {
	f.Add([]byte(`{"requestID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}`), "/api/panes/"+foreignPane+"/input-direct")
	f.Add([]byte(`[]`), "/api/workspace/context")
	f.Add([]byte(`{}`), "/api/network/request")
	f.Fuzz(func(t *testing.T, raw []byte, path string) {
		if len(raw) > 70001 || len(path) > 4096 {
			return
		}
		_, _ = decode(raw)
		b, writes := fixtureBridge()
		r := httptest.NewRequest("POST", "/api/panes/"+foreignPane+"/input-direct", bytes.NewReader(raw))
		r.Header.Set("x-relay-token", "fixture")
		status, _ := b.Handle(r)
		if status != 403 || *writes != 0 || len(b.receipts) != 0 {
			t.Fatal("foreign write or receipt escaped scope")
		}
		r = httptest.NewRequest("POST", "/api/panes/"+targetPane+"/input-direct", bytes.NewReader(raw))
		r.Header.Set("x-relay-token", "wrong")
		status, _ = b.Handle(r)
		if status != 401 || *writes != 0 {
			t.Fatal("unauthorized body reached executor")
		}
		if idRoute(path, "/api/input-receipts/") && (!strings.HasPrefix(path, "/api/input-receipts/") || strings.Contains(strings.TrimPrefix(path, "/api/input-receipts/"), "/")) {
			t.Fatal("receipt route escaped path")
		}
	})
}

func TestHTTPRedirectDoesNotForwardCredentials(t *testing.T) {
	leaked := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked = true }))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, http.StatusFound) }))
	defer source.Close()
	d := HTTPDesktop{URL: source.URL, Token: func(context.Context) (string, error) { return "private", nil }}
	status, _, e := d.Call(context.Background(), "GET", "/api/state", nil, "caller")
	if e != nil || status != 302 || leaked {
		t.Fatal("desktop credentials followed redirect")
	}
}

func TestJSONRejectsInvalidUTF8(t *testing.T) {
	if _, e := decode([]byte{'{', '"', 'x', '"', ':', '"', 255, '"', '}'}); e == nil {
		t.Fatal("invalid UTF8 JSON accepted")
	}
}

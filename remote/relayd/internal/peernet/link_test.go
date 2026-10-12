package peernet

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFailedDeliveryNeverBecomesDuplicate(t *testing.T) {
	seen := make(map[string]string)
	writes := 0
	write := func() error {
		writes++
		return errors.New("recipient socket unavailable")
	}
	for attempt := 0; attempt < 2; attempt++ {
		status, err := deliveryStatus(seen, "lost-id", write)
		if status != "failed" {
			t.Fatalf("attempt %d reported %q instead of failed", attempt, status)
		}
		if attempt == 0 && err == nil {
			t.Fatal("first failed write lost its error")
		}
	}
	if writes != 1 {
		t.Fatalf("ambiguous write retried %d times", writes)
	}
	status, err := deliveryStatus(seen, "delivered-id", func() error { writes++; return nil })
	if status != "socket-written" || err != nil {
		t.Fatalf("first successful write: %q, %v", status, err)
	}
	status, err = deliveryStatus(seen, "delivered-id", func() error { writes++; return nil })
	if status != "duplicate" || err != nil || writes != 2 {
		t.Fatalf("successful duplicate: %q, %v, writes=%d", status, err, writes)
	}
}

func TestEndpointIncarnation(t *testing.T) {
	target := Record{PID: 42, Name: "agent", Session: "session", Socket: "/tmp/peer.sock", Start: "start-1"}
	if !sameEndpoint(target, target) {
		t.Fatal("rejected original endpoint")
	}
	for _, change := range []func(*Record){
		func(r *Record) { r.Start = "start-2" },
		func(r *Record) { r.Start = "" },
		func(r *Record) { r.PID++ },
		func(r *Record) { r.Name = "other" },
		func(r *Record) { r.Session = "other" },
		func(r *Record) { r.Socket = "/tmp/other.sock" },
	} {
		current := target
		change(&current)
		if sameEndpoint(current, target) {
			t.Fatal("accepted replacement endpoint")
		}
	}
}

func TestNativeValidation(t *testing.T) {
	for _, tc := range []struct {
		name, token, from, id, body string
		ok                          bool
	}{
		{"valid", "secret", "uds:/peer", "id-1", "hello", true},
		{"bad-token", "wrong", "uds:/peer", "id-1", "hello", false},
		{"wrong-sender", "secret", "uds:/other", "id-1", "hello", false},
		{"bad-id", "secret", "uds:/peer", "../id", "hello", false},
		{"empty", "secret", "uds:/peer", "id-1", "", false},
		{"large", "secret", "uds:/peer", "id-1", strings.Repeat("x", 32769), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a, b := net.Pipe()
			defer a.Close()
			defer b.Close()
			var out bytes.Buffer
			done := make(chan error, 1)
			go func() { defer a.Close(); done <- acceptNative(a, "secret", Record{Socket: "/peer"}, &wire{out: &out}) }()
			enc := json.NewEncoder(b)
			_ = enc.Encode(map[string]string{"type": "auth", "token": tc.token})
			_ = enc.Encode(map[string]any{"type": "user", "from": tc.from, "msg_id": tc.id, "message": map[string]string{"content": tc.body}})
			e := <-done
			if (e == nil) != tc.ok {
				t.Fatalf("result %v", e)
			}
			if tc.ok {
				var f frame
				if e = json.Unmarshal(out.Bytes(), &f); e != nil || f.Type != "message" || f.Body != "hello" {
					t.Fatalf("frame %s", out.Bytes())
				}
			}
		})
	}
}
func TestFrameBound(t *testing.T) {
	for _, s := range []string{strings.Repeat("x", MaxFrame+1) + "\n", "unterminated"} {
		if _, e := line(bufio.NewReaderSize(strings.NewReader(s), MaxFrame+1)); e == nil {
			t.Fatal("accepted bad frame")
		}
	}
}
func TestPrivateFiles(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "key")
	if e := os.WriteFile(p, []byte("x"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e := readPrivate(p, 10); e != nil {
		t.Fatal(e)
	}
	alias := filepath.Join(d, "alias")
	if e := os.Symlink(p, alias); e != nil {
		t.Fatal(e)
	}
	if _, e := readPrivate(alias, 10); e == nil {
		t.Fatal("accepted symlink")
	}
	if e := os.Chmod(p, 0666); e != nil {
		t.Fatal(e)
	}
	if _, e := readPrivate(p, 10); e == nil {
		t.Fatal("accepted writable key")
	}
}

func TestRegistrationPinsIdentityAndCleansUp(t *testing.T) {
	home := t.TempDir()
	// macOS socket paths are short; Go's test directory may exceed sun_path.
	dir, err := os.MkdirTemp("/tmp", "relay-peer-unit-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sock := filepath.Join(dir, "p.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	r, err := register(home, sock, "test-peer", "test-session")
	if err != nil {
		t.Fatal(err)
	}
	defer r.close()
	if len(r.secret) != 32 {
		t.Fatal("peer token incompatible with Claude's 32-hex schema")
	}
	got, err := Resolve(home, "test-peer", "test-session", os.Getpid())
	if err != nil || got.Socket != sock {
		t.Fatalf("resolve: %+v %v", got, err)
	}
	if _, err = Resolve(home, "other-peer", "test-session", os.Getpid()); err == nil {
		t.Fatal("accepted wrong name")
	}
	if _, err = Resolve(home, "test-peer", "other-session", os.Getpid()); err == nil {
		t.Fatal("accepted wrong session")
	}
	if _, err = register(home, sock, "replacement", "replacement"); err == nil {
		t.Fatal("replaced existing registry")
	}
	r.value["procStart"] = "wrong-start"
	if err = r.refresh(); err != nil {
		t.Fatal(err)
	}
	if _, err = Resolve(home, "test-peer", "test-session", os.Getpid()); err == nil {
		t.Fatal("accepted reused PID")
	}
	r.close()
	for _, path := range []string{r.record, r.key, r.socket} {
		if _, err = os.Lstat(path); !os.IsNotExist(err) {
			t.Fatalf("cleanup failed: %s", path)
		}
	}
}

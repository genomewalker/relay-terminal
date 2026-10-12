package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestNativeClaudeParkedPairGuards(t *testing.T) {
	front := nativeClaudeRegistration{PID: 123, Kind: "interactive", Entrypoint: "cli",
		SessionID: "009f406d-c23a-483c-b212-3f4e7461be26", ParkedJobID: "5577ee9d", PIDDomain: "native-domain"}
	bg := nativeClaudeRegistration{PID: 456, Kind: "bg", Entrypoint: "cli",
		SessionID: "5577ee9d-5e02-4ca8-b208-74360e3f65d1", JobID: "5577ee9d", PIDDomain: "native-domain"}
	if err := nativeClaudeParkedPair(front, bg); err != nil {
		t.Fatal(err)
	}
	for name, change := range map[string]func(*nativeClaudeRegistration, *nativeClaudeRegistration){
		"wrong job":       func(a, b *nativeClaudeRegistration) { b.JobID = "aaaaaaaa" },
		"unsafe job":      func(a, b *nativeClaudeRegistration) { a.ParkedJobID = "../bad"; b.JobID = a.ParkedJobID },
		"wrong domain":    func(a, b *nativeClaudeRegistration) { b.PIDDomain = "other" },
		"same process":    func(a, b *nativeClaudeRegistration) { b.PID = a.PID },
		"foreground kind": func(a, b *nativeClaudeRegistration) { a.Kind = "bg" },
		"background kind": func(a, b *nativeClaudeRegistration) { b.Kind = "interactive" },
		"proxy":           func(a, b *nativeClaudeRegistration) { b.RelayProxy = true },
		"sdk":             func(a, b *nativeClaudeRegistration) { b.Entrypoint = "sdk" },
		"invalid session": func(a, b *nativeClaudeRegistration) { b.SessionID = "../../session" },
	} {
		t.Run(name, func(t *testing.T) {
			a, b := front, bg
			change(&a, &b)
			if nativeClaudeParkedPair(a, b) == nil {
				t.Fatal("unsafe attachment accepted")
			}
		})
	}
}

func TestNativeClaudeBackgroundRegistrationGuards(t *testing.T) {
	dir := t.TempDir()
	_ = os.Chmod(dir, 0700)
	p := filepath.Join(dir, "123.json")
	row := nativeClaudeRegistration{PID: 123, ProcessStart: "expected", Kind: "bg", Entrypoint: "cli",
		SessionID: "5577ee9d-5e02-4ca8-b208-74360e3f65d1", JobID: "5577ee9d", PeerProtocol: 1,
		PIDDomain: nativeClaudePIDDomain(), Socket: filepath.Join(dir, "peer.sock")}
	data, _ := json.Marshal(row)
	_ = os.WriteFile(p, data, 0600)
	if _, _, _, err := readNativeClaudeRegistrationKind(p, 123, "expected", "bg"); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := readNativeClaudeRegistration(p, 123, "expected"); err == nil {
		t.Fatal("background accepted as interactive")
	}
	if _, _, _, err := readNativeClaudeRegistrationKind(p, 123, "different", "bg"); err == nil {
		t.Fatal("stale background accepted")
	}
}

func TestNativeClaudeContinuationGuards(t *testing.T) {
	dir := t.TempDir()
	_ = os.Chmod(dir, 0700)
	p := filepath.Join(dir, "conversation.jsonl")
	old := "009f406d-c23a-483c-b212-3f4e7461be26"
	next := "5577ee9d-5e02-4ca8-b208-74360e3f65d1"
	row := func(kind, session, target string) string {
		data, _ := json.Marshal(map[string]string{"type": kind, "sessionId": session, "continuedInSessionId": target})
		return string(data) + "\n"
	}
	_ = os.WriteFile(p, []byte(row("assistant", old, "invented")+row("continued-in", old, next)), 0600)
	if got, err := nativeClaudeNextSession(p, old); err != nil || got != next {
		t.Fatal(got, err)
	}
	_ = os.WriteFile(p, []byte(row("continued-in", old, next)+row("continued-in", old, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")), 0600)
	if _, err := nativeClaudeNextSession(p, old); err == nil {
		t.Fatal("ambiguous continuation accepted")
	}
	_ = os.WriteFile(p, []byte(row("continued-in", old, old)), 0600)
	if _, err := nativeClaudeNextSession(p, old); err == nil {
		t.Fatal("cyclic continuation accepted")
	}
	_ = os.Chmod(p, 0664)
	if _, err := nativeClaudeNextSession(p, old); err == nil {
		t.Fatal("writable continuation accepted")
	}
}

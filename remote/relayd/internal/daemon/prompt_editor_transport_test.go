package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func promptEditorTestTransport(t *testing.T) (*Session, PromptOwnerBinding, func(string, promptEditorRequest) promptEditorResponse) {
	t.Helper()
	return promptEditorTestTransportConfigured(t, nil)
}

func promptEditorTestTransportConfigured(t *testing.T, configure func(PromptOwnerBinding) (func() (PromptOwnerBinding, error), func(PromptOwnerBinding) error)) (*Session, PromptOwnerBinding, func(string, promptEditorRequest) promptEditorResponse) {
	t.Helper()
	root, err := os.MkdirTemp("", "relay-pedit-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	path := filepath.Join(root, "test.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	owner := promptEditorTestOwner()
	owner.ProcessID = os.Getpid()
	owner.ProcessStart, err = processStartTime(owner.ProcessID)
	if err != nil {
		t.Fatal(err)
	}
	readOwner := func() (PromptOwnerBinding, error) { return owner, nil }
	validateBridge := func(PromptOwnerBinding) error { return nil }
	if configure != nil {
		readOwner, validateBridge = configure(owner)
	}
	session := &Session{}
	if !session.acquireControl("controller") {
		t.Fatal("test control unavailable")
	}
	t.Cleanup(func() {
		session.promptEditorMu.Lock()
		defer session.promptEditorMu.Unlock()
		if p := session.promptEditor; p != nil {
			p.transaction.cancel()
			p.timer.Stop()
		}
	})
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer connection.Close()
				frame, err := protocol.ReadFrame(connection)
				if err != nil {
					return
				}
				var hello protocol.HelloPayload
				if protocol.DecodeJSON(frame, &hello) != nil {
					return
				}
				servePromptEditorRequest(connection, protocol.NewWriter(connection), hello, session,
					readOwner, validateBridge)
			}()
		}
	}()
	rpc := func(client string, request promptEditorRequest) promptEditorResponse {
		connection, err := net.DialTimeout("unix", path, time.Second)
		if err != nil {
			return promptEditorResponse{State: "transport_error", Message: err.Error()}
		}
		defer connection.Close()
		_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
		raw, _ := json.Marshal(request)
		frame, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{ClientID: client, PromptEditor: raw})
		if err := protocol.NewWriter(connection).Write(frame); err != nil {
			return promptEditorResponse{State: "transport_error", Message: err.Error()}
		}
		frame, err = protocol.ReadFrame(connection)
		var response promptEditorResponse
		if err != nil || protocol.DecodeJSON(frame, &response) != nil {
			return promptEditorResponse{State: "transport_error"}
		}
		return response
	}
	return session, owner, rpc
}

func TestPromptEditorTransportExactDraftAndLease(t *testing.T) {
	_, owner, rpc := promptEditorTestTransport(t)
	id := "0123456789abcdef0123456789abcdef"
	request := promptEditorRequest{Operation: "arm", ID: id, Owner: owner}
	if response := rpc("foreign", request); response.State != "refused" {
		t.Fatalf("foreign lease admitted: %s", response.State)
	}
	if response := rpc("controller", request); response.State != "armed" {
		t.Fatalf("arm: %+v", response)
	}
	if response := rpc("controller", request); response.State != "armed" {
		t.Fatal("same transaction not idempotent")
	}
	editorResult := make(chan promptEditorResponse, 1)
	go func() {
		editorResult <- rpc("", promptEditorRequest{Operation: "capture", ID: id, Text: []byte("Exact  draft 🧬\nHard   newline")})
	}()
	snapshot := rpc("controller", promptEditorRequest{Operation: "snapshot", ID: id, Owner: owner})
	if snapshot.State != "captured" || string(snapshot.Text) != "Exact  draft 🧬\nHard   newline" {
		t.Fatalf("snapshot: %+v", snapshot)
	}
	if response := rpc("foreign", promptEditorRequest{Operation: "commit", ID: id, Digest: snapshot.Digest, Text: []byte("wrong")}); response.State != "refused" {
		t.Fatal("foreign client committed")
	}
	if response := rpc("controller", promptEditorRequest{Operation: "commit", ID: id, Digest: snapshot.Digest, Text: []byte("漢字  replacement\nTail 🧬"), Owner: owner}); response.State != "committed" {
		t.Fatalf("commit: %+v", response)
	}
	result := <-editorResult
	if !result.Apply || string(result.Text) != "漢字  replacement\nTail 🧬" {
		t.Fatalf("editor result: %+v", result)
	}
	if response := rpc("controller", promptEditorRequest{Operation: "cancel", ID: id, Owner: owner}); response.State != "delivered" {
		t.Fatal("delivered edit falsely reported cancelled")
	}
	wrong := sha256.Sum256([]byte("wrong"))
	if response := rpc("", promptEditorRequest{Operation: "editor-applied", ID: id, Digest: hex.EncodeToString(wrong[:])}); response.State != "refused" {
		t.Fatal("wrong application digest accepted")
	}
	applied := sha256.Sum256(result.Text)
	if response := rpc("", promptEditorRequest{Operation: "editor-applied", ID: id, Digest: hex.EncodeToString(applied[:])}); response.State != "applied" {
		t.Fatalf("application receipt: %+v", response)
	}
	if response := rpc("foreign", promptEditorRequest{Operation: "receipt", ID: id}); response.State != "refused" {
		t.Fatal("foreign client read receipt")
	}
	if response := rpc("controller", promptEditorRequest{Operation: "receipt", ID: id, Owner: owner}); response.State != "applied" || response.Digest != hex.EncodeToString(applied[:]) {
		t.Fatal("exact application receipt missing")
	}
	if response := rpc("controller", request); response.State != "delivered" {
		t.Fatal("completed transaction rearmed")
	}
}

func TestPromptEditorTransportCancelAndUnarmed(t *testing.T) {
	session, owner, rpc := promptEditorTestTransport(t)
	if response := rpc("", promptEditorRequest{Operation: "capture", Text: []byte("unrelated")}); response.State != "unarmed" || response.Apply {
		t.Fatal("unarmed editor intercepted")
	}
	id := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if response := rpc("controller", promptEditorRequest{Operation: "arm", ID: id, Owner: owner}); response.State != "armed" {
		t.Fatal("arm refused")
	}
	editorResult := make(chan promptEditorResponse, 1)
	go func() {
		editorResult <- rpc("", promptEditorRequest{Operation: "capture", ID: id, Text: []byte("original")})
	}()
	if response := rpc("controller", promptEditorRequest{Operation: "snapshot", ID: id, Owner: owner}); response.State != "captured" {
		t.Fatalf("snapshot: %+v", response)
	}
	if response := rpc("controller", promptEditorRequest{Operation: "cancel", ID: id, Owner: owner}); response.State != "cancelled" {
		t.Fatal("cancel refused")
	}
	result := <-editorResult
	if result.Apply || len(result.Text) != 0 {
		t.Fatal("cancel changes editor file")
	}
	// Capture delivery is finished here, so this deterministically covers
	// the cancellation reply race regardless of the goroutine schedule.
	if response := rpc("controller", promptEditorRequest{Operation: "cancel", ID: id, Owner: owner}); response.State != "cancelled" {
		t.Fatalf("readonly delivery changed cancellation receipt: %+v", response)
	}
	if response := rpc("", promptEditorRequest{Operation: "editor-status"}); response.State != "unarmed" {
		t.Fatalf("completed readonly transaction intercepts manual editor: %+v", response)
	}
	session.promptEditor.transaction.mu.Lock()
	session.promptEditor.transaction.readOwner = func() (PromptOwnerBinding, error) {
		changed := owner
		changed.ProcessStart++
		return changed, nil
	}
	session.promptEditor.transaction.mu.Unlock()
	if response := rpc("", promptEditorRequest{Operation: "editor-status"}); response.State != "unarmed" || response.Owner != nil || len(response.Text) != 0 {
		t.Fatalf("stale completed owner intercepts later manual editor: %+v", response)
	}
}

func TestPromptEditorTransportControllerRequestsRequireOriginalOwner(t *testing.T) {
	session, owner, rpc := promptEditorTestTransport(t)
	id := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	if response := rpc("controller", promptEditorRequest{Operation: "arm", ID: id, Owner: owner}); response.State != "armed" {
		t.Fatal("arm refused")
	}
	changed := owner
	changed.ProcessStart++
	for _, operation := range []string{"snapshot", "commit", "cancel", "receipt"} {
		for _, supplied := range []PromptOwnerBinding{{}, changed} {
			if response := rpc("controller", promptEditorRequest{Operation: operation, ID: id, Owner: supplied}); response.State != "refused" {
				t.Fatalf("%s accepted missing or changed owner: %+v", operation, response)
			}
		}
	}
	session.promptEditor.transaction.mu.Lock()
	state := session.promptEditor.transaction.state
	session.promptEditor.transaction.mu.Unlock()
	if state != "armed" {
		t.Fatalf("refused request changed transaction to %q", state)
	}
	if response := rpc("controller", promptEditorRequest{Operation: "cancel", ID: id, Owner: owner}); response.State != "cancelled" {
		t.Fatal("original owner could not cancel")
	}
}

func TestPromptEditorUnsupportedRequiresVerifiedOwnerAndControl(t *testing.T) {
	for _, mode := range []string{"missing", "changed-owner", "changed-during-capability", "corrupt-bridge", "foreign-control"} {
		t.Run(mode, func(t *testing.T) {
			var changed atomic.Bool
			session, owner, rpc := promptEditorTestTransportConfigured(t, func(original PromptOwnerBinding) (func() (PromptOwnerBinding, error), func(PromptOwnerBinding) error) {
				read := func() (PromptOwnerBinding, error) {
					result := original
					if changed.Load() {
						result.ProcessStart++
					}
					return result, nil
				}
				bridge := func(PromptOwnerBinding) error {
					if mode == "changed-during-capability" {
						changed.Store(true)
					}
					if mode == "corrupt-bridge" {
						return errors.New("bridge integrity changed")
					}
					return errPromptEditorUnsupported
				}
				return read, bridge
			})
			if mode == "changed-owner" {
				changed.Store(true)
			}
			client := "controller"
			if mode == "foreign-control" {
				client = "foreign"
			}
			request := promptEditorRequest{Operation: "arm", ID: "dddddddddddddddddddddddddddddddd", Owner: owner}
			response := rpc(client, request)
			if mode == "missing" {
				if response.State != "unavailable" || !response.Unsupported || response.ID != request.ID || response.Owner == nil || *response.Owner != owner {
					t.Fatalf("unsupported response not bound: %+v", response)
				}
			} else if response.State != "refused" || response.Unsupported {
				t.Fatalf("unverified capability granted fallback: %+v", response)
			}
			session.promptEditorMu.Lock()
			pending := session.promptEditor
			session.promptEditorMu.Unlock()
			if pending != nil {
				t.Fatal("unsupported/refused arm installed a transaction")
			}
		})
	}
}

func TestPromptEditorRepeatedArmRejectsChangedKernelOwner(t *testing.T) {
	var changed atomic.Bool
	session, owner, rpc := promptEditorTestTransportConfigured(t, func(original PromptOwnerBinding) (func() (PromptOwnerBinding, error), func(PromptOwnerBinding) error) {
		return func() (PromptOwnerBinding, error) {
			result := original
			if changed.Load() {
				result.ProcessStart++
			}
			return result, nil
		}, func(PromptOwnerBinding) error { return nil }
	})
	request := promptEditorRequest{Operation: "arm", ID: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", Owner: owner}
	if response := rpc("controller", request); response.State != "armed" {
		t.Fatalf("initial arm: %+v", response)
	}
	changed.Store(true)
	if response := rpc("controller", request); response.State != "refused" || response.Unsupported {
		t.Fatalf("stale repeated arm: %+v", response)
	}
	session.promptEditorMu.Lock()
	pending := session.promptEditor
	session.promptEditorMu.Unlock()
	if pending == nil || pending.id != request.ID {
		t.Fatal("refusal replaced original transaction")
	}
}

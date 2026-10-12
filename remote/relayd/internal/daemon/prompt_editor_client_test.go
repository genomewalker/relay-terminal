package daemon

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestPromptEditorClientOldWorkerIsProbeOnly(t *testing.T) {
	root, err := os.MkdirTemp("", "relay-pedit-old-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	path := filepath.Join(root, "test.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	observed := make(chan protocol.HelloPayload, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		defer connection.Close()
		frame, err := protocol.ReadFrame(connection)
		if err != nil {
			return
		}
		var hello protocol.HelloPayload
		if protocol.DecodeJSON(frame, &hello) != nil {
			return
		}
		observed <- hello
		// The old worker's Probe branch precedes terminal attachment. It
		// ignores prompt_editor and returns only readiness, with no input.
		status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready"})
		_ = protocol.NewWriter(connection).Write(status)
	}()
	request := json.RawMessage(`{"operation":"arm","id":"0123456789abcdef0123456789abcdef"}`)
	if _, err := callVerifiedPromptEditorWorker(workerManifest{SessionID: "owned", SocketPath: path, WorkerPID: os.Getpid(), Token: "private-test-token"}, "controller", request); err == nil {
		t.Fatal("old worker treated as supporting editor transactions")
	}
	hello := <-observed
	if !hello.Probe || hello.SessionID != "owned" || string(hello.PromptEditor) != string(request) {
		t.Fatal("probe-only compatibility lost")
	}
}

func TestPromptEditorClientRejectsInvalidRequestBeforeConnecting(t *testing.T) {
	for _, pane := range []string{"../invalid", ""} {
		if _, err := CallPromptEditor(pane, "controller", json.RawMessage(`{}`)); err == nil {
			t.Fatal("invalid pane accepted")
		}
	}
	if _, err := CallPromptEditor("owned", "controller", json.RawMessage(`invalid-json`)); err == nil {
		t.Fatal("invalid JSON accepted")
	}
}

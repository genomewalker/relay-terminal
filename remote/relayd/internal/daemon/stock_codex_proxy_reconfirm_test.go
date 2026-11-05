package daemon

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func confirmedProxyForReconfirmation(t *testing.T) codexProxySelection {
	t.Helper()
	s := codexProxySelection{wanted: "chosen"}
	proxyRPC(t, &s, true, `{"id":"resume","method":"thread/resume","params":{"threadId":"chosen"}}`)
	proxyRPC(t, &s, false, `{"id":"resume","result":{"thread":{"id":"chosen","path":"/saved/root.jsonl"}}}`)
	return s
}

func TestStockCodexProxyReconfirmsReturnedPrimaryOnlyAfterSuccessfulTurn(t *testing.T) {
	for _, method := range []string{"turn/start", "turn/steer"} {
		t.Run(method, func(t *testing.T) {
			s := confirmedProxyForReconfirmation(t)
			proxyRPC(t, &s, true, `{"method":"thread/unsubscribe","params":{"threadId":"chosen"}}`)
			if s.session != "" {
				t.Fatal("released primary must be unbound")
			}
			proxyRPC(t, &s, true, `{"id":"return","method":"`+method+`","params":{"threadId":"chosen"}}`)
			if s.session != "" {
				t.Fatal("a turn request alone must not restore identity")
			}
			result := `{"turn":{"id":"turn-1","status":"inProgress"}}`
			if method == "turn/steer" {
				result = `{"turnId":"turn-1"}`
			}
			proxyRPC(t, &s, false, `{"id":"return","result":`+result+`}`)
			if s.session != "chosen" || s.path != "/saved/root.jsonl" {
				t.Fatalf("confirmed return to the same primary was lost: %+v", s)
			}
		})
	}
}

func TestStockCodexProxyReconfirmationRejectsErrorsNullAndUnmatchedReplies(t *testing.T) {
	for _, response := range []string{
		`{"id":"return","error":{"code":-1}}`,
		`{"id":"return","result":null}`,
		`{"id":"return","result":{}}`,
		`{"id":"other","result":{"turn":{"id":"turn-1"}}}`,
	} {
		t.Run(response, func(t *testing.T) {
			s := confirmedProxyForReconfirmation(t)
			proxyRPC(t, &s, true, `{"method":"thread/unsubscribe","params":{"threadId":"chosen"}}`)
			proxyRPC(t, &s, true, `{"id":"return","method":"turn/start","params":{"threadId":"chosen"}}`)
			proxyRPC(t, &s, false, response)
			if s.session != "" {
				t.Fatal("unsuccessful or unrelated turn response restored identity")
			}
		})
	}
}

func TestStockCodexProxyReconfirmationDoesNotAdoptAnotherThread(t *testing.T) {
	s := confirmedProxyForReconfirmation(t)
	proxyRPC(t, &s, true, `{"id":"foreign","method":"turn/start","params":{"threadId":"another"}}`)
	proxyRPC(t, &s, false, `{"id":"foreign","result":{"turn":{"id":"turn-1"}}}`)
	if s.session != "" {
		t.Fatal("another thread's successful turn became the saved primary")
	}
}

func TestStockCodexProxyReconfirmationRejectsRepliesFromAnEarlierSelection(t *testing.T) {
	for _, invalidate := range []string{"foreign_resume", "primary_unload", "primary_unsubscribe", "new_connection"} {
		t.Run(invalidate, func(t *testing.T) {
			s := confirmedProxyForReconfirmation(t)
			proxyRPC(t, &s, true, `{"method":"thread/unsubscribe","params":{"threadId":"chosen"}}`)
			proxyRPC(t, &s, true, `{"id":"return","method":"turn/start","params":{"threadId":"chosen"}}`)
			switch invalidate {
			case "foreign_resume":
				proxyRPC(t, &s, true, `{"id":"other","method":"thread/resume","params":{"threadId":"another"}}`)
			case "primary_unload":
				proxyRPC(t, &s, false, `{"method":"thread/unloaded","params":{"threadId":"chosen"}}`)
			case "primary_unsubscribe":
				proxyRPC(t, &s, true, `{"method":"thread/unsubscribe","params":{"threadId":"chosen"}}`)
			case "new_connection":
				s.invalidate("connection_changed")
			}
			proxyRPC(t, &s, false, `{"id":"return","result":{"turn":{"id":"turn-1"}}}`)
			if s.session != "" {
				t.Fatal("a late turn response crossed a selection or connection change")
			}
		})
	}
}

func TestStockCodexProxyReconfirmationNeedsResumeOnThisConnection(t *testing.T) {
	for _, priorConnection := range []bool{false, true} {
		s := codexProxySelection{wanted: "chosen"}
		if priorConnection {
			s = confirmedProxyForReconfirmation(t)
			s.invalidate("connection_changed")
		}
		proxyRPC(t, &s, true, `{"id":"return","method":"turn/start","params":{"threadId":"chosen"}}`)
		proxyRPC(t, &s, false, `{"id":"return","result":{"turn":{"id":"turn-1"}}}`)
		if s.session != "" {
			t.Fatal("a turn without a confirmed resume on this connection established identity")
		}
	}
}

func TestStockCodexProxyCompactionAndSameThreadRecapPreserveIdentity(t *testing.T) {
	s := confirmedProxyForReconfirmation(t)
	proxyRPC(t, &s, true, `{"id":"compact","method":"thread/compact/start","params":{"threadId":"chosen"}}`)
	proxyRPC(t, &s, false, `{"id":"compact","result":{}}`)
	proxyRPC(t, &s, false, `{"method":"thread/compacted","params":{"threadId":"chosen"}}`)
	proxyRPC(t, &s, true, `{"id":"recap","method":"turn/start","params":{"threadId":"chosen"}}`)
	if s.session != "chosen" || s.path != "/saved/root.jsonl" {
		t.Fatal("same-thread compaction or recap lost the confirmed identity")
	}
}

func TestStockCodexProxyClearRequiresOriginalConversationToBeResumed(t *testing.T) {
	s := confirmedProxyForReconfirmation(t)
	proxyRPC(t, &s, true, `{"id":"clear","method":"thread/start","params":{}}`)
	proxyRPC(t, &s, false, `{"id":"clear","result":{"thread":{"id":"new-thread"}}}`)
	proxyRPC(t, &s, true, `{"id":"recap","method":"turn/start","params":{"threadId":"new-thread"}}`)
	proxyRPC(t, &s, false, `{"id":"recap","result":{"turn":{"id":"turn-1"}}}`)
	if s.session != "" {
		t.Fatal("clear plus recap silently adopted a new conversation")
	}
	proxyRPC(t, &s, true, `{"id":"resume-again","method":"thread/resume","params":{"threadId":"chosen"}}`)
	proxyRPC(t, &s, false, `{"id":"resume-again","result":{"thread":{"id":"chosen","path":"/saved/root.jsonl"}}}`)
	if s.session != "chosen" {
		t.Fatal("resuming the original conversation did not restore the binding")
	}
}

func TestStockCodexProxyNewConnectionNeedsAndAcceptsFreshResume(t *testing.T) {
	s := confirmedProxyForReconfirmation(t)
	s.invalidate("connection_changed")
	proxyRPC(t, &s, true, `{"id":"fresh-resume","method":"thread/resume","params":{"threadId":"chosen"}}`)
	if s.session != "" {
		t.Fatal("a request on the new connection established identity")
	}
	proxyRPC(t, &s, false, `{"id":"fresh-resume","result":{"thread":{"id":"chosen","path":"/saved/root.jsonl"}}}`)
	if s.session != "chosen" || !s.confirmedResume {
		t.Fatal("successful fresh resume failed to reverify identity")
	}
}

func TestStockCodexProxyBindingReportsSelectionFailure(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	server := NewServer()
	directory, err := os.MkdirTemp("/tmp", "rpx-error-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	path := filepath.Join(directory, "control.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	dev, ino, err := codexProxySocketIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	start, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	pane := "selection-error"
	descriptor := codexProxyDescriptor{Version: 1, Pane: pane, Session: "chosen", ProxyPID: os.Getpid(), ProxyStart: start, ControlSocket: path, ControlDevice: dev, ControlInode: ino}
	data, _ := json.Marshal(descriptor)
	if err := os.MkdirAll(codexProxyDirectory(server, pane), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(codexProxyDirectory(server, pane), "descriptor.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var request map[string]string
		if json.NewDecoder(conn).Decode(&request) == nil {
			_ = json.NewEncoder(conn).Encode(map[string]string{"error": "stock Codex has no verified current session"})
		}
	}()
	_, err = readStockCodexProxyBinding(pane)
	if err == nil || !strings.Contains(err.Error(), "no verified current session") {
		t.Fatalf("the actual selection failure was hidden: %v", err)
	}
}

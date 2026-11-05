package daemon

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/websocket"
)

func proxyRPC(t *testing.T, s *codexProxySelection, frontend bool, data string) {
	t.Helper()
	var err error
	if frontend {
		err = s.frontend([]byte(data))
	} else {
		err = s.backend([]byte(data))
	}
	if err != nil {
		t.Fatal(err)
	}
}

func TestStockCodexProxyRequiresConfirmedExactResume(t *testing.T) {
	s := codexProxySelection{wanted: "chosen"}
	proxyRPC(t, &s, true, `{"id":1,"method":"thread/read","params":{"threadId":"chosen"}}`)
	proxyRPC(t, &s, false, `{"id":1,"result":{"thread":{"id":"chosen"}}}`)
	if s.session != "" {
		t.Fatal("read cannot select a frontend thread")
	}
	proxyRPC(t, &s, true, `{"id":2,"method":"thread/resume","params":{"threadId":"chosen"}}`)
	if s.session != "" {
		t.Fatal("request is not a confirmed binding")
	}
	proxyRPC(t, &s, false, `{"id":2,"result":{"thread":{"id":"chosen","path":"/unwritten"}}}`)
	if s.session != "chosen" || s.path != "/unwritten" {
		t.Fatalf("resume not confirmed: %+v", s)
	}
}

func TestStockCodexManagedProxyFollowsOnlyConfirmedFrontendSelections(t *testing.T) {
	s := codexProxySelection{trackPrimary: true}
	proxyRPC(t, &s, true, `{"id":"new","method":"thread/start","params":{}}`)
	if s.session != "" {
		t.Fatal("unconfirmed new thread bound")
	}
	proxyRPC(t, &s, false, `{"method":"thread/started","params":{"thread":{"id":"background"}}}`)
	if s.session != "" {
		t.Fatal("background notification selected a primary")
	}
	proxyRPC(t, &s, false, `{"id":"new","result":{"thread":{"id":"fresh","path":"/owned/fresh"}}}`)
	if s.session != "fresh" {
		t.Fatal("fresh frontend thread not bound")
	}
	proxyRPC(t, &s, true, `{"id":"read","method":"thread/read","params":{"threadId":"other"}}`)
	proxyRPC(t, &s, false, `{"id":"read","result":{"thread":{"id":"other"}}}`)
	if s.session != "fresh" {
		t.Fatal("background read changed primary")
	}
	proxyRPC(t, &s, true, `{"id":"old","method":"thread/resume","params":{"threadId":"older"}}`)
	proxyRPC(t, &s, true, `{"id":"clear","method":"thread/start","params":{}}`)
	proxyRPC(t, &s, false, `{"id":"old","result":{"thread":{"id":"older"}}}`)
	if s.session != "" {
		t.Fatal("stale resume response rebound an old conversation")
	}
	proxyRPC(t, &s, false, `{"id":"clear","result":{"thread":{"id":"after-clear"}}}`)
	if s.session != "after-clear" {
		t.Fatal("clear did not bind the new confirmed thread")
	}
	proxyRPC(t, &s, true, `{"id":"fork","method":"thread/fork","params":{"threadId":"after-clear"}}`)
	proxyRPC(t, &s, false, `{"id":"fork","result":{"thread":{"id":"forked"}}}`)
	if s.session != "forked" {
		t.Fatal("explicit frontend fork was not bound")
	}
}

func TestStockCodexManagedProxyReconfirmsOnlyItsConfirmedPrimaryTurn(t *testing.T) {
	s := codexProxySelection{trackPrimary: true}
	proxyRPC(t, &s, true, `{"id":1,"method":"thread/start","params":{}}`)
	proxyRPC(t, &s, false, `{"id":1,"result":{"thread":{"id":"fresh","path":"/owned/fresh"}}}`)
	proxyRPC(t, &s, true, `{"method":"thread/unsubscribe","params":{"threadId":"fresh"}}`)
	if s.session != "" {
		t.Fatal("unsubscribed primary remained live")
	}
	proxyRPC(t, &s, true, `{"id":2,"method":"turn/start","params":{"threadId":"fresh"}}`)
	if s.session != "" {
		t.Fatal("unconfirmed turn restored identity")
	}
	proxyRPC(t, &s, false, `{"id":2,"result":{"turn":{"id":"turn-a"}}}`)
	if s.session != "fresh" || s.path != "/owned/fresh" {
		t.Fatal("confirmed primary turn did not restore identity")
	}
	proxyRPC(t, &s, true, `{"id":3,"method":"thread/start","params":{}}`)
	proxyRPC(t, &s, true, `{"id":4,"method":"turn/start","params":{"threadId":"fresh"}}`)
	proxyRPC(t, &s, false, `{"id":4,"result":{"turn":{"id":"stale-turn"}}}`)
	if s.session != "" {
		t.Fatal("old thread turn overrode an explicit new conversation")
	}
}

func TestStockCodexProxyRefusesOtherSessionAndStaleResponse(t *testing.T) {
	s := codexProxySelection{wanted: "chosen"}
	proxyRPC(t, &s, true, `{"id":"first","method":"thread/resume","params":{"threadId":"chosen"}}`)
	proxyRPC(t, &s, true, `{"id":"other","method":"thread/resume","params":{"threadId":"other"}}`)
	proxyRPC(t, &s, false, `{"id":"first","result":{"thread":{"id":"chosen"}}}`)
	proxyRPC(t, &s, false, `{"id":"other","result":{"thread":{"id":"other"}}}`)
	if s.session != "" {
		t.Fatal("stale or other resume bound the selected frontend")
	}
}

func TestStockCodexProxyThreadChangesInvalidateBeforeResponse(t *testing.T) {
	for _, method := range []string{"thread/start", "thread/fork", "thread/resume", "turn/start", "turn/steer"} {
		t.Run(method, func(t *testing.T) {
			s := codexProxySelection{wanted: "chosen", session: "chosen", epoch: 1}
			frame, _ := json.Marshal(map[string]any{"id": 1, "method": method, "params": map[string]string{"threadId": "other"}})
			if s.frontend(frame) != nil || s.session != "" {
				t.Fatal("thread change retained binding")
			}
		})
	}
}

func TestStockCodexProxyErrorsAndMismatchesCannotBind(t *testing.T) {
	for _, response := range []string{`{"id":1,"error":{"code":-1}}`, `{"id":1,"result":{"thread":{"id":"other"}}}`, `{"id":1,"result":null}`} {
		s := codexProxySelection{wanted: "chosen"}
		proxyRPC(t, &s, true, `{"id":1,"method":"thread/resume","params":{"threadId":"chosen"}}`)
		proxyRPC(t, &s, false, response)
		if s.session != "" {
			t.Fatal("unsuccessful resume bound frontend")
		}
	}
}

func TestStockCodexProxyOrdinaryResponsesAndOwnTurnsPreserveBinding(t *testing.T) {
	s := codexProxySelection{wanted: "chosen", session: "chosen", epoch: 1}
	for _, frame := range []string{`{"id":30,"result":["first","second"]}`, `{"id":31,"result":"ordinary"}`, `{"id":32,"result":1}`} {
		proxyRPC(t, &s, false, frame)
	}
	proxyRPC(t, &s, true, `{"id":40,"method":"turn/start","params":{"threadId":"chosen","input":[]}}`)
	if s.session != "chosen" {
		t.Fatal("ordinary protocol traffic invalidated binding")
	}
}

func TestStockCodexProxyUnloadAndMalformedFramesInvalidate(t *testing.T) {
	for _, method := range []string{"thread/closed", "thread/unloaded"} {
		s := codexProxySelection{wanted: "chosen", session: "chosen", epoch: 1}
		proxyRPC(t, &s, false, `{"method":"`+method+`","params":{"threadId":"chosen"}}`)
		if s.session != "" {
			t.Fatal("unloaded thread retained binding")
		}
	}
	s := codexProxySelection{wanted: "chosen", session: "chosen", epoch: 1}
	if s.frontend([]byte("{")) == nil || s.session != "" {
		t.Fatal("malformed RPC retained binding")
	}
}

func TestStockCodexProxyFrameCodecPreservesExactPayload(t *testing.T) {
	payload := []byte("{ \"id\": 1, \"params\": {\"content\": \"fixture \\u03b1\"} }")
	input := codexProxyFrame{data: payload, kind: websocket.TextFrame}
	data, kind, err := codexProxyFrameCodec.Marshal(input)
	if err != nil || kind != websocket.TextFrame || string(data) != string(payload) {
		t.Fatal("frame changed during forwarding")
	}
	var output codexProxyFrame
	if codexProxyFrameCodec.Unmarshal(data, kind, &output) != nil || string(output.data) != string(payload) || output.kind != kind {
		t.Fatal("received frame changed")
	}
}

func TestStockCodexProxyBackendPinsKernelIdentity(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "rpx-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "backend.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	os.Chmod(path, 0600)
	dev, ino, err := codexProxySocketIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	start, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	endpoint := NativeCodexEndpoint{Socket: path, DaemonPID: os.Getpid(), DaemonStart: start, Device: dev, Inode: ino}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	conn, err := codexProxyBackendConnection(ctx, endpoint)
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	endpoint.DaemonStart++
	if conn, err := codexProxyBackendConnection(ctx, endpoint); err == nil {
		conn.Close()
		t.Fatal("reused backend incarnation accepted")
	}
	endpoint.DaemonStart--
	endpoint.Inode++
	if conn, err := codexProxyBackendConnection(ctx, endpoint); err == nil {
		conn.Close()
		t.Fatal("replaced backend socket accepted")
	}
}

func TestStockCodexProxyDescriptorIsNotALiveLease(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	server := NewServer()
	pane := "fixture-pane"
	if _, err := readStockCodexProxyDescriptor(server, pane); err != errNoStockCodexProxy {
		t.Fatal(err)
	}
	dir := codexProxyDirectory(server, pane)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(codexProxyDescriptor{Version: 1, Pane: pane, Session: "chosen", ProxyPID: os.Getpid(), ProxyStart: 1, ControlSocket: filepath.Join(dir, "missing.sock")})
	if err := os.WriteFile(filepath.Join(dir, "descriptor.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readStockCodexProxyBinding(pane); err == nil || !strings.Contains(err.Error(), "socket") {
		t.Fatal("historical descriptor must not authorize binding", err)
	}
}

func TestStockCodexProxyBackgroundReadsDoNotReplacePrimaryAssociation(t *testing.T) {
	for _, method := range []string{"thread/read", "thread/turns/list", "thread/items/list", "mcpServerStatus/list"} {
		s := codexProxySelection{wanted: "chosen", session: "chosen", epoch: 1}
		frame, _ := json.Marshal(map[string]any{"id": 7, "method": method, "params": map[string]string{"threadId": "subagent"}})
		if s.frontend(frame) != nil || s.session != "chosen" {
			t.Fatal("background metadata changed primary association", method)
		}
	}
	s := codexProxySelection{wanted: "chosen", session: "chosen", epoch: 1}
	proxyRPC(t, &s, false, `{"method":"thread/started","params":{"thread":{"id":"subagent"}}}`)
	if s.session != "chosen" {
		t.Fatal("background notification changed primary association")
	}
}

func TestStockCodexProxyBackgroundUnsubscribePreservesPrimaryAcrossTurns(t *testing.T) {
	s := codexProxySelection{wanted: "chosen", session: "chosen", path: "/root-rollout", epoch: 2}
	for _, frame := range []string{
		`{"id":10,"method":"thread/unsubscribe","params":{"threadId":"finished-subagent"}}`,
		`{"method":"thread/unloaded","params":{"threadId":"finished-subagent"}}`,
		`{"id":11,"method":"turn/start","params":{"threadId":"chosen","input":[]}}`,
		`{"id":12,"method":"turn/steer","params":{"threadId":"chosen","input":[]}}`,
	} {
		proxyRPC(t, &s, !strings.Contains(frame, "thread/unloaded"), frame)
		if s.session != "chosen" || s.path != "/root-rollout" || s.epoch != 2 {
			t.Fatalf("background unsubscribe broke root across ordinary turns: %+v", s)
		}
	}
	proxyRPC(t, &s, true, `{"id":13,"method":"thread/unsubscribe","params":{"threadId":"chosen"}}`)
	if s.session != "" || s.epoch != 3 || s.lastInvalidation != "thread/unsubscribe" {
		t.Fatalf("primary unsubscribe did not revoke binding: %+v", s)
	}
}

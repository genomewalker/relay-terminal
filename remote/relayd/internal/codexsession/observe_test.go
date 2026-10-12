package codexsession

import (
	"context"
	"golang.org/x/net/websocket"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestObserveRuntimeGuards(t *testing.T) {
	for _, tc := range []struct {
		name                             string
		duplicate, disconnected, changed bool
		wantError                        bool
	}{
		{name: "unique"},
		{name: "multiple", duplicate: true, wantError: true},
		{name: "disconnected", disconnected: true, wantError: true},
		{name: "changed", changed: true, wantError: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(websocket.Handler(func(ws *websocket.Conn) {
				defer ws.Close()
				for {
					var frame struct {
						ID     int            `json:"id"`
						Method string         `json:"method"`
						Params map[string]any `json:"params"`
					}
					if websocket.JSON.Receive(ws, &frame) != nil {
						return
					}
					if frame.Method == "initialized" {
						continue
					}
					var result any
					switch frame.Method {
					case "initialize":
						result = map[string]any{"userAgent": "fixture"}
					case "thread/loaded/list":
						ids := []string{"01a0eb84-4b45-7ea0-a48a-ef75002cd8ec"}
						if tc.duplicate {
							ids = append(ids, "01a0eb88-0102-7970-88d8-a1170921fded")
						}
						result = map[string]any{"data": ids, "nextCursor": nil}
					case "mcpServerStatus/list":
						if frame.Params["serverName"] != "codex_tui" {
							t.Error("wrong native server")
						}
						calls++
						origin := "http://127.0.0.1:58889"
						status := "connected"
						if tc.disconnected {
							status = "disconnected"
						}
						if tc.changed && calls > 1 {
							origin = "http://127.0.0.1:58890"
						}
						result = map[string]any{"data": []any{map[string]any{"name": "codex_tui", "httpOrigin": origin, "runtimeStatus": status}}, "nextCursor": nil}
					case "thread/read":
						if frame.Params["includeTurns"] != false {
							t.Error("history content requested")
						}
						result = map[string]any{"thread": map[string]any{"id": frame.Params["threadId"], "path": "/fixture/.codex/sessions/thread.jsonl"}}
					default:
						t.Errorf("unexpected or mutating method %s", frame.Method)
						return
					}
					if websocket.JSON.Send(ws, map[string]any{"id": frame.ID, "result": result}) != nil {
						return
					}
				}
			}))
			defer server.Close()
			connection, err := net.Dial("tcp", strings.TrimPrefix(server.URL, "http://"))
			if err != nil {
				t.Fatal(err)
			}
			defer connection.Close()
			ctx, cancel := context.WithTimeout(context.Background(), time.Second*3)
			defer cancel()
			got, err := ObserveRuntime(ctx, connection, "http://127.0.0.1:58889")
			if (err != nil) != tc.wantError {
				t.Fatalf("binding=%+v error=%v", got, err)
			}
			if err == nil && got.ThreadID != "01a0eb84-4b45-7ea0-a48a-ef75002cd8ec" {
				t.Fatal("wrong thread")
			}
		})
	}
}

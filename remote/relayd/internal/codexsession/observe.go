package codexsession

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"reflect"
	"sort"
	"time"

	"golang.org/x/net/websocket"
)

// RuntimeBinding is a read-only observation of an already loaded native thread.
// It does not authorize input, resume a thread, or grant ownership of a controller.
type RuntimeBinding struct {
	ThreadID       string
	TranscriptPath string
	Origin         string
}

type runtimeOrigin struct {
	ThreadID string
	Origin   string
	Status   string
}

// ObserveRuntime accepts only the native daemon connection authenticated by the
// caller's kernel checks. No mutating App Server methods are exposed here.
func ObserveRuntime(ctx context.Context, connection net.Conn, origin string) (RuntimeBinding, error) {
	var empty RuntimeBinding
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(8 * time.Second)
	}
	if err := connection.SetDeadline(deadline); err != nil {
		return empty, err
	}
	config, err := websocket.NewConfig("ws://localhost/", "http://localhost/")
	if err != nil {
		return empty, err
	}
	ws, err := websocket.NewClient(config, connection)
	if err != nil {
		return empty, err
	}
	defer ws.Close()
	ws.MaxPayloadBytes = 1 << 20
	nextID := 0
	rpc := func(method string, params any, result any) error {
		switch method {
		case "initialize", "thread/loaded/list", "mcpServerStatus/list", "thread/read":
		default:
			return errors.New("method outside native observation allowlist")
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		nextID++
		if err := websocket.JSON.Send(ws, map[string]any{"id": nextID, "method": method, "params": params}); err != nil {
			return err
		}
		for count := 0; count < 4096; count++ {
			var frame struct {
				ID     json.RawMessage `json:"id"`
				Result json.RawMessage `json:"result"`
				Error  json.RawMessage `json:"error"`
			}
			if err := websocket.JSON.Receive(ws, &frame); err != nil {
				return err
			}
			var id int
			if json.Unmarshal(frame.ID, &id) != nil || id != nextID {
				continue
			}
			if len(frame.Error) > 0 && string(frame.Error) != "null" {
				return errors.New("native observation RPC failed: " + method)
			}
			if len(frame.Result) == 0 {
				return errors.New("native observation result missing")
			}
			return json.Unmarshal(frame.Result, result)
		}
		return errors.New("native notification limit exceeded")
	}
	var initialized json.RawMessage
	if err = rpc("initialize", map[string]any{
		"clientInfo":   map[string]string{"name": "relay_binding_observer", "title": "Relay binding observer", "version": "0.1"},
		"capabilities": map[string]bool{"experimentalApi": true},
	}, &initialized); err != nil {
		return empty, err
	}
	if err = websocket.JSON.Send(ws, map[string]any{"method": "initialized", "params": map[string]any{}}); err != nil {
		return empty, err
	}
	snapshot := func() ([]runtimeOrigin, error) {
		ids := []string{}
		seen := map[string]bool{}
		cursor := ""
		for page := 0; ; page++ {
			if page >= 8 {
				return nil, errors.New("loaded-thread page limit exceeded")
			}
			params := map[string]any{"limit": 100}
			if cursor != "" {
				params["cursor"] = cursor
			}
			var response struct {
				Data []string `json:"data"`
				Next string   `json:"nextCursor"`
			}
			if err := rpc("thread/loaded/list", params, &response); err != nil {
				return nil, err
			}
			for _, id := range response.Data {
				if id == "" || len(id) > 128 || seen[id] {
					return nil, errors.New("invalid or duplicate loaded thread")
				}
				seen[id] = true
				ids = append(ids, id)
				if len(ids) > 512 {
					return nil, errors.New("loaded-thread limit exceeded")
				}
			}
			if response.Next == "" {
				break
			}
			if response.Next == cursor {
				return nil, errors.New("loaded-thread cursor repeated")
			}
			cursor = response.Next
		}
		sort.Strings(ids)
		rows := make([]runtimeOrigin, 0, len(ids))
		for _, id := range ids {
			var response struct {
				Data []struct {
					Name   string `json:"name"`
					Origin string `json:"httpOrigin"`
					Status string `json:"runtimeStatus"`
				} `json:"data"`
				Next string `json:"nextCursor"`
			}
			if err := rpc("mcpServerStatus/list", map[string]any{"threadId": id, "serverName": "codex_tui", "detail": "toolsAndAuthOnly", "limit": 100}, &response); err != nil {
				return nil, err
			}
			if response.Next != "" {
				return nil, errors.New("unexpected server-status pagination")
			}
			row := runtimeOrigin{ThreadID: id}
			found := false
			for _, server := range response.Data {
				if server.Name != "codex_tui" {
					continue
				}
				if found {
					return nil, errors.New("duplicate native TUI server")
				}
				found = true
				row.Origin = server.Origin
				row.Status = server.Status
			}
			rows = append(rows, row)
		}
		return rows, nil
	}
	first, err := snapshot()
	if err != nil {
		return empty, err
	}
	matches := []runtimeOrigin{}
	for _, row := range first {
		if row.Origin == origin {
			matches = append(matches, row)
		}
	}
	readPath := func(id string) (string, error) {
		var read struct {
			Thread struct {
				ID   string `json:"id"`
				Path string `json:"path"`
			} `json:"thread"`
		}
		if err := rpc("thread/read", map[string]any{"threadId": id, "includeTurns": false}, &read); err != nil {
			return "", err
		}
		if read.Thread.ID != id || read.Thread.Path == "" {
			return "", errors.New("native thread transcript metadata unavailable")
		}
		return read.Thread.Path, nil
	}
	selected, err := selectPrimaryThread(matches, func(id string) (string, error) {
		path, err := readPath(id)
		if err != nil {
			return "", err
		}
		return threadSpawnParent(path, id)
	})
	if err != nil {
		return empty, err
	}
	var read struct {
		Thread struct {
			ID   string `json:"id"`
			Path string `json:"path"`
		} `json:"thread"`
	}
	if err = rpc("thread/read", map[string]any{"threadId": selected, "includeTurns": false}, &read); err != nil {
		return empty, err
	}
	if read.Thread.ID != selected || read.Thread.Path == "" {
		return empty, errors.New("native thread transcript metadata unavailable")
	}
	second, err := snapshot()
	if err != nil {
		return empty, err
	}
	if !reflect.DeepEqual(first, second) {
		return empty, errors.New("native runtime association changed")
	}
	return RuntimeBinding{ThreadID: selected, TranscriptPath: read.Thread.Path, Origin: origin}, nil
}

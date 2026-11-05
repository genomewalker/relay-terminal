package codexmcphealth

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"unicode/utf8"
)

type Options struct {
	PID                                int
	Start, Thread, Socket, Cwd, Server string
	Refresh, InspectLoaded             bool
}
type Identity struct{ Device, Inode uint64 }
type RPC interface {
	Call(string, any) (map[string]any, error)
	Close() error
}
type Runtime interface {
	Validate(Options) error
	Start(int) (string, error)
	PrivateSocket(string) (Identity, error)
	OwnsListener(int, string) (bool, error)
	Connect(context.Context, string) (RPC, error)
}

func array(v any) ([]any, error) {

	a, ok := v.([]any)
	if !ok {
		return nil, errors.New("array required")
	}
	return a, nil
}
func obj(v any) (map[string]any, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("object required")
	}
	return m, nil
}
func Run(ctx context.Context, args []string, out, errout io.Writer) error {
	flags := flag.NewFlagSet("relay-codex-mcp-health", flag.ContinueOnError)
	flags.SetOutput(errout)
	o := Options{}
	flags.IntVar(&o.PID, "pid", 0, "exact source PID")
	flags.StringVar(&o.Start, "start", "", "process start identity")
	flags.StringVar(&o.Thread, "thread", "", "exact loaded thread")
	flags.StringVar(&o.Socket, "socket", "", "private control socket")
	flags.StringVar(&o.Cwd, "cwd", "", "source working directory")
	flags.StringVar(&o.Server, "server", "relayDesktopR", "server name")
	flags.BoolVar(&o.Refresh, "refresh", false, "reload MCP in the exact single idle thread")
	flags.BoolVar(&o.InspectLoaded, "inspect-loaded", false, "inspect bounded loaded identities without refreshing")
	if e := flags.Parse(args); e != nil {
		return e
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	result, e := Inspect(ctx, o, NativeRuntime{})
	if e != nil {
		return e
	}
	return json.NewEncoder(out).Encode(result)
}
func Inspect(ctx context.Context, o Options, r Runtime) (map[string]any, error) {
	if o.PID <= 0 || o.Start == "" || o.Thread == "" || o.Socket == "" || o.Cwd == "" {
		return nil, errors.New("pid, start, thread, socket and cwd are required")
	}
	if o.InspectLoaded && o.Refresh {
		return nil, errors.New("loaded thread inspection cannot refresh")
	}
	if e := r.Validate(o); e != nil {
		return nil, e
	}
	identity, e := r.PrivateSocket(o.Socket)
	if e != nil {
		return nil, e
	}
	c, e := r.Connect(ctx, o.Socket)
	if e != nil {
		return nil, e
	}
	defer c.Close()
	stable := func() error {
		current, e := r.PrivateSocket(o.Socket)
		if e != nil {
			return e
		}
		start, e := r.Start(o.PID)
		if e != nil {
			return e
		}
		if current != identity || start != o.Start {
			return errors.New("source changed while connecting or before refresh")
		}
		return nil
	}
	if e = stable(); e != nil {
		return nil, e
	}
	if _, e = c.Call("initialize", map[string]any{"clientInfo": map[string]any{"name": "relay_mcp_health", "version": "0.1"}, "capabilities": map[string]any{"experimentalApi": true}}); e != nil {
		return nil, e
	}
	loadedResult, e := c.Call("thread/loaded/list", map[string]any{})
	if e != nil {
		return nil, e
	}
	loaded, e := arrayField(loadedResult, "data")
	if e != nil {
		return nil, e
	}
	if o.InspectLoaded {
		if len(loaded) > 100 {
			return nil, errors.New("loaded thread inventory exceeds limit")
		}
		threads := []any{}
		for _, id := range loaded {
			v, e := c.Call("thread/read", map[string]any{"threadId": id, "includeTurns": false})
			if e != nil {
				return nil, e
			}
			item, e := obj(v["thread"])
			if e != nil {
				return nil, e
			}
			if item["cwd"] == o.Cwd {
				threads = append(threads, map[string]any{"id": item["id"], "session_id": item["sessionId"], "cwd": item["cwd"], "status": item["status"], "forked_from": item["forkedFromId"]})
			}
		}
		return map[string]any{"loaded_count": len(loaded), "matching_directory_threads": threads}, nil
	}
	found := false
	for _, id := range loaded {
		if id == o.Thread {
			found = true
		}
	}
	if !found {
		return nil, errors.New("exact source thread is not loaded")
	}
	v, e := c.Call("thread/read", map[string]any{"threadId": o.Thread, "includeTurns": false})
	if e != nil {
		return nil, e
	}
	thread, e := obj(v["thread"])
	if e != nil {
		return nil, e
	}
	if thread["id"] != o.Thread || thread["cwd"] != o.Cwd {
		return nil, errors.New("thread identity or working directory changed")
	}
	if o.Refresh {
		owns, e := r.OwnsListener(o.PID, o.Socket)
		if e != nil {
			return nil, e
		}
		if !owns {
			return nil, errors.New("control listener does not belong to the exact source process")
		}
		status, _ := thread["status"].(map[string]any)
		if len(loaded) != 1 || loaded[0] != o.Thread || status["type"] != "idle" {
			return nil, errors.New("refresh requires the single intended idle thread")
		}
		start, checkErr := r.Start(o.PID)
		if checkErr != nil {
			return nil, checkErr
		}
		current, checkErr := r.PrivateSocket(o.Socket)
		if checkErr != nil {
			return nil, checkErr
		}
		if start != o.Start || current != identity {
			return nil, errors.New("source changed before refresh")
		}
		if _, e = c.Call("config/mcpServer/reload", map[string]any{}); e != nil {
			return nil, e
		}
	}
	result, e := c.Call("mcpServerStatus/list", map[string]any{"threadId": o.Thread, "serverName": o.Server, "limit": 100, "detail": "toolsAndAuthOnly"})
	if e != nil {
		return nil, e
	}
	rows, e := arrayField(result, "data")
	if e != nil {
		return nil, e
	}
	servers := []any{}
	for _, row := range rows {
		item, e := obj(row)
		if e != nil {
			return nil, e
		}
		count := 0
		if tools, present := item["tools"]; present {
			length, e := valueLength(tools)
			if e != nil {
				return nil, e
			}
			count = length
		}
		servers = append(servers, map[string]any{"name": item["name"], "runtime_status": item["runtimeStatus"], "tool_count": count, "tools_error": item["toolsError"], "auth_status": item["authStatus"]})
	}
	return map[string]any{"thread": o.Thread, "loaded_count": len(loaded), "refresh_requested": o.Refresh, "servers": servers, "next_cursor": result["nextCursor"]}, nil
}

func arrayField(m map[string]any, key string) ([]any, error) {
	v, present := m[key]
	if !present {
		return []any{}, nil
	}
	return array(v)
}
func valueLength(v any) (int, error) {
	switch x := v.(type) {
	case map[string]any:
		return len(x), nil
	case []any:
		return len(x), nil
	case string:
		return utf8.RuneCountInString(x), nil
	default:
		return 0, errors.New("sized tools value required")
	}
}

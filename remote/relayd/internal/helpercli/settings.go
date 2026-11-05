package helpercli

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

const settingsURL = "http://127.0.0.1:47471"
const settingsTokenHelper = "/Applications/Relay.app/Contents/MacOS/relay-mcp"

type UsageError struct{ Message string }

func (e *UsageError) Error() string { return e.Message }

type SettingsRequest func(context.Context, string, any, string) (any, error)
type SettingsDependencies struct {
	Request       SettingsRequest
	NativeRequest HostSettingsRequest
	UUID          func() (string, error)
	ReadFile      func(string) ([]byte, error)
}

func randomUUID() (string, error) {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		return "", e
	}
	b[6] = b[6]&15 | 64
	b[8] = b[8]&63 | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}
func boundedFile(path string, limit int) ([]byte, error) {
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	s, e := f.Stat()
	if e != nil {
		return nil, e
	}
	if !s.Mode().IsRegular() || s.Size() > int64(limit) {
		return nil, errors.New("file exceeds size limit or is not regular")
	}
	b, e := io.ReadAll(io.LimitReader(f, int64(limit)+1))
	if e != nil {
		return nil, e
	}
	if len(b) > limit {
		return nil, errors.New("file exceeds size limit")
	}
	return b, nil
}
func DefaultSettingsDependencies() SettingsDependencies {
	return SettingsDependencies{Request: settingsHTTP(settingsTokenHelper, settingsURL, nil), NativeRequest: nativeSettingsNode, UUID: randomUUID, ReadFile: func(p string) ([]byte, error) { return boundedFile(p, 32768) }}
}

type boundedOutput struct {
	bytes.Buffer
	limit int
}

func (b *boundedOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > b.limit {
		return 0, errors.New("helper output exceeds size limit")
	}
	return b.Buffer.Write(p)
}
func settingsHTTP(helper, base string, client *http.Client) SettingsRequest {
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("settings redirects are not permitted") }}
	}
	return func(ctx context.Context, method string, payload any, path string) (any, error) {
		tokenCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		cmd := exec.CommandContext(tokenCtx, helper, "--use-relay-token", "--print-http-headers")
		out := &boundedOutput{limit: 65537}
		cmd.Stdout = out
		if e := cmd.Run(); e != nil {
			return nil, errors.New("Relay token helper failed")
		}
		headers, e := jsonObject(out.Bytes(), 65537)
		if e != nil {
			return nil, e
		}
		authorization, ok := headers["Authorization"].(string)
		if !ok {
			return nil, errors.New("missing Authorization header")
		}
		var body io.Reader
		if payload != nil {
			b, e := json.Marshal(payload)
			if e != nil {
				return nil, e
			}
			body = bytes.NewReader(b)
		}
		requestCtx, cancelRequest := context.WithTimeout(ctx, 15*time.Second)
		defer cancelRequest()
		req, e := http.NewRequestWithContext(requestCtx, method, base+path, body)
		if e != nil {
			return nil, e
		}
		req.Header.Set("X-Relay-Token", strings.TrimPrefix(authorization, "Bearer "))
		req.Header.Set("Content-Type", "application/json")
		response, e := client.Do(req)
		if e != nil {
			return nil, e
		}
		defer response.Body.Close()
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			b, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
			return nil, fmt.Errorf("Relay rejected the settings request: %s", strings.ToValidUTF8(string(b), "�"))
		}
		b, e := io.ReadAll(io.LimitReader(response.Body, maxDocument+1))
		if e != nil {
			return nil, e
		}
		return decodeJSON(b, maxDocument)
	}
}

type settingsArgs struct {
	action, key, value, file, requestID, revision string
	help                                          bool
}

func parseSettings(args []string) (settingsArgs, error) {
	var a settingsArgs
	if len(args) == 0 {
		return a, errors.New("action required: get, schema, ai-status, ai-check, set, update")
	}
	if args[0] == "-h" || args[0] == "--help" {
		a.help = true
		return a, nil
	}
	a.action = args[0]
	switch a.action {
	case "get", "schema", "ai-status", "ai-check", "set", "update":
	default:
		return a, errors.New("unknown settings action")
	}
	var pos []string
	for i := 1; i < len(args); i++ {
		s := args[i]
		if s == "-h" || s == "--help" {
			a.help = true
			return a, nil
		}
		if s == "--" {
			pos = append(pos, args[i+1:]...)
			break
		}
		if strings.HasPrefix(s, "--") {
			key, val, has := strings.Cut(s, "=")
			if key != "--request-id" && key != "--expected-revision" && key != "--file" {
				return a, errors.New("unknown settings option")
			}
			if a.action != "set" && a.action != "update" || key == "--file" && a.action != "update" {
				return a, errors.New("option unavailable for action")
			}
			if !has {
				i++
				if i >= len(args) {
					return a, errors.New("option requires value")
				}
				val = args[i]
				if strings.HasPrefix(val, "-") && val != "-" {
					if _, err := decodeJSON([]byte(val), maxDocument); err != nil {
						return a, errors.New("option requires value")
					}
				}
			}
			switch key {
			case "--request-id":
				a.requestID = val
			case "--expected-revision":
				a.revision = val
			case "--file":
				a.file = val
			}
			continue
		}
		if strings.HasPrefix(s, "-") && s != "-" { // argparse accepts negative numeric positional values.
			if _, e := decodeJSON([]byte(s), 32768); e != nil {
				return a, errors.New("unknown settings option")
			}
		}
		pos = append(pos, s)
	}
	switch a.action {
	case "get":
		if len(pos) > 1 {
			return a, errors.New("get accepts one optional key")
		}
		if len(pos) == 1 {
			a.key = pos[0]
		}
	case "set":
		if len(pos) != 2 {
			return a, errors.New("set requires key and value")
		}
		a.key, a.value = pos[0], pos[1]
	case "update":
		if len(pos) != 0 || a.file == "" {
			return a, errors.New("update requires --file")
		}
	default:
		if len(pos) != 0 {
			return a, errors.New("unexpected positional argument")
		}
	}
	return a, nil
}
func RunSettings(ctx context.Context, args []string, stdout, stderr io.Writer, deps SettingsDependencies) error {
	if len(args) > 0 && args[0] == "host" {
		return RunHostSettings(ctx, args[1:], stdout, stderr, deps)
	}
	a, e := parseSettings(args)
	if e != nil {
		return &UsageError{Message: e.Error()}
	}
	if a.help {
		_, e = fmt.Fprintln(stdout, "Usage: relay-settings {get [key],schema,ai-status,ai-check,set key value,update --file PATH} [--request-id ID] [--expected-revision REV]")
		return e
	}
	if deps.Request == nil || deps.UUID == nil || deps.ReadFile == nil {
		return errors.New("settings dependencies unavailable")
	}
	if a.action == "ai-status" || a.action == "ai-check" {
		method, path := "GET", "/api/intelligence/status"
		if a.action == "ai-check" {
			method, path = "POST", "/api/intelligence/check"
		}
		v, e := deps.Request(ctx, method, nil, path)
		if e != nil {
			return e
		}
		return printJSON(stdout, v)
	}
	v, e := deps.Request(ctx, "GET", nil, "/api/settings")
	if e != nil {
		return e
	}
	current, ok := v.(map[string]any)
	if !ok {
		return errors.New("invalid settings response")
	}
	var result any
	switch a.action {
	case "schema":
		result, e = required(current, "definitions")
	case "get":
		result = current
		if a.key != "" {
			values, ok := current["values"].(map[string]any)
			if !ok {
				return errors.New("missing values")
			}
			result, e = required(values, a.key)
		}
	default:
		var changes any
		if a.action == "set" {
			value, err := decodeJSON([]byte(a.value), maxDocument)
			if err != nil {
				if json.Valid([]byte(a.value)) {
					return err
				}
				value = a.value
			}
			changes = map[string]any{a.key: value}
		} else {
			b, err := deps.ReadFile(a.file)
			if err != nil {
				return err
			}
			if len(b) > 32768 {
				return errors.New("Settings update file exceeds 32 KiB")
			}
			changes, e = decodeJSON(b, 32768)
			if e != nil {
				return e
			}
		}
		id := a.requestID
		if id == "" {
			id, e = deps.UUID()
			if e != nil {
				return e
			}
		}
		revision := any(a.revision)
		if a.revision == "" {
			revision, e = required(current, "revision")
			if e != nil {
				return e
			}
		}
		instance, e := required(current, "instance")
		if e != nil {
			return e
		}
		if _, e = fmt.Fprintln(stderr, "Settings request:", id); e != nil {
			return e
		}
		if _, e = fmt.Fprintln(stderr, "Expected revision:", revision); e != nil {
			return e
		}
		result, e = deps.Request(ctx, "POST", map[string]any{"instance": instance, "request_id": id, "expected_revision": revision, "changes": changes}, "/api/settings")
	}
	if e != nil {
		return e
	}
	return printJSON(stdout, result)
}

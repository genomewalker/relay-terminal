package main

// Miko uses the ordinary MCP dispatcher as a pure request compiler. This
// transport cannot contact a host: the app submits the resulting request
// through its own authenticated, assistant-attributed control route.
import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"sort"
	"strings"
	"unicode/utf8"
)

func mikoExcluded(name string) bool {
	if strings.HasPrefix(name, "relay_miko_") {
		return true
	}
	switch name {
	case "relay_ask_miko", "relay_register_caller", "relay_control_caller", "relay_begin_terminal_control", "relay_authorize_r_session", "relay_available_tools", "relay_call_tool", "relay_research_capability",
		// Miko does not broadcast yet; its catalog and card policy would need it first.
		"relay_broadcast_message":
		return true
	}
	return false
}

func mikoCatalog() []map[string]any {
	x, _, _ := (&server{}).handle(request{Method: "tools/list"})
	var out []map[string]any
	for _, entry := range x.(map[string]any)["tools"].([]any) {
		t := entry.(map[string]any)
		if mikoExcluded(t["name"].(string)) {
			continue
		}
		// A model cannot impersonate another caller by supplying credentials.
		delete(t["inputSchema"].(map[string]any)["properties"].(map[string]any), "caller_token")
		// Remote-host proposal polling is not a Miko (Mac-side) argument.
		delete(t["inputSchema"].(map[string]any)["properties"].(map[string]any), "proposal_id")
		// Required keys are a set; editor schemas assemble them from maps.
		if required, ok := t["inputSchema"].(map[string]any)["required"].([]string); ok {
			sort.Strings(required)
		}
		t["tier"] = "change"
		if t["annotations"].(map[string]any)["readOnlyHint"] == true && !mikoExecutes(t["name"].(string)) {
			t["tier"] = "read"
		}
		out = append(out, t)
	}
	return out
}

// Some legacy MCP execution schemas have a readOnly annotation. Miko must
// classify their effects rather than infer authority from that UI hint.
func mikoExecutes(name string) bool {
	switch name {
	case "relay_run_editor_selection", "relay_run_editor_file", "relay_run_project_file", "relay_run_r_code", "relay_pause_r_session":
		return true
	}
	return false
}

// Decode one unambiguous JSON value, rejecting duplicates at every depth.
func mikoJSON(data []byte) (any, error) {
	if len(data) > 65536 || !utf8.Valid(data) {
		return nil, errors.New("Miko input exceeds 64 KiB")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var value func(int) (any, error)
	value = func(depth int) (any, error) {
		if depth > 24 {
			return nil, errors.New("JSON nesting exceeds 24")
		}
		t, e := d.Token()
		if e != nil {
			return nil, e
		}
		if c, ok := t.(json.Delim); ok {
			switch c {
			case '{':
				m := map[string]any{}
				for d.More() {
					k, e := d.Token()
					if e != nil {
						return nil, e
					}
					key, ok := k.(string)
					if !ok {
						return nil, errors.New("object key required")
					}
					if _, ok := m[key]; ok {
						return nil, errors.New("duplicate key")
					}
					v, e := value(depth + 1)
					if e != nil {
						return nil, e
					}
					m[key] = v
				}
				end, e := d.Token()
				if e != nil || end != json.Delim('}') {
					return nil, errors.New("truncated object")
				}
				return m, nil
			case '[':
				a := []any{}
				for d.More() {
					v, e := value(depth + 1)
					if e != nil {
						return nil, e
					}
					a = append(a, v)
				}
				end, e := d.Token()
				if e != nil || end != json.Delim(']') {
					return nil, errors.New("truncated array")
				}
				return a, nil
			default:
				return nil, errors.New("unexpected delimiter")
			}
		}
		return t, nil
	}
	v, e := value(0)
	if e != nil {
		return nil, e
	}
	if _, e = d.Token(); e != io.EOF {
		return nil, errors.New("trailing JSON")
	}
	return v, nil
}

func mikoSchema(value any, schema map[string]any) error {
	fail := func() error { return errors.New("arguments must match the exact Relay schema") }
	if choices, ok := schema["enum"]; ok {
		found := false
		values := reflect.ValueOf(choices)
		if values.Kind() != reflect.Slice {
			return fail()
		}
		for i := 0; i < values.Len(); i++ {
			if reflect.DeepEqual(value, values.Index(i).Interface()) {
				found = true
			}
		}
		if !found {
			return fail()
		}
	}
	switch schema["type"] {
	case "object":
		m, ok := value.(map[string]any)
		if !ok {
			return fail()
		}
		p, _ := schema["properties"].(map[string]any)
		// The live catalog uses []string; decoded test schemas can use []any.
		switch keys := schema["required"].(type) {
		case []string:
			for _, k := range keys {
				if _, ok := m[k]; !ok {
					return fail()
				}
			}
		case []any:
			for _, k := range keys {
				if _, ok := m[k.(string)]; !ok {
					return fail()
				}
			}
		}
		for k, v := range m {
			if s, ok := p[k].(map[string]any); ok {
				if e := mikoSchema(v, s); e != nil {
					return e
				}
			} else if s, ok := p[k].(map[string]string); ok {
				ss := map[string]any{}
				for k, v := range s {
					ss[k] = v
				}
				if e := mikoSchema(v, ss); e != nil {
					return e
				}
			} else if schema["additionalProperties"] == false {
				return fail()
			}
		}
	case "string":
		str, ok := value.(string)
		if !ok {
			return fail()
		}
		if limit, ok := schema["maxLength"].(int); ok && utf8.RuneCountInString(str) > limit {
			return fail()
		}
	case "integer":
		n, ok := value.(json.Number)
		if !ok {
			return fail()
		}
		if _, e := n.Int64(); e != nil {
			return fail()
		}
	case "boolean":
		if _, ok := value.(bool); !ok {
			return fail()
		}
	case "array":
		a, ok := value.([]any)
		if !ok {
			return fail()
		}
		if s, ok := schema["items"].(map[string]any); ok {
			for _, v := range a {
				if e := mikoSchema(v, s); e != nil {
					return e
				}
			}
		}
	}
	return nil
}

type mikoPlan struct {
	Tool   string          `json:"tool"`
	Tier   string          `json:"tier"`
	Method string          `json:"method"`
	Path   string          `json:"path"`
	Body   json.RawMessage `json:"body"`
}
type mikoCapture struct {
	plan  *mikoPlan
	calls int
}

func (c *mikoCapture) RoundTrip(r *http.Request) (*http.Response, error) {
	c.calls++
	if c.calls != 1 || r.URL.Host != "miko.invalid" || !strings.HasPrefix(r.URL.Path, "/api/") {
		return nil, errors.New("not one Relay control request")
	}
	c.plan.Method = r.Method
	c.plan.Path = r.URL.RequestURI()
	c.plan.Body = json.RawMessage(`{}`)
	if r.Body != nil {
		b, e := io.ReadAll(io.LimitReader(r.Body, 262145))
		if e != nil || len(b) > 262144 {
			return nil, errors.New("request too large")
		}
		if len(b) > 0 {
			c.plan.Body = b
		}
	}
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: http.Header{}}, nil
}
func compileMikoPlan(data []byte) (*mikoPlan, error) {
	v, e := mikoJSON(data)
	if e != nil {
		return nil, e
	}
	m, ok := v.(map[string]any)
	if !ok || len(m) != 2 {
		return nil, errors.New("exact tool_name and arguments required")
	}
	n, ok := m["tool_name"].(string)
	if !ok {
		return nil, errors.New("exact tool name required")
	}
	args, ok := m["arguments"].(map[string]any)
	if !ok {
		return nil, errors.New("arguments object required")
	}
	var definition map[string]any
	for _, t := range mikoCatalog() {
		if t["name"] == n {
			definition = t
			break
		}
	}
	if definition == nil {
		return nil, errors.New("tool excluded or unknown")
	}
	if n == "relay_host_request" || n == "relay_workspace_request" {
		r, ok := args["request"].(map[string]any)
		if !ok {
			return nil, errors.New("host request object required")
		}
		if e := mikoHostArguments(r); e != nil {
			return nil, e
		}
	}
	if n == "relay_update_settings" {
		changes, _ := args["changes"].(map[string]any)
		for key := range changes {
			if strings.HasPrefix(key, "miko_") {
				return nil, errors.New("Miko security preferences are Settings-only")
			}
		}
	}
	if e := mikoSchema(args, definition["inputSchema"].(map[string]any)); e != nil {
		return nil, e
	}
	p := &mikoPlan{Tool: n, Tier: definition["tier"].(string)}
	capture := &mikoCapture{plan: p}
	s := &server{token: "pure-request-compiler", callerToken: "miko-compiler-shape-only", endpoint: "http://miko.invalid", client: &http.Client{Transport: capture}}
	params, _ := json.Marshal(map[string]any{"name": n, "arguments": args})
	_, code, detail := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || capture.calls != 1 || p.Path == "" {
		return nil, fmt.Errorf("Relay refused request: %s", detail)
	}
	return p, nil
}

func mikoCLI(mode string, in io.Reader, out io.Writer) error {
	if mode == "--miko-catalog" {
		return json.NewEncoder(out).Encode(mikoCatalog())
	}
	b, e := io.ReadAll(io.LimitReader(in, 65537))
	if e != nil {
		return e
	}
	p, e := compileMikoPlan(b)
	if e != nil {
		return e
	}
	return json.NewEncoder(out).Encode(p)
}

// Tool callers use this same finite operation namespace in RelaySidePanel.
// Nothing here can forward host_rotation, caller registration or agent_accounts.
func mikoHostArguments(r map[string]any) error {
	operation, ok := r["operation"].(string)
	if !ok {
		return errors.New("exact host operation required")
	}
	fields := map[string][]string{
		"capabilities": {}, "process_list": {},
		"exec":   {"job_id", "kind", "command", "argv", "cwd", "env", "stdin", "keep_stdin", "timeout_seconds"},
		"status": {"job_id", "stdout_offset", "stderr_offset", "wait_millis"},
		"input":  {"job_id", "stdin", "input_sequence", "close_stdin"}, "cancel": {"job_id"},
		"process_signal": {"process_pid", "process_start", "signal"},
		"file_stat":      {"path"}, "file_list": {"path", "version", "offset", "length"},
		"file_read":   {"path", "version", "offset", "length"},
		"file_write":  {"job_id", "path", "version", "data", "offset", "upload_size", "upload_sha256"},
		"file_verify": {"path", "version"}, "plugin": {"plugin"},
	}
	allowed, ok := fields[operation]
	if !ok {
		return errors.New("host operation not exposed to Miko")
	}
	for key := range r {
		if key == "operation" || key == "request_id" {
			continue
		}
		found := false
		for _, field := range allowed {
			if key == field {
				found = true
			}
		}
		if !found {
			return fmt.Errorf("unknown %s argument %s", operation, key)
		}
	}
	if operation == "plugin" {
		p, ok := r["plugin"].(map[string]any)
		if !ok {
			return errors.New("plugin object required")
		}
		allowed := map[string]bool{"all_users": true, "user": true, "cluster": true, "operation": true, "root": true, "path": true, "job_id": true, "stream": true, "script": true, "action_id": true, "confirmed": true, "transfer": true}
		for key := range p {
			if !allowed[key] {
				return errors.New("unknown plugin field")
			}
		}
	}
	return nil
}

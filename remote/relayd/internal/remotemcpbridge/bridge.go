package remotemcpbridge

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const ResponseLimit = 8 << 20

var uuid = regexp.MustCompile(`^[a-fA-F0-9-]{36}$`)
var callerPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
var paneRoute = regexp.MustCompile(`^/api/panes/([a-fA-F0-9-]{36})(/(viewport|editor|agent-binding|r-status|r-snapshot|input-request|input-direct|editor-selection|r-run-selection|r-run-file|r-run-project-file|editor-edit|editor-save|editor-receipt|r-authorize|r-run|r-result|r-pause))?$`)

type Desktop func(context.Context, string, string, []byte, string) (int, []byte, error)
type Bridge struct {
	Host, Token   string
	Desktop       Desktop
	mu            sync.Mutex
	receipts      map[string]bool
	mikoOwners    map[string]mikoOwner
	linkProposals map[string]linkProposalEntry
	workspaceReqs map[string]string
	now           func() time.Time
}
type rejection struct {
	status int
	body   []byte
}

func (r rejection) Error() string { return fmt.Sprintf("desktop rejected request (%d)", r.status) }
func New(host, token string, desktop Desktop) *Bridge {
	return &Bridge{Host: host, Token: token, Desktop: desktop, receipts: map[string]bool{}, mikoOwners: map[string]mikoOwner{}, linkProposals: map[string]linkProposalEntry{}, now: time.Now}
}
func object(v any) (map[string]any, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("object required")
	}
	return m, nil
}
func array(v any) ([]any, error) {
	a, ok := v.([]any)
	if !ok {
		return nil, errors.New("array required")
	}
	return a, nil
}
func stringValue(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}
func lower(v any) string { return strings.ToLower(stringValue(v)) }
func decode(raw []byte) (any, error) {
	if !utf8.Valid(raw) {
		return nil, errors.New("invalid JSON UTF-8")
	}
	var v any
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	if e := d.Decode(&v); e != nil {
		return nil, e
	}
	if e := d.Decode(new(any)); e != io.EOF {
		return nil, errors.New("trailing JSON")
	}
	return v, nil
}
func encode(v any) []byte { b, _ := json.Marshal(v); return b }
func (b *Bridge) forward(ctx context.Context, method, path string, body []byte, caller string) (int, []byte, error) {
	status, result, e := b.Desktop(ctx, method, path, body, caller)
	if e == nil && len(result) > ResponseLimit {
		return 502, []byte(`{"error":"Desktop response too large"}`), nil
	}
	return status, result, e
}
func (b *Bridge) State(ctx context.Context, caller string) (map[string]any, map[string]bool, map[string]string, error) {
	data, allowed, tabs, _, e := b.scopeState(ctx, caller)
	return data, allowed, tabs, e
}

// scopeState is State plus paneTab, which maps each allowed pane that sits in a
// whole-host tab to the first such tab holding it (a repeated tab ID replaces
// the earlier entry, keeping its position, as the Python bridge's dict does).
func (b *Bridge) scopeState(ctx context.Context, caller string) (map[string]any, map[string]bool, map[string]string, map[string]string, error) {
	data, allowed, tabscope, tabPanes, order, e := b.scopeStateInner(ctx, caller)
	if e != nil {
		return nil, nil, nil, nil, e
	}
	paneTab := map[string]string{}
	for _, id := range order {
		for pane := range tabPanes[id] {
			if _, seen := paneTab[pane]; !seen {
				paneTab[pane] = id
			}
		}
	}
	return data, allowed, tabscope, paneTab, nil
}
func (b *Bridge) scopeStateInner(ctx context.Context, caller string) (map[string]any, map[string]bool, map[string]string, map[string]map[string]bool, []string, error) {
	status, raw, e := b.forward(ctx, "GET", "/api/state", nil, caller)
	if e != nil {
		return nil, nil, nil, nil, nil, e
	}
	if status != 200 {
		return nil, nil, nil, nil, nil, rejection{status, raw}
	}
	v, e := decode(raw)
	if e != nil {
		return nil, nil, nil, nil, nil, e
	}
	data, e := object(v)
	if e != nil {
		return nil, nil, nil, nil, nil, e
	}
	sessions, e := array(data["sessions"])
	if e != nil {
		return nil, nil, nil, nil, nil, e
	}
	allowed := map[string]bool{}
	tabscope := map[string]string{}
	tabPanes := map[string]map[string]bool{}
	order := []string{}
	firstTab := ""
	keptSessions := []any{}
	for _, sv := range sessions {
		session, e := object(sv)
		if e != nil {
			return nil, nil, nil, nil, nil, e
		}
		tabs, e := array(session["tabs"])
		if e != nil {
			return nil, nil, nil, nil, nil, e
		}
		keptTabs := []any{}
		for _, tv := range tabs {
			tab, e := object(tv)
			if e != nil {
				return nil, nil, nil, nil, nil, e
			}
			panes, e := array(tab["panes"])
			if e != nil {
				return nil, nil, nil, nil, nil, e
			}
			kept := []any{}
			for _, pv := range panes {
				pane, e := object(pv)
				if e != nil {
					return nil, nil, nil, nil, nil, e
				}
				if pane["host"] == b.Host && (pane["contentKind"] == "terminal" || pane["contentKind"] == "editor") {
					id, ok := pane["id"].(string)
					if !ok {
						return nil, nil, nil, nil, nil, errors.New("pane ID required")
					}
					allowed[strings.ToLower(id)] = true
					kept = append(kept, pane)
				}
			}
			if len(panes) > 0 && len(kept) == len(panes) {
				id := lower(tab["id"])
				tabscope[id] = lower(session["id"])
				ids := map[string]bool{}
				for _, pv := range kept {
					ids[strings.ToLower(pv.(map[string]any)["id"].(string))] = true
				}
				if _, known := tabPanes[id]; !known {
					order = append(order, id)
				}
				tabPanes[id] = ids
				if firstTab == "" {
					firstTab = id
				}
			}
			tab["panes"] = kept
			if len(kept) > 0 {
				keptTabs = append(keptTabs, tab)
			}
		}
		session["tabs"] = keptTabs
		if len(keptTabs) > 0 {
			keptSessions = append(keptSessions, session)
		}
	}
	data["sessions"] = keptSessions
	if caller != "" {
		if len(tabscope) == 0 {
			return nil, nil, nil, nil, nil, rejection{403, []byte(`{"error":"No bound remote workspace available"}`)}
		}
		status, raw, e = b.forward(ctx, "POST", "/api/workspace/context", encode(map[string]any{"tab_id": firstTab}), caller)
		if e != nil {
			return nil, nil, nil, nil, nil, e
		}
		if status != 200 {
			return nil, nil, nil, nil, nil, rejection{status, raw}
		}
	}
	if !allowed[lower(data["selectedPaneID"])] {
		data["selectedPaneID"] = nil
	}
	return data, allowed, tabscope, tabPanes, order, nil
}
func pairMembers(link map[string]any) ([]any, bool) {
	members, ok := link["members"].([]any)
	return members, ok && len(members) == 2
}
func (b *Bridge) savedPair(ctx context.Context, source, target string, allowed map[string]bool, caller string) (bool, error) {
	if source == target || !allowed[source] {
		return false, nil
	}
	status, raw, e := b.forward(ctx, "GET", "/api/pane-links", nil, caller)
	if e != nil {
		return false, e
	}
	if status != 200 {
		return false, rejection{status, raw}
	}
	v, e := decode(raw)
	if e != nil {
		return false, e
	}
	data, e := object(v)
	if e != nil {
		return false, e
	}
	linksValue, present := data["links"]
	if !present {
		linksValue = []any{}
	}
	links, e := array(linksValue)
	if e != nil {
		return false, e
	}
	for _, v := range links {
		link, e := object(v)
		if e != nil {
			return false, e
		}
		members, ok := pairMembers(link)
		if !ok {
			continue
		}
		a, e := object(members[0])
		if e != nil {
			return false, e
		}
		c, e := object(members[1])
		if e != nil {
			return false, e
		}
		x, y := lower(a["paneID"]), lower(c["paneID"])
		if x == source && y == target || x == target && y == source {
			return true, nil
		}
	}
	return false, nil
}
func readBody(r *http.Request, limit int, message string) ([]byte, error) {
	size, e := strconv.ParseInt(r.Header.Get("Content-Length"), 10, 64)
	if r.Header.Get("Content-Length") == "" {
		size = r.ContentLength
		e = nil
	}
	if e != nil {
		return nil, e
	}
	if size < 1 || size > int64(limit) {
		return nil, rejection{413, encode(map[string]string{"error": message})}
	}
	raw, e := io.ReadAll(io.LimitReader(r.Body, size+1))
	if e != nil {
		return nil, e
	}
	if int64(len(raw)) != size {
		return nil, errors.New("incomplete or excess request body")
	}
	return raw, nil
}
func body(r *http.Request, limit int, message string) ([]byte, map[string]any, error) {
	raw, e := readBody(r, limit, message)
	if e != nil {
		return nil, nil, e
	}
	v, e := decode(raw)
	if e != nil {
		return nil, nil, e
	}
	obj, e := object(v)
	return raw, obj, e
}
func (b *Bridge) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" && r.Method != "POST" {
		http.Error(w, "Unsupported method", 501)
		return
	}
	status, result := b.Handle(r)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(result)))
	w.WriteHeader(status)
	_, _ = w.Write(result)
}
func deny(message string) (int, []byte, error) {
	return 403, encode(map[string]string{"error": message}), nil
}
func (b *Bridge) Handle(r *http.Request) (status int, result []byte) {
	defer func() {
		if recover() != nil {
			status = 503
			result = []byte(`{"error":"Bridge unavailable; inspect receipt before retrying an execution"}`)
		}
	}()
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("x-relay-token")), []byte(b.Token)) != 1 {
		return 401, []byte(`{"error":"Unauthorized"}`)
	}
	caller := r.Header.Get("X-Relay-Caller-Token")
	_, present := r.Header[http.CanonicalHeaderKey("X-Relay-Caller-Token")]
	if present && (caller == "" || len(caller) > 200 || !callerPattern.MatchString(caller)) {
		return 403, []byte(`{"error":"Invalid caller credential"}`)
	}
	status, result, e := b.route(r, caller)
	if e != nil {
		var reject rejection
		if errors.As(e, &reject) {
			return reject.status, reject.body
		}
		return 503, []byte(`{"error":"Bridge unavailable; inspect receipt before retrying an execution"}`)
	}
	return status, result
}
func (b *Bridge) route(r *http.Request, caller string) (int, []byte, error) {
	ctx := r.Context()
	data, allowed, tabs, paneTab, e := b.scopeState(ctx, caller)
	if e != nil {
		return 0, nil, e
	}
	method, path := r.Method, r.URL.RequestURI()
	var raw []byte
	var proposal map[string]any
	forward := func(m, p string, body []byte) (int, []byte, error) { return b.forward(ctx, m, p, body, caller) }
	switch {
	case method == "GET" && path == "/api/state":
		return 200, encode(data), nil
	case method == "GET" && path == "/api/control":
	case method == "POST" && (path == "/api/workspace/context" || path == "/api/workspace/host-request" || path == "/api/workspace/image" || path == "/api/host/request"):
		raw, proposal, e = body(r, 4194304, "Bounded workspace request required")
		if e != nil {
			if raw != nil && proposal == nil {
				return 400, []byte(`{"error":"Structured workspace request required"}`), nil
			}
			return 0, nil, e
		}
		if path == "/api/host/request" {
			if proposal["host"] != b.Host {
				return deny("Host is outside this bridge scope")
			}
		} else if _, ok := proposal["pane_id"]; path == "/api/workspace/context" && ok {
			if _, both := proposal["tab_id"]; both || !allowed[lower(proposal["pane_id"])] {
				return deny("Pane is outside this bridge scope")
			}
		} else if _, ok := tabs[lower(proposal["tab_id"])]; !ok {
			return deny("Tab is outside this bridge scope")
		}
		if path == "/api/workspace/context" && proposal["action"] == "bind" {
			return deny("Workspace binding requires desktop control")
		}
	case method == "POST" && path == "/api/workspace/apply":
		return b.workspaceApply(r, caller, allowed, tabs, paneTab)
	case method == "POST" && (path == "/api/workspace/stack-pane" || path == "/api/workspace/new-stacked-pane"):
		return b.workspaceStack(r, caller, path, allowed)
	case method == "POST" && path == "/api/workspace/tab-action":
		raw, proposal, e = body(r, 4096, "Bounded request required")
		if e != nil {
			return 0, nil, e
		}
		session, ok := tabs[lower(proposal["tabID"])]
		if !ok {
			return deny("Tab is outside this remote host scope")
		}
		action := proposal["action"]
		if action == "move" {
			target, ok := tabs[lower(proposal["targetTabID"])]
			if !ok || target != session {
				return deny("Move target must be in the same scoped Relay session")
			}
		} else if action != "rename" && action != "close" {
			return deny("Tab action outside bridge scope")
		}
	case method == "POST" && path == "/api/network/remote-peers":
		raw, proposal, e = body(r, 4096, "Bounded discovery request required")
		if e != nil {
			if raw != nil {
				return deny("Peer discovery is limited to this bridge SSH host")
			}
			return 0, nil, e
		}
		if len(proposal) != 1 || proposal["host"] != b.Host {
			return deny("Peer discovery is limited to this bridge SSH host")
		}
	case method == "GET" && (path == "/api/network/status" || path == "/api/network/links"):
		status, result, e := forward("GET", path, nil)
		if e != nil || status != 200 {
			return status, result, e
		}
		v, e := decode(result)
		if e != nil {
			return 0, nil, e
		}
		rows, e := array(v)
		if e != nil {
			return 0, nil, e
		}
		kept := []any{}
		for _, v := range rows {
			row, e := object(v)
			if e != nil {
				return 0, nil, e
			}
			if row["host"] == b.Host {
				kept = append(kept, row)
			}
		}
		return 200, encode(kept), nil
	case method == "GET" && path == "/api/network/local-peers":
		return deny("Use relay_discover_remote_peers with the bridge SSH host; local discovery refers to the Mac")
	case method == "POST" && path == "/api/network/request":
		raw, proposal, e = body(r, 4096, "Bounded network request required")
		if e != nil {
			if raw != nil {
				status, result, err := forward("GET", "/api/network/links", nil)
				if err != nil || status != 200 {
					return status, result, err
				}
			}
			return 0, nil, e
		}
		ok, e := b.linkAllowed(ctx, lower(proposal["linkID"]), caller)
		if e != nil {
			return 0, nil, e
		}
		if !ok {
			return deny("Link is outside this bridge host scope")
		}
	case method == "GET" && idRoute(path, "/api/network/receipts/"):
		status, result, e := forward("GET", path, nil)
		if e != nil || status != 200 {
			return status, result, e
		}
		v, e := decode(result)
		if e != nil {
			return 0, nil, e
		}
		receipt, e := object(v)
		if e != nil {
			return 0, nil, e
		}
		ok, e := b.linkAllowed(ctx, lower(receipt["linkID"]), caller)
		if e != nil {
			var reject rejection
			if !errors.As(e, &reject) {
				return 0, nil, e
			}
		}
		if e != nil || !ok {
			return deny("Network receipt is outside this bridge host scope")
		}
		return status, result, nil
	case method == "GET" && path == "/api/pane-links":
		status, result, e := forward("GET", path, nil)
		if e != nil || status != 200 {
			return status, result, e
		}
		v, e := decode(result)
		if e != nil {
			return 0, nil, e
		}
		obj, e := object(v)
		if e != nil {
			return 0, nil, e
		}
		links, e := array(obj["links"])
		if e != nil {
			return 0, nil, e
		}
		kept := []any{}
		for _, v := range links {
			link, e := object(v)
			if e != nil {
				return 0, nil, e
			}
			members, ok := pairMembers(link)
			if !ok {
				continue
			}
			for _, v := range members {
				member, e := object(v)
				if e != nil {
					return 0, nil, e
				}
				if allowed[lower(member["paneID"])] {
					kept = append(kept, link)
					break
				}
			}
		}
		return 200, encode(map[string]any{"links": kept}), nil
	case method == "POST" && (path == "/api/pane-links" || messageRoute(path)):
		raw, proposal, e = body(r, 70000, "Bounded messaging request required")
		if e != nil {
			return 0, nil, e
		}
		source := lower(proposal["sourcePaneID"])
		target := lower(proposal["paneID"])
		if path != "/api/pane-links" {
			target = strings.ToLower(strings.Split(path, "/")[3])
		}
		if source == target || !allowed[source] {
			return deny("Message source must be a distinct pane on this bridge host")
		}
		if !allowed[target] {
			ok := false
			if path != "/api/pane-links" {
				ok, e = b.savedPair(ctx, source, target, allowed, caller)
				if e != nil {
					return 0, nil, e
				}
			}
			if !ok && path != "/api/pane-links" {
				// relay-mcp started before relay_call_tool went to relayd
				// still sends here; the direct tool reaches relayd, which
				// delivers over a saved desktop or remote link.
				return deny("Cross-host messages require an explicitly saved pane pair. To answer a linked desktop session or a pane on another host, call `relay_message_pane` directly, not through `relay_call_tool`")
			}
			if !ok {
				return deny("Cross-host messages require an explicitly saved pane pair")
			}
		}
	case method == "GET" && idRoute(path, "/api/pane-messages/"):
		status, result, e := forward("GET", path, nil)
		if e != nil || status != 200 {
			return status, result, e
		}
		v, e := decode(result)
		if e != nil {
			return 0, nil, e
		}
		receipt, e := object(v)
		if e != nil {
			return 0, nil, e
		}
		source, target := lower(receipt["source_pane_id"]), lower(receipt["pane_id"])
		ok := allowed[source] && allowed[target]
		if !ok {
			ok, e = b.savedPair(ctx, source, target, allowed, caller)
			if e != nil {
				return 0, nil, e
			}
		}
		if !ok {
			return deny("Message receipt is outside this bridge host scope")
		}
		return status, result, nil
	case method == "POST" && path == mikoPath:
		return b.mikoAgent(r, caller, allowed)
	case method == "POST" && path == linkProposalPath:
		return b.linkProposal(r, caller, allowed)
	case method == "GET" && idRoute(path, "/api/input-receipts/"):
		id := strings.TrimPrefix(path, "/api/input-receipts/")
		b.mu.Lock()
		ok := b.receipts[id]
		b.mu.Unlock()
		if !ok {
			return deny("Receipt outside this bridge")
		}
	default:
		match := paneRoute.FindStringSubmatch(path)
		if match == nil || !allowed[strings.ToLower(match[1])] {
			return deny("Only this remote host terminal scope is allowed")
		}
		op := match[3]
		if method == "GET" && (op == "" || op == "viewport" || op == "editor" || op == "agent-binding" || op == "r-status") {
		} else if method == "POST" && contains([]string{"r-snapshot", "input-request", "input-direct", "editor-selection", "r-run-selection", "r-run-file", "r-run-project-file", "editor-edit", "editor-save", "editor-receipt", "r-authorize", "r-run", "r-result", "r-pause"}, op) {
			raw, proposal, e = body(r, 70000, "Bounded request required")
			if e != nil {
				return 0, nil, e
			}
			if op == "input-request" || op == "input-direct" {
				id, ok := proposal["requestID"].(string)
				if !ok || !uuid.MatchString(id) {
					return 400, []byte(`{"error":"Request identity required"}`), nil
				}
				b.mu.Lock()
				if len(b.receipts) >= 512 && !b.receipts[id] {
					b.mu.Unlock()
					return 429, []byte(`{"error":"Bridge request limit reached"}`), nil
				}
				b.receipts[id] = true
				b.mu.Unlock()
			}
		} else {
			return deny("Operation outside bridge scope")
		}
	}
	status, result, e := forward(method, path, raw)
	if e != nil {
		return 0, nil, e
	}
	if path == "/api/workspace/tab-action" && status == 200 {
		v, e := decode(result)
		if e != nil {
			return 502, []byte(`{"error":"Invalid tab action receipt"}`), nil
		}
		receipt, e := object(v)
		if e != nil {
			return 502, []byte(`{"error":"Invalid tab action receipt"}`), nil
		}
		delete(receipt, "selectedTabID")
		result = encode(receipt)
	}
	return status, result, nil
}
func contains(items []string, value string) bool {
	for _, item := range items {
		if value == item {
			return true
		}
	}
	return false
}
func idRoute(path, prefix string) bool {
	return strings.HasPrefix(path, prefix) && uuid.MatchString(strings.TrimPrefix(path, prefix))
}
func messageRoute(path string) bool {
	parts := strings.Split(path, "/")
	return len(parts) == 5 && parts[1] == "api" && parts[2] == "panes" && uuid.MatchString(parts[3]) && parts[4] == "message"
}
func (b *Bridge) linkAllowed(ctx context.Context, id, caller string) (bool, error) {
	status, raw, e := b.forward(ctx, "GET", "/api/network/links", nil, caller)
	if e != nil {
		return false, e
	}
	if status != 200 {
		return false, rejection{status, raw}
	}
	v, e := decode(raw)
	if e != nil {
		return false, e
	}
	rows, e := array(v)
	if e != nil {
		return false, e
	}
	for _, v := range rows {
		row, e := object(v)
		if e != nil {
			return false, e
		}
		if lower(row["id"]) == id && row["host"] == b.Host {
			return true, nil
		}
	}
	return false, nil
}

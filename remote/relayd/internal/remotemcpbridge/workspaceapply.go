package remotemcpbridge

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf8"
)

// Workspace creation routes. /api/workspace/apply mirrors the Python bridge:
// only newTab, splitRight and splitDown, from a pane whose whole tab is on this
// bridge's SSH host. Exact keys and string values, no duplicate keys, canonical
// UUIDs. The forwarded body always names this host and carries bridgeScope,
// which the desktop revalidates at mutation time. The stack routes add a
// host-scope check and a host-only bridgeScope; the desktop owns grants,
// instances, idempotency and the commit-time fence.

const workspaceRequestLimit = 512

var exactUUID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

type strictPair struct {
	key, value string
	isString   bool
}

// strictObject parses one top-level JSON object without collapsing duplicate
// keys. ok is false for anything that is not a single well-formed object.
func strictObject(raw []byte) (pairs []strictPair, ok bool) {
	if !utf8.Valid(raw) {
		return nil, false
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	if t, e := d.Token(); e != nil || t != json.Delim('{') {
		return nil, false
	}
	for d.More() {
		t, e := d.Token()
		key, isKey := t.(string)
		if e != nil || !isKey {
			return nil, false
		}
		var v json.RawMessage
		if e := d.Decode(&v); e != nil {
			return nil, false
		}
		p := strictPair{key: key}
		if len(v) > 0 && v[0] == '"' {
			if json.Unmarshal(v, &p.value) != nil {
				return nil, false
			}
			p.isString = true
		}
		pairs = append(pairs, p)
	}
	if t, e := d.Token(); e != nil || t != json.Delim('}') {
		return nil, false
	}
	if _, e := d.Token(); e != io.EOF {
		return nil, false
	}
	return pairs, true
}

// strictStrings applies the shared rules in the Python order: malformed (400),
// duplicates (403), then unknown keys and non-string values (403).
func strictStrings(raw []byte, allowedKeys []string, unknownMessage string) (map[string]string, int, string) {
	pairs, ok := strictObject(raw)
	if !ok {
		return nil, 400, "Structured workspace request required"
	}
	seen := map[string]bool{}
	for _, p := range pairs {
		if seen[p.key] {
			return nil, 403, "Duplicate workspace request field"
		}
		seen[p.key] = true
	}
	out := map[string]string{}
	for _, p := range pairs {
		if !contains(allowedKeys, p.key) || !p.isString {
			return nil, 403, unknownMessage
		}
		out[p.key] = p.value
	}
	return out, 0, ""
}

func jsonReply(status int, message string) (int, []byte, error) {
	return status, encode(map[string]string{"error": message}), nil
}

func (b *Bridge) remoteHostConfigured() bool { return b.Host != "" && b.Host != "This Mac" }

type bridgeScope struct {
	Host      string `json:"host"`
	TabID     string `json:"tabID"`
	SessionID string `json:"sessionID"`
}
type workspaceApplyBody struct {
	Instance       string      `json:"instance"`
	RequestID      string      `json:"requestID"`
	PaneID         string      `json:"paneID"`
	Action         string      `json:"action"`
	ConnectionHost string      `json:"connectionHost"`
	BridgeScope    bridgeScope `json:"bridgeScope"`
}

func (b *Bridge) workspaceApply(r *http.Request, caller string, allowed map[string]bool, tabs, paneTab map[string]string) (int, []byte, error) {
	raw, e := readBody(r, 4096, "Bounded workspace request required")
	if e != nil {
		return 0, nil, e
	}
	req, status, reason := strictStrings(raw, []string{"instance", "requestID", "paneID", "action", "connectionHost"},
		"Only instance, requestID, paneID, action and this host's connectionHost are allowed")
	if req == nil {
		return jsonReply(status, reason)
	}
	for _, k := range []string{"instance", "requestID", "paneID"} {
		if !exactUUID.MatchString(req[k]) {
			return jsonReply(403, "Exact instance, requestID and paneID required")
		}
	}
	if a := req["action"]; a != "newTab" && a != "splitRight" && a != "splitDown" {
		return jsonReply(403, "Only newTab, splitRight and splitDown are available through this bridge")
	}
	if !b.remoteHostConfigured() {
		return jsonReply(403, "Bridge host is not a remote host")
	}
	if h, present := req["connectionHost"]; present && h != b.Host {
		return jsonReply(403, "Connection target must be this bridge SSH host")
	}
	out := workspaceApplyBody{Instance: strings.ToLower(req["instance"]), RequestID: strings.ToLower(req["requestID"]),
		PaneID: strings.ToLower(req["paneID"]), Action: req["action"], ConnectionHost: b.Host}
	tab, ok := paneTab[out.PaneID]
	if !allowed[out.PaneID] || !ok {
		return jsonReply(403, "Pane is outside this remote host workspace scope")
	}
	fingerprint := strings.Join([]string{out.Instance, out.PaneID, out.Action, out.ConnectionHost}, "|")
	b.mu.Lock()
	if b.workspaceReqs == nil {
		b.workspaceReqs = map[string]string{}
	}
	old, known := b.workspaceReqs[out.RequestID]
	if known && old != fingerprint {
		b.mu.Unlock()
		return jsonReply(409, "Conflicting workspace request ID")
	}
	if !known && len(b.workspaceReqs) >= workspaceRequestLimit {
		b.mu.Unlock()
		return jsonReply(429, "Bridge request limit reached")
	}
	b.workspaceReqs[out.RequestID] = fingerprint
	b.mu.Unlock()
	out.BridgeScope = bridgeScope{Host: b.Host, TabID: tab, SessionID: tabs[tab]}
	return b.forward(r.Context(), "POST", "/api/workspace/apply", encode(out), caller)
}

type hostScope struct {
	Host string `json:"host"`
}
type stackPaneBody struct {
	Instance     string    `json:"instance"`
	RequestID    string    `json:"requestID"`
	PaneID       string    `json:"paneID"`
	TargetPaneID string    `json:"targetPaneID"`
	BridgeScope  hostScope `json:"bridgeScope"`
}
type newStackedPaneBody struct {
	Instance     string    `json:"instance"`
	RequestID    string    `json:"requestID"`
	TargetPaneID string    `json:"targetPaneID"`
	Host         string    `json:"host"`
	BridgeScope  hostScope `json:"bridgeScope"`
}

// workspaceStack gates stack-pane and new-stacked-pane on this bridge's host
// and forwards the four caller keys plus a host-only bridgeScope that the
// desktop re-checks at commit time.
func (b *Bridge) workspaceStack(r *http.Request, caller, path string, allowed map[string]bool) (int, []byte, error) {
	raw, e := readBody(r, 4096, "Bounded workspace request required")
	if e != nil {
		return 0, nil, e
	}
	if pairs, ok := strictObject(raw); ok {
		for _, p := range pairs {
			if p.key == "bridgeScope" {
				return jsonReply(400, "bridgeScope is set by the bridge")
			}
		}
	}
	keys := []string{"instance", "requestID", "paneID", "targetPaneID"}
	idKeys := keys
	if path == "/api/workspace/new-stacked-pane" {
		keys = []string{"instance", "requestID", "targetPaneID", "host"}
		idKeys = keys[:3]
	}
	req, status, reason := strictStrings(raw, keys, "Exactly "+strings.Join(keys, ", ")+" are allowed")
	if req == nil {
		return jsonReply(status, reason)
	}
	if len(req) != len(keys) {
		return jsonReply(403, "Exactly "+strings.Join(keys, ", ")+" are required")
	}
	for _, k := range idKeys {
		if !exactUUID.MatchString(req[k]) {
			return jsonReply(403, "Exact UUIDs required")
		}
	}
	if !b.remoteHostConfigured() {
		return jsonReply(403, "Bridge host is not a remote host")
	}
	if !allowed[strings.ToLower(req["targetPaneID"])] {
		return jsonReply(403, "Pane is outside this bridge scope")
	}
	scope := hostScope{Host: b.Host}
	var out any
	if path == "/api/workspace/stack-pane" {
		if !allowed[strings.ToLower(req["paneID"])] {
			return jsonReply(403, "Pane is outside this bridge scope")
		}
		out = stackPaneBody{req["instance"], req["requestID"], req["paneID"], req["targetPaneID"], scope}
	} else {
		if req["host"] != b.Host {
			return jsonReply(403, "New stacked panes are limited to this bridge SSH host")
		}
		out = newStackedPaneBody{req["instance"], req["requestID"], req["targetPaneID"], b.Host, scope}
	}
	return b.forward(r.Context(), "POST", path, encode(out), caller)
}

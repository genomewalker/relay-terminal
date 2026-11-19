package remotemcpbridge

import (
	"net/http"
	"strings"
)

// launchAgent passes relay_launch_agent for this bridge's host only. The
// calling pane (relay-mcp's own pane) must be on this host in a tab wholly on
// it, and any placement must stay in the caller's Relay session, so a remote
// agent can never start agents on the Mac or in another session. The app
// re-checks the injected bridgeScope against live state.
func (b *Bridge) launchAgent(r *http.Request, caller string, allowed map[string]bool, tabs, paneTab map[string]string) (int, []byte, error) {
	raw, e := readBody(r, 16384, "Bounded launch request required")
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
	required := []string{"instance", "requestID", "host", "cwd", "provider", "model", "account", "briefPath", "callerPaneID"}
	keys := append(append([]string{}, required...), "permissionMode", "targetPaneID", "anchorTabID", "anchorPaneID")
	req, status, reason := strictStrings(raw, keys, "Unknown relay_launch_agent field")
	if req == nil {
		return jsonReply(status, reason)
	}
	for _, k := range required {
		if req[k] == "" {
			return jsonReply(403, "A remote launch needs its calling pane and every required field")
		}
	}
	for _, k := range []string{"instance", "requestID", "callerPaneID"} {
		if !exactUUID.MatchString(req[k]) {
			return jsonReply(403, "Exact UUIDs required")
		}
	}
	if !b.remoteHostConfigured() || req["host"] != b.Host {
		return jsonReply(403, "A remote agent launches only on its bridge SSH host")
	}
	sessionOf := func(pane string) (string, bool) {
		pane = strings.ToLower(pane)
		if !allowed[pane] {
			return "", false
		}
		session, ok := tabs[paneTab[pane]]
		return session, ok
	}
	session, ok := sessionOf(req["callerPaneID"])
	if !ok {
		return jsonReply(403, "Calling pane is outside this bridge scope")
	}
	placements := 0
	for _, k := range []string{"targetPaneID", "anchorPaneID", "anchorTabID"} {
		value, present := req[k]
		if !present {
			continue
		}
		placements++
		var placed string
		var inScope bool
		if k == "anchorTabID" {
			placed, inScope = tabs[strings.ToLower(value)]
		} else {
			if !exactUUID.MatchString(value) {
				return jsonReply(403, "Exact UUIDs required")
			}
			placed, inScope = sessionOf(value)
		}
		if !inScope || placed != session {
			return jsonReply(403, "Placement must stay in the calling pane's session on this host")
		}
	}
	if placements > 1 {
		return jsonReply(403, "Give at most one placement")
	}
	out := map[string]any{}
	for k, v := range req {
		out[k] = v
	}
	out["bridgeScope"] = hostScope{Host: b.Host}
	return b.forward(r.Context(), "POST", "/api/workspace/launch-agent", encode(out), caller)
}

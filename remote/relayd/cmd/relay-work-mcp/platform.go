package main

import (
	"path/filepath"
	"strings"
)

// The Linux frontend is installed beside the stable Relay MCP alias in
// ~/.local/share/relay/bin, so the handler is resolved next to the frontend's
// own executable rather than from HOME or PATH.
func siblingHandler(executable string) string {
	return filepath.Join(filepath.Dir(executable), "relay-mcp-communication")
}

// A remote pane's Relay MCP environment carries the shared registered-client
// credential. Work sends must instead be attributed to the pane's own
// provisioned Work credential (kernel ancestry), so it never reaches the handler.
func withoutSharedCaller(environment []string) []string {
	out := make([]string, 0, len(environment))
	for _, value := range environment {
		if strings.HasPrefix(value, "RELAY_MCP_CALLER_TOKEN=") {
			continue
		}
		out = append(out, value)
	}
	return out
}

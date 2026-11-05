package main

import (
	"encoding/json"
	"os"
	"testing"
)

// A sender cannot claim its own permission class: only the sending host's
// relayd observes it, so the tool refuses the argument before any daemon call.
func TestCommunicationRejectsAClaimedPermissionClass(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	for _, key := range []string{"permissionClass", "permission_class", "from_mode"} {
		s, wire := fallbackHelper(t, 0, `{"status":"written_to_socket"}`, "")
		args := messageArgs()
		args[key], _ = json.Marshal("bypass")
		result, handled := s.daemonCommunication("relay_message_pane", args)
		if !handled || !result.(map[string]any)["isError"].(bool) {
			t.Fatalf("%s accepted: %v", key, result)
		}
		if _, err := os.Stat(wire); err == nil {
			t.Fatalf("%s reached relayd", key)
		}
	}
}

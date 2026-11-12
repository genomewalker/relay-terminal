package main

import "testing"

func TestRemoteWorkCLIIsTheInstalledAliasBesideRelayMCP(t *testing.T) {
	got := remoteWorkCLI("/maps/projects/x/.local/share/relay/bin/relay-mcp-linux-amd64")
	if got != "/maps/projects/x/.local/share/relay/bin/relayd-work-communication" {
		t.Fatal(got)
	}
}

package main

import (
	"reflect"
	"testing"
)

func TestLinuxHandlerIsTheSiblingRelayMCPAlias(t *testing.T) {
	got := siblingHandler("/maps/projects/x/.local/share/relay/bin/relay-work-mcp-linux-amd64")
	if got != "/maps/projects/x/.local/share/relay/bin/relay-mcp-communication" {
		t.Fatal(got)
	}
}

func TestSharedCallerTokenNeverReachesTheWorkHandler(t *testing.T) {
	in := []string{"HOME=/h", "RELAY_MCP_CALLER_TOKEN=secret", "RELAY_MCP_CALLER_TOKEN_X=keep", "RELAY_MCP_BACKEND=daemon"}
	got := withoutSharedCaller(in)
	want := []string{"HOME=/h", "RELAY_MCP_CALLER_TOKEN_X=keep", "RELAY_MCP_BACKEND=daemon"}
	if !reflect.DeepEqual(got, want) {
		t.Fatal(got)
	}
}

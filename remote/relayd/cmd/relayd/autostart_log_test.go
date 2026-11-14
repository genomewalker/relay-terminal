package main

import (
	"strings"
	"testing"
	"time"
)

// The line names the subcommand and where the client came from, and never a
// flag or argument value.
func TestAutoStartLineNamesCommandAndSourceButNoArguments(t *testing.T) {
	at := time.Date(2026, 11, 14, 9, 0, 0, 0, time.UTC)
	line := autoStartLine([]string{"/home/u/.local/share/relay/bin/relayd-linux-amd64", "node", "--token", "s3cret"},
		4242, 4200, "bash", "10.84.4.17 51234 22", "relayd", at)
	for _, want := range []string{"2026-11-14T09:00:00Z", "`relayd node`", "client pid 4242", "parent pid 4200 bash", "ssh from 10.84.4.17", "invoked as relayd"} {
		if !strings.Contains(line, want) {
			t.Errorf("missing %q in %q", want, line)
		}
	}
	for _, leak := range []string{"--token", "s3cret", "51234"} {
		if strings.Contains(line, leak) {
			t.Errorf("line carries %q: %q", leak, line)
		}
	}
	local := autoStartLine([]string{"relayd", "observe\nforged"}, 1, 2, "", "", "", at)
	if !strings.Contains(local, "local") || !strings.Contains(local, "parent pid 2 unknown") || strings.Contains(local, "\n") {
		t.Errorf("local line %q", local)
	}
}

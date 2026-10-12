package daemon

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectInvocationRejectsUnsafeEnvelope(t *testing.T) {
	for _, raw := range []string{
		`{}`, `{"argv":["echo"],"timeout_seconds":1}`, `{"argv":["/bin/echo"],"timeout_seconds":61}`,
		`{"argv":["/bin/echo"],"timeout_seconds":1,"unknown":true}`,
		`{"argv":["/bin/echo"],"timeout_seconds":1} {}`,
		`{"argv":["/bin/echo"],"environment":{"BAD=KEY":"x"},"timeout_seconds":1}`,
	} {
		if _, err := parseProjectInvocation(raw); err == nil {
			t.Fatal("accepted", raw)
		}
	}
}

func TestProjectCommandLiteralArgumentsAndNoReplay(t *testing.T) {
	root := t.TempDir()
	req := PluginRequest{Operation: "projectRun", Root: root, Confirmed: true, ActionID: testHPCAction,
		Script: `{"argv":["/bin/echo","$(touch should-not-exist)","a b"],"environment":{},"timeout_seconds":2}`}
	ledger := filepath.Join(t.TempDir(), "receipts")
	output, err := performHPCAction(req, ledger, pluginProjectCommand, ownedJob)
	if err != nil || !strings.Contains(output, "$(touch should-not-exist) a b") {
		t.Fatal(output, err)
	}
	if _, err := performHPCAction(req, ledger, pluginProjectCommand, ownedJob); err == nil {
		t.Fatal("replayed command")
	}
}

func TestProjectCommandDoesNotInheritCredentials(t *testing.T) {
	t.Setenv("RELAY_TEST_SECRET", "must-not-leak")
	output, err := pluginProjectCommand(t.TempDir(), "", `{"argv":["/usr/bin/env"],"environment":{"REVIEWED":"yes"},"timeout_seconds":2}`)
	if err != nil || strings.Contains(output, "RELAY_TEST_SECRET") || !strings.Contains(output, "REVIEWED=yes") {
		t.Fatal(output, err)
	}
}

func TestProjectCommandTimeout(t *testing.T) {
	_, err := pluginProjectCommand(t.TempDir(), "", `{"argv":["/bin/sleep","5"],"environment":{},"timeout_seconds":1}`)
	if err == nil {
		t.Fatal("timeout ignored")
	}
}

package agentlaunch

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const savedThread = "01a13c87-83d1-76f3-a38a-1b2f0953416e"

func writeRollout(t *testing.T, home, day, thread string, lines ...string) {
	t.Helper()
	directory := filepath.Join(home, "sessions", "2026", "10", day)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	body := `{"type":"session_meta","payload":{"id":"` + thread + `"}}` + "\n" + strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(filepath.Join(directory, "rollout-2026-10-"+day+"T00-27-56-"+thread+".jsonl"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func turnContext(approval, sandbox string) string {
	return `{"type":"turn_context","payload":{"turn_id":"t","approval_policy":"` + approval + `","sandbox_policy":{"type":"` + sandbox + `"}}}`
}

func TestCodexResumedThreadOnlyForExactResumeWithoutPermissionChoice(t *testing.T) {
	for _, argv := range [][]string{
		{"resume", savedThread},
		{"--cd", "/work", "--model", "gpt-rosalind-5.5", "-c", `model_reasoning_effort="xhigh"`, "resume", savedThread},
		{"--profile=relay-terminal", "resume", savedThread, "--", "prompt"},
	} {
		if thread, ok := CodexResumedThread(argv); !ok || thread != savedThread {
			t.Fatalf("%v: got %q %v", argv, thread, ok)
		}
	}
	for _, argv := range [][]string{
		{},
		{"--model", "gpt-6.1-sol"},
		{"resume", "--last"},
		{"resume", "not-a-thread"},
		{"--cd", "resume", "/work"},
		{"--dangerously-bypass-approvals-and-sandbox", "resume", savedThread},
		{"resume", savedThread, "-s", "read-only"},
		{"--sandbox=workspace-write", "resume", savedThread},
		{"-a", "never", "resume", savedThread},
		{"--full-auto", "resume", savedThread},
		{"-c", `sandbox_mode="read-only"`, "resume", savedThread},
		{"--config=approval_policy=\"never\"", "resume", savedThread},
		{"-c", "sandbox_workspace_write.network_access=true", "resume", savedThread},
		{"resume", savedThread, "resume", savedThread},
	} {
		if thread, ok := CodexResumedThread(argv); ok {
			t.Fatalf("%v: unexpectedly resolved %q", argv, thread)
		}
	}
}

func TestSavedCodexPermissionsUseLastTurnContext(t *testing.T) {
	home := t.TempDir()
	writeRollout(t, home, "15", savedThread,
		turnContext("on-request", "workspace-write"),
		`{"type":"event_msg","payload":{"type":"task_started"}}`,
		`not json`,
		turnContext("never", "danger-full-access"))
	permissions, err := SavedCodexPermissions(home, savedThread)
	if err != nil || permissions != (CodexPermissions{SandboxMode: "danger-full-access", ApprovalPolicy: "never"}) {
		t.Fatalf("got %#v %v", permissions, err)
	}
	expected := []string{"-c", `sandbox_mode="danger-full-access"`, "-c", `approval_policy="never"`}
	if got := permissions.AppServerArguments(); !reflect.DeepEqual(got, expected) {
		t.Fatalf("app server arguments %v", got)
	}

	// A later restricted turn is what the thread last ran with.
	writeRollout(t, home, "15", savedThread, turnContext("never", "danger-full-access"), turnContext("never", "read-only"))
	if permissions, err := SavedCodexPermissions(home, savedThread); err != nil || permissions.SandboxMode != "read-only" {
		t.Fatalf("got %#v %v", permissions, err)
	}
}

func TestSavedCodexPermissionsRefuseUnprovenRecords(t *testing.T) {
	other := "01a12f1b-7c35-7681-9f90-9ef906a1a59e"
	cases := map[string]func(home string){
		"missing":        func(string) {},
		"no turns":       func(home string) { writeRollout(t, home, "15", savedThread) },
		"unknown mode":   func(home string) { writeRollout(t, home, "15", savedThread, turnContext("never", "external-sandbox")) },
		"unknown policy": func(home string) { writeRollout(t, home, "15", savedThread, turnContext("sometimes", "read-only")) },
		"other thread":   func(home string) { writeRollout(t, home, "15", other, turnContext("never", "danger-full-access")) },
		"ambiguous": func(home string) {
			writeRollout(t, home, "14", savedThread, turnContext("never", "danger-full-access"))
			writeRollout(t, home, "15", savedThread, turnContext("never", "danger-full-access"))
		},
		"identity mismatch": func(home string) {
			directory := filepath.Join(home, "sessions", "2026", "10", "15")
			_ = os.MkdirAll(directory, 0o700)
			body := `{"type":"session_meta","payload":{"id":"` + other + `"}}` + "\n" + turnContext("never", "danger-full-access") + "\n"
			_ = os.WriteFile(filepath.Join(directory, "rollout-2026-10-15T00-27-56-"+savedThread+".jsonl"), []byte(body), 0o600)
		},
	}
	for name, setup := range cases {
		home := t.TempDir()
		setup(home)
		if permissions, err := SavedCodexPermissions(home, savedThread); err == nil {
			t.Fatalf("%s: accepted %#v", name, permissions)
		}
	}
	if _, err := SavedCodexPermissions("relative", savedThread); err == nil {
		t.Fatal("relative Codex home accepted")
	}
	if got := (CodexPermissions{SandboxMode: "danger-full-access", ApprovalPolicy: `never" -c x="y`}).AppServerArguments(); got != nil {
		t.Fatalf("unvalidated permissions produced arguments %v", got)
	}
	if got := (CodexPermissions{}).AppServerArguments(); got != nil {
		t.Fatalf("empty permissions produced arguments %v", got)
	}
}

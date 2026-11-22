package daemon

import (
	"encoding/json"
	"testing"
)

func TestPromptOwnerFallbackAdmitsOnlyAnUnnamedLiveFrontend(t *testing.T) {
	cases := []struct {
		name     string
		evidence promptOwnerEvidence
		want     promptOwnerChoice
	}{
		{"startup dialog with no records", promptOwnerEvidence{Provider: "claude", PID: 2125132}, promptOwnerPreSession},
		{"codex startup dialog with no records", promptOwnerEvidence{Provider: "codex", PID: 4242}, promptOwnerPreSession},
		// a83d388b: both records still name the previous Claude (607606).
		{"stale records for an earlier process", promptOwnerEvidence{Provider: "claude", PID: 2125132}, promptOwnerPreSession},
		{"verified bootstrap for this process", promptOwnerEvidence{Provider: "claude", PID: 7, BootstrapVerified: true, BootstrapNamesPID: true}, promptOwnerBootstrap},
		{"bootstrap conflicts with binding session", promptOwnerEvidence{Provider: "claude", PID: 7, BootstrapVerified: true, BootstrapNamesPID: true, SessionConflict: true}, promptOwnerRefuse},
		{"codex never uses a bootstrap", promptOwnerEvidence{Provider: "codex", PID: 7, BootstrapVerified: true}, promptOwnerRefuse},
		{"incomplete verified binding for this process", promptOwnerEvidence{Provider: "claude", PID: 7, RecordNamesPID: true, StoredNamesPID: true}, promptOwnerRefuse},
		{"unverifiable stored binding for this process", promptOwnerEvidence{Provider: "codex", PID: 7, StoredNamesPID: true}, promptOwnerRefuse},
		{"unverifiable bootstrap for this process", promptOwnerEvidence{Provider: "claude", PID: 7, BootstrapNamesPID: true}, promptOwnerRefuse},
		{"no frontend", promptOwnerEvidence{Provider: "claude", PID: 0}, promptOwnerRefuse},
		{"unknown provider", promptOwnerEvidence{Provider: "shell", PID: 7}, promptOwnerRefuse},
	}
	for _, test := range cases {
		if got := promptOwnerFallback(test.evidence); got != test.want {
			t.Errorf("%s: got %d, want %d", test.name, got, test.want)
		}
	}
}

// The Mac decodes exactly this JSON (RelayPromptOwnerBindingTests pins the
// same bytes): no session_id, input_only true, transcript_identity presession.
func TestPromptOwnerPreSessionWireShape(t *testing.T) {
	owner := PromptOwnerBinding{Version: 1, PaneID: "a83d388b-ec10-4776-af1e-398b8e5111d1", NodeBootID: "kernel-boot",
		WorkerPID: 100, WorkerStart: 1001, ShellPID: 101, ShellStart: 1002, Provider: "claude",
		ProcessID: 102, ProcessStart: 1003, TranscriptIdentity: PromptOwnerPreSessionIdentity, InputOnly: true}
	data, err := json.Marshal(owner)
	if err != nil {
		t.Fatal(err)
	}
	const want = `{"version":1,"pane_id":"a83d388b-ec10-4776-af1e-398b8e5111d1","node_boot_id":"kernel-boot","worker_pid":100,"worker_start":1001,"shell_pid":101,"shell_start":1002,"provider":"claude","process_id":102,"process_start":1003,"transcript_identity":"presession","input_only":true}`
	if string(data) != want {
		t.Fatalf("wire shape changed:\n got %s\nwant %s", data, want)
	}
}

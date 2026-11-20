package daemon

import (
	"testing"
	"time"
)

func TestVerifiedClaudeLifecycleKeepsNativeIdentityAndHookObservation(t *testing.T) {
	started := time.Date(2026, 11, 20, 15, 0, 0, 0, time.UTC)
	live := AgentBindingRecord{
		Version: 1, Source: "native_registration_kernel_owner", Revision: "live-revision",
		Producer:  agentProducer{PaneID: "pane", Provider: "claude", ProcessID: 22, ProcessStart: 77, ConfigDir: "/claude"},
		SessionID: "session", TranscriptPath: "/claude/projects/project/session.jsonl",
		ObservedAt: started.Add(time.Hour), Lifecycle: "unknown",
	}
	stored := live
	stored.Producer.SenderPID = 33
	stored.Source = ""
	stored.Revision = "hook-revision"
	stored.ObservedAt = started.Add(time.Minute)

	for _, lifecycle := range []string{"stop_observed", "quiet", "needs_input", "active", "exited"} {
		t.Run(lifecycle, func(t *testing.T) {
			stored.Lifecycle = lifecycle
			want := live
			want.Lifecycle = lifecycle
			want.ObservedAt = stored.ObservedAt
			if got := withVerifiedClaudeLifecycle(live, stored, started); got != want {
				t.Fatalf("expected native identity and original hook observation: got %+v, want %+v", got, want)
			}
		})
	}
	stored.Lifecycle = "quiet"
	for name, change := range map[string]func(*AgentBindingRecord){
		"missing record":       func(r *AgentBindingRecord) { *r = AgentBindingRecord{} },
		"version":              func(r *AgentBindingRecord) { r.Version = 2 },
		"source":               func(r *AgentBindingRecord) { r.Source = "native_registration_kernel_owner" },
		"missing sender":       func(r *AgentBindingRecord) { r.Producer.SenderPID = 0 },
		"missing revision":     func(r *AgentBindingRecord) { r.Revision = "" },
		"provider":             func(r *AgentBindingRecord) { r.Producer.Provider = "codex" },
		"pane":                 func(r *AgentBindingRecord) { r.Producer.PaneID = "other-pane" },
		"pid":                  func(r *AgentBindingRecord) { r.Producer.ProcessID++ },
		"reused pid":           func(r *AgentBindingRecord) { r.Producer.ProcessStart++ },
		"account":              func(r *AgentBindingRecord) { r.Producer.ConfigDir = "" },
		"session":              func(r *AgentBindingRecord) { r.SessionID = "other-session" },
		"transcript":           func(r *AgentBindingRecord) { r.TranscriptPath = "/other/path.jsonl" },
		"missing timestamp":    func(r *AgentBindingRecord) { r.ObservedAt = time.Time{} },
		"prior incarnation":    func(r *AgentBindingRecord) { r.ObservedAt = started.Add(-time.Nanosecond) },
		"future timestamp":     func(r *AgentBindingRecord) { r.ObservedAt = live.ObservedAt.Add(time.Nanosecond) },
		"unknown lifecycle":    func(r *AgentBindingRecord) { r.Lifecycle = "unknown" },
		"unexpected lifecycle": func(r *AgentBindingRecord) { r.Lifecycle = "idle" },
	} {
		t.Run(name, func(t *testing.T) {
			bad := stored
			change(&bad)
			if got := withVerifiedClaudeLifecycle(live, bad, started); got != live {
				t.Fatalf("mismatched telemetry changed live binding: %+v", got)
			}
		})
	}
	if got := withVerifiedClaudeLifecycle(live, stored, time.Time{}); got != live {
		t.Fatalf("missing kernel incarnation time allowed hook telemetry: %+v", got)
	}
}

package daemon

import (
	"testing"
	"time"
)

// A subagent or compaction event must not erase the main turn's lifecycle,
// but only the same process incarnation and session may pass it on.
func TestCarriedLifecycleOnlyFromSameIncarnationAndSession(t *testing.T) {
	directory := t.TempDir()
	producer := agentProducer{PaneID: "pane", Provider: "claude", ProcessID: 22, ProcessStart: 77, SenderPID: 33, ConfigDir: "/claude"}
	observed := time.Now().UTC().Add(-time.Minute).Truncate(time.Microsecond)
	write := func(change func(map[string]any)) {
		record := map[string]any{"version": 1, "producer": producer, "session_id": "session", "transcript_path": "/claude/t.jsonl",
			"lifecycle": "stop_observed", "revision": "r", "observed_at": observed.Format(time.RFC3339Nano)}
		if change != nil {
			change(record)
		}
		if err := writeBindingRecord(directory, "pane", record); err != nil {
			t.Fatal(err)
		}
	}
	write(nil)
	got, ok := carriedLifecycle(directory, producer, "session")
	if !ok || got.Lifecycle != "stop_observed" || !got.ObservedAt.Equal(observed) {
		t.Fatalf("same incarnation lost its lifecycle: %+v %v", got, ok)
	}
	if _, ok := carriedLifecycle(directory, producer, "other-session"); ok {
		t.Fatal("another session inherited the lifecycle")
	}
	for name, other := range map[string]agentProducer{
		"reused pid": {PaneID: "pane", Provider: "claude", ProcessID: 22, ProcessStart: 78, ConfigDir: "/claude"},
		"other pid":  {PaneID: "pane", Provider: "claude", ProcessID: 23, ProcessStart: 77, ConfigDir: "/claude"},
		"account":    {PaneID: "pane", Provider: "claude", ProcessID: 22, ProcessStart: 77, ConfigDir: "/other"},
		"provider":   {PaneID: "pane", Provider: "codex", ProcessID: 22, ProcessStart: 77, ConfigDir: "/claude"},
	} {
		if _, ok := carriedLifecycle(directory, other, "session"); ok {
			t.Errorf("%s inherited the lifecycle", name)
		}
	}
	for _, lifecycle := range []string{"exited", "unknown", "idle"} {
		write(func(r map[string]any) { r["lifecycle"] = lifecycle })
		if _, ok := carriedLifecycle(directory, producer, "session"); ok {
			t.Errorf("lifecycle %q was carried", lifecycle)
		}
	}
	write(func(r map[string]any) { r["observed_at"] = time.Now().Add(time.Hour).Format(time.RFC3339Nano) })
	if _, ok := carriedLifecycle(directory, producer, "session"); ok {
		t.Error("a future observation was carried")
	}
	if _, ok := carriedLifecycle(t.TempDir(), producer, "session"); ok {
		t.Error("a missing record produced a lifecycle")
	}
}

// Before the launch SessionStart was mapped, an idle resumed Claude kept the
// "unknown" written at launch forever.
func TestLaunchUnknownLifecycleIsTheLaunchPrompt(t *testing.T) {
	started := time.Date(2026, 11, 20, 15, 0, 0, 0, time.UTC)
	live := AgentBindingRecord{
		Version: 1, Source: "native_registration_kernel_owner", Revision: "live-revision",
		Producer:  agentProducer{PaneID: "pane", Provider: "claude", ProcessID: 22, ProcessStart: 77, ConfigDir: "/claude"},
		SessionID: "session", TranscriptPath: "/claude/projects/project/session.jsonl",
		ObservedAt: started.Add(72 * time.Hour), Lifecycle: "unknown",
	}
	stored := live
	stored.Producer.SenderPID = 33
	stored.Source = ""
	stored.Revision = "hook-revision"
	stored.ObservedAt = started.Add(10 * time.Second)
	got := withVerifiedClaudeLifecycle(live, stored, started)
	if got.Lifecycle != "stop_observed" || !got.ObservedAt.Equal(stored.ObservedAt) {
		t.Fatalf("launch record was not the launch prompt: %+v", got)
	}
	for name, at := range map[string]time.Time{
		"after the launch window": started.Add(claudeLaunchHookWindow),
		"days later":              started.Add(48 * time.Hour),
		"before the process":      started.Add(-time.Second),
	} {
		late := stored
		late.ObservedAt = at
		if got := withVerifiedClaudeLifecycle(live, late, started); got != live {
			t.Errorf("%s: unknown became %q", name, got.Lifecycle)
		}
	}
	if got := withVerifiedClaudeLifecycle(live, stored, time.Time{}); got != live {
		t.Error("missing process start time allowed the launch rule")
	}
	other := stored
	other.SessionID = "other-session"
	if got := withVerifiedClaudeLifecycle(live, other, started); got != live {
		t.Error("a launch record of another session applied")
	}
}

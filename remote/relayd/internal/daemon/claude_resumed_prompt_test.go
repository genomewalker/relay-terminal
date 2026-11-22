package daemon

import (
	"os"
	"reflect"
	"testing"
	"time"
)

// On 2026-11-20 an operator moved two Convergence panes by relaunching them as
// `claude ... --resume <session> "<note>"`. The proof refused every resumed
// launch, so both could never be moved again (2026-11-22, f62dee0f and
// 10c81cc6). A resume of the bound session whose note was submitted by this
// process and completed is now eligible; everything else still refuses.

func resumedRow(kind, text, stop string, at time.Time) map[string]any {
	row := initialRow(kind, text, stop)
	row["timestamp"] = at.UTC().Format(time.RFC3339Nano)
	return row
}

func resumedProof(path, revision string, args []string, started time.Time) *phClaudeInitialPromptProof {
	return phProveClaudeInitialPromptSince(path, initialSession, args, revision, os.Getuid(), true, started)
}

func TestClaudeResumedPromptIncorporatedAfterStart(t *testing.T) {
	started := time.Now().Add(-time.Hour)
	old := started.Add(-48 * time.Hour)
	note := "Note from the user: this conversation was moved. Reply with one line, then wait."
	tool := resumedRow("user", "", "", started.Add(2*time.Minute))
	tool["message"].(map[string]any)["content"] = []any{map[string]any{"type": "tool_result", "tool_use_id": "t", "content": "ok"}}
	compact := resumedRow("user", "summary", "", old.Add(time.Hour))
	compact["isCompactSummary"] = true
	path, revision := initialTranscript(t,
		resumedRow("user", "original work", "", old), resumedRow("assistant", "done", "end_turn", old),
		compact, // history before the note may be compacted
		resumedRow("user", note, "", started.Add(time.Minute)),
		resumedRow("assistant", "tool", "tool_use", started.Add(time.Minute)), tool,
		resumedRow("assistant", "Acknowledged.", "end_turn", started.Add(3*time.Minute)),
		resumedRow("user", "later work", "", started.Add(10*time.Minute)),
		resumedRow("assistant", "done", "end_turn", started.Add(11*time.Minute)))
	launcher := []string{"relayd", "agent", "claude"}
	for _, args := range [][]string{
		{"claude", "--settings", "/h.json", "--dangerously-skip-permissions", "--model", "opus", "--resume", initialSession, note},
		{"claude", "--model", "opus", "-r", initialSession, note},
		{"claude", "--model", "opus", "--resume=" + initialSession, note},
	} {
		proof := resumedProof(path, revision, args, started)
		got := phShlexSplit(phClaudeResumeCommandWithPrompt(args, initialSession, launcher, "", proof))
		for _, word := range got {
			if word == note {
				t.Fatalf("note replayed: %q", got)
			}
		}
		if got[len(got)-2] != "--resume" || got[len(got)-1] != initialSession {
			t.Fatalf("session not resumed exactly once: %q", got)
		}
		resumes := 0
		for _, word := range got {
			if word == "--resume" || word == "-r" {
				resumes++
			}
		}
		if resumes != 1 {
			t.Fatalf("resume selector repeated: %q", got)
		}
	}
	want := []string{"relayd", "agent", "claude", "--model", "opus", "--resume", initialSession}
	args := []string{"claude", "--model", "opus", "-r", initialSession, note}
	if got := phShlexSplit(phClaudeResumeCommandWithPrompt(args, initialSession, launcher, "", resumedProof(path, revision, args, started))); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q", got)
	}
}

func TestClaudeResumedPromptRefusesUnprovenShapes(t *testing.T) {
	started := time.Now().Add(-time.Hour)
	note := "a one-off note"
	before := started.Add(-10 * time.Minute)
	after := started.Add(time.Minute)
	done := func(at time.Time) map[string]any { return resumedRow("assistant", "ok", "end_turn", at) }
	args := []string{"claude", "--resume", initialSession, note}
	compactMid := resumedRow("user", "summary", "", after)
	compactMid["isCompactSummary"] = true
	cases := map[string][]map[string]any{
		// An older matching turn cannot stand in for a still-pending prompt.
		"only_before_process_start": {resumedRow("user", note, "", before), done(before)},
		"twice":                     {resumedRow("user", note, "", after), done(after), resumedRow("user", note, "", after), done(after)},
		// A transcript ending at the pending note refuses even when idle.
		"pending_at_end":              {resumedRow("user", note, "", after)},
		"pending_mid_tool":            {resumedRow("user", note, "", after), resumedRow("assistant", "tool", "tool_use", after)},
		"next_prompt_before_done":     {resumedRow("user", note, "", after), resumedRow("user", "other", "", after), done(after)},
		"compaction_before_done":      {resumedRow("user", note, "", after), compactMid, done(after)},
		"not_present":                 {resumedRow("user", "something else", "", after), done(after)},
		"trimmed_text_is_not_a_match": {resumedRow("user", " "+note+" ", "", after), done(after)},
	}
	other := resumedRow("user", note, "", after)
	other["sessionId"] = "other-session"
	cases["note_in_other_session"] = []map[string]any{other, done(after)}
	for name, rows := range cases {
		t.Run(name, func(t *testing.T) {
			path, rev := initialTranscript(t, rows...)
			mrRaise(t, "not verified", func() { resumedProof(path, rev, args, started) })
		})
	}
	good := []map[string]any{resumedRow("user", note, "", after), done(after)}
	path, rev := initialTranscript(t, good...)
	if resumedProof(path, rev, args, started) == nil {
		t.Fatal("good shape refused")
	}
	for name, argv := range map[string][]string{
		"other_session":       {"claude", "--resume", "other-session", note},
		"two_selectors":       {"claude", "--resume", initialSession, "-r", initialSession, note},
		"fork":                {"claude", "--resume", initialSession, "--fork-session", note},
		"continue":            {"claude", "--continue", "--resume", initialSession, note},
		"session_id":          {"claude", "--session-id", initialSession, "--resume", initialSession, note},
		"selector_value_last": {"claude", note, "--resume", initialSession},

		"no_prompt": {"claude", "--resume", initialSession},
	} {
		t.Run("argv_"+name, func(t *testing.T) {
			mrRaise(t, "not verified", func() { resumedProof(path, rev, argv, started) })
		})
	}
	// A joined short form (-r<id>) is not a recognised selector. On a real
	// resumed transcript the note is not the first turn, so the original-launch
	// proof refuses; and even where it were the first turn, the resume builder
	// refuses the unknown argument as a custom launch.
	t.Run("short_form_joined", func(t *testing.T) {
		joined := []string{"claude", "-r" + initialSession, note}
		history, histRev := initialTranscript(t, resumedRow("user", "original work", "", before), done(before),
			resumedRow("user", note, "", after), done(after))
		mrRaise(t, "not verified", func() { resumedProof(history, histRev, joined, started) })
		proof := resumedProof(path, rev, joined, started)
		mrRaise(t, "custom Claude launch", func() {
			phClaudeResumeCommandWithPrompt(joined, initialSession, []string{"relayd", "agent", "claude"}, "", proof)
		})
	})
	t.Run("no_process_start", func(t *testing.T) {
		mrRaise(t, "not verified", func() { resumedProof(path, rev, args, time.Time{}) })
	})
	t.Run("not_idle", func(t *testing.T) {
		mrRaise(t, "not verified", func() {
			phProveClaudeInitialPromptSince(path, initialSession, args, rev, os.Getuid(), false, started)
		})
	})
	t.Run("stale_revision", func(t *testing.T) {
		mrRaise(t, "not verified", func() { resumedProof(path, "stale", args, started) })
	})
	t.Run("old_api_still_refuses_resume", func(t *testing.T) {
		mrRaise(t, "not verified", func() { initialProof(path, rev, args) })
	})
}

// On 2026-11-22 f62dee0f and 10c81cc6 still refused after the resumed-prompt
// proof shipped: Claude auto-compacted the large conversation right after the
// note arrived, then answered it. The post-compaction API request blob ended
// with the note verbatim. Shape taken from that transcript, content replaced.
func TestClaudeResumedPromptSurvivesCompactionCarriedByRequestBlob(t *testing.T) {
	started := time.Now().Add(-time.Hour)
	after := started.Add(time.Minute)
	note := "Note from the user: this conversation was moved. Reply with one line, then wait."
	args := []string{"claude", "--settings", "/h.json", "--model", "opus", "--resume", initialSession, note}
	boundary := func(at time.Time) map[string]any {
		return map[string]any{"type": "system", "subtype": "compact_boundary", "sessionId": initialSession,
			"timestamp": at.UTC().Format(time.RFC3339Nano)}
	}
	summary := func(at time.Time) map[string]any {
		row := resumedRow("user", "This session is being continued from a previous conversation.", "", at)
		row["isCompactSummary"], row["isVisibleInTranscriptOnly"] = true, true
		return row
	}
	blob := func(session string, texts ...string) map[string]any {
		var blocks []any
		for _, text := range texts {
			blocks = append(blocks, map[string]any{"type": "text", "text": text})
		}
		return map[string]any{"type": "api-request-blob", "sessionId": session,
			"message": map[string]any{"role": "user", "content": blocks}}
	}
	turnDone := map[string]any{"type": "system", "subtype": "turn_duration", "sessionId": initialSession}
	noteRow := resumedRow("user", note, "", after)
	reply := resumedRow("assistant", "Acknowledged.", "end_turn", after.Add(time.Minute))
	accepted := []map[string]any{noteRow, boundary(after), summary(after),
		blob(initialSession, "<system-reminder>context</system-reminder>", "summary", note), reply, turnDone}
	path, rev := initialTranscript(t, accepted...)
	proof := resumedProof(path, rev, args, started)
	if proof == nil || proof.text != note {
		t.Fatalf("proof %+v", proof)
	}

	refuse := map[string][]map[string]any{
		"no_blob":             {noteRow, boundary(after), summary(after), reply, turnDone},
		"blob_last_differs":   {noteRow, boundary(after), summary(after), blob(initialSession, note, "something else"), reply},
		"blob_before_compact": {noteRow, blob(initialSession, note), boundary(after), summary(after), reply},
		"blob_other_session":  {noteRow, boundary(after), summary(after), blob("other-session", note), reply},
		"second_compact_without_new_blob": {noteRow, boundary(after), summary(after), blob(initialSession, note),
			boundary(after), summary(after), reply},
		"boundary_only_no_blob": {noteRow, boundary(after), turnDone},
	}
	sidechain := blob(initialSession, note)
	sidechain["isSidechain"] = true
	refuse["blob_sidechain"] = []map[string]any{noteRow, boundary(after), summary(after), sidechain, reply}
	for name, rows := range refuse {
		t.Run(name, func(t *testing.T) {
			path, rev := initialTranscript(t, rows...)
			mrRaise(t, "not verified", func() { resumedProof(path, rev, args, started) })
		})
	}
	t.Run("second_compact_with_new_blob", func(t *testing.T) {
		path, rev := initialTranscript(t, noteRow, boundary(after), summary(after), blob(initialSession, note),
			boundary(after), summary(after), blob(initialSession, "summary", note), reply)
		if resumedProof(path, rev, args, started) == nil {
			t.Fatal("no proof")
		}
	})
}

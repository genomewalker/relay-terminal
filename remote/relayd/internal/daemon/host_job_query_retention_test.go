package daemon

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

const appRelayd = `'/Applications/Relay.app/Contents/MacOS/relayd'`

func TestHostJobQueryRetentionRecognisesOnlyAppQueries(t *testing.T) {
	poll := []byte(`{"operation":"route_desktop_link_list"}`)
	remoteCommunication := hostJobQueryHelperPrefix + `"$HOME/.local/bin/relayd" 'communication'` + hostJobQueryHelperSuffix
	cases := []struct {
		name  string
		r     hostRequest
		query bool
	}{
		{"local link poll", hostRequest{Command: appRelayd + ` 'communication'`, Stdin: poll}, true},
		{"remote link poll", hostRequest{Command: remoteCommunication, Stdin: poll}, true},
		{"remote notices", hostRequest{Command: remoteCommunication, Stdin: []byte(`{"operation":"question_notices","pane_ids":[]}`)}, true},
		{"agent binding", hostRequest{Command: appRelayd + ` 'agent-binding' '8307c1b8-1d4d-4d86-86ea-86420af8ac8b'`}, true},
		{"remote agent binding", hostRequest{Command: `"$HOME/.local/bin/relayd" 'agent-binding' '--native' 'abc'`}, true},
		{"maintenance", hostRequest{Command: appRelayd + ` 'agent-maintenance' '--pane' 'abc' '--expect-account' '~/.claude-max'`}, true},
		{"quoted escape", hostRequest{Command: appRelayd + ` 'agent-binding' 'it'\''s'`}, true},

		{"send", hostRequest{Command: appRelayd + ` 'communication'`, Stdin: []byte(`{"operation":"send"}`)}, false},
		{"no operation", hostRequest{Command: appRelayd + ` 'communication'`}, false},
		{"shepherd", hostRequest{Command: appRelayd + ` 'communication-shepherd'`, Stdin: poll}, false},
		{"communication with arguments", hostRequest{Command: appRelayd + ` 'communication' 'x'`, Stdin: poll}, false},
		{"helper wrapping a binding", hostRequest{Command: hostJobQueryHelperPrefix + appRelayd + ` 'agent-binding' 'x'` + hostJobQueryHelperSuffix}, false},
		{"chained command", hostRequest{Command: appRelayd + ` 'agent-binding' 'x'; rm -rf /tmp/x`}, false},
		{"substitution", hostRequest{Command: appRelayd + ` 'agent-binding' $(id)`}, false},
		{"other double quote", hostRequest{Command: `"$PWD/relayd" 'agent-binding' 'x'`}, false},
		{"other binary", hostRequest{Command: `'/bin/relay' 'agent-binding' 'x'`}, false},
		{"other verb", hostRequest{Command: appRelayd + ` 'resume-saved' 'a' 'b' 'c'`}, false},
		{"argv form", hostRequest{Argv: []string{"/Applications/Relay.app/Contents/MacOS/relayd", "agent-binding", "x"}}, false},
		{"listener kind", hostRequest{Kind: hostJobKindPeerListener, Command: appRelayd + ` 'agent-binding' 'x'`}, false},
		{"kept stdin", hostRequest{Command: appRelayd + ` 'communication'`, Stdin: poll, KeepStdin: true}, false},
	}
	for _, c := range cases {
		if got := hostJobQueryRetention(c.r) == hostJobRetentionQuery; got != c.query {
			t.Errorf("%s: query %v, want %v", c.name, got, c.query)
		}
	}
}

func TestHostJobCleanupRemovesAppQueriesAfterAnHour(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	query := func(id string, finished time.Time) hostJobRecord {
		record := finishedJob(id, finished, 0)
		record.Retention = hostJobRetentionQuery
		return record
	}
	writeArchivedJob(t, s.stateDir, query("job-query-old", now.Add(-hostJobQueryRetentionAge-time.Second)))
	writeArchivedJob(t, s.stateDir, query("job-query-recent", now.Add(-hostJobQueryRetentionAge+time.Minute)))
	writeArchivedJob(t, s.stateDir, finishedJob("job-ordinary", now.Add(-2*hostJobQueryRetentionAge), 0))
	result, err := runCleanup(t, s, now, nil)
	if err != nil || result.Removed != 1 || result.EligibleQuery != 1 || result.KeptRecent != 2 {
		t.Fatalf("cleanup %+v %v", result, err)
	}
	if _, err := os.Lstat(filepath.Join(s.stateDir, "host-jobs-completed", "job-query-old")); !os.IsNotExist(err) {
		t.Fatal("query record past the hour was kept")
	}
	for _, id := range []string{"job-query-recent", "job-ordinary"} {
		if _, err := os.Stat(filepath.Join(s.stateDir, "host-jobs-completed", id, "record.json")); err != nil {
			t.Fatalf("%s removed early", id)
		}
	}
	assertReserved(t, s, "job-query-old")
}

func TestAppQueryJobRecordIsStampedAtLaunch(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	bin := filepath.Join(t.TempDir(), "relayd")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\necho '{}'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	for id, command := range map[string]string{
		"job-stamped-query":   "'" + bin + "' 'agent-binding' 'pane'",
		"job-unstamped-other": "'" + bin + "' 'version'",
	} {
		request := hostRequest{RequestID: "exec", Operation: "exec", JobID: id, Command: command, Cwd: s.stateDir}
		if _, err := s.startHostJob(request); err != nil {
			t.Fatal(err)
		}
		waitHostJob(t, s, id)
		record, err := readArchivedHostJobRecord(filepath.Join(s.stateDir, "host-jobs", id), id)
		want := ""
		if id == "job-stamped-query" {
			want = hostJobRetentionQuery
		}
		if err != nil || record.State != "exited" || record.Retention != want {
			t.Fatalf("%s record %+v %v", id, record, err)
		}
	}
}

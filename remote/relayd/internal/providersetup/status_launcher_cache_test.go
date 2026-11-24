package providersetup

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// statusLauncherHost is a home directory with the installed launcher, one
// plugin version and a stub Node that records each status run.
type statusLauncherHost struct {
	t        *testing.T
	home     string
	launcher string
	runs     string
}

func newStatusLauncherHost(t *testing.T) statusLauncherHost {
	t.Helper()
	home := t.TempDir()
	h := statusLauncherHost{t: t, home: home,
		launcher: filepath.Join(home, ".config/relay/cc-status.sh"),
		runs:     filepath.Join(home, "node-runs")}
	write := func(path, body string, mode os.FileMode) {
		if e := os.MkdirAll(filepath.Dir(path), 0o700); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(path, []byte(body), mode); e != nil {
			t.Fatal(e)
		}
	}
	write(h.launcher, string(DefaultAssets()["relay-cc-status.sh"]), 0o700)
	write(filepath.Join(home, ".claude/plugins/cache/genomewalker-cc-status/cc-status/1.2.3/dist/index.js"), "", 0o600)
	// --version probes are not status runs; each status run prints its stdin
	// and a run number, and fails when STUB_FAIL is set.
	write(filepath.Join(home, ".claude/nodejs/bin/node"), `#!/bin/bash
[ "${1:-}" = --version ] && { echo v20.0.0; exit 0; }
echo run >> "$HOME/node-runs"
printf 'status %s %s\n' "$(wc -l < "$HOME/node-runs" | tr -d ' ')" "$(cat)"
[ -n "${STUB_FAIL:-}" ] && exit 3
exit 0
`, 0o700)
	return h
}

func (h statusLauncherHost) run(stdin string, env ...string) (string, int) {
	h.t.Helper()
	cmd := exec.Command("bash", h.launcher)
	if strings.HasPrefix(stdin, "--") {
		cmd = exec.Command("bash", h.launcher, stdin)
		stdin = ""
	}
	cmd.Env = append([]string{"HOME=" + h.home, "PATH=/usr/bin:/bin:/usr/sbin:/sbin"}, env...)
	cmd.Stdin = strings.NewReader(stdin)
	out, e := cmd.Output()
	code := 0
	if x, ok := e.(*exec.ExitError); ok {
		code = x.ExitCode()
	} else if e != nil {
		h.t.Fatal(e)
	}
	return string(out), code
}

func (h statusLauncherHost) nodeRuns() int {
	raw, e := os.ReadFile(h.runs)
	if os.IsNotExist(e) {
		return 0
	} else if e != nil {
		h.t.Fatal(e)
	}
	return strings.Count(string(raw), "run\n")
}

func TestStatusLauncherKeepsEachSessionsLineForTheTTL(t *testing.T) {
	h := newStatusLauncherHost(t)
	a := `{"session_id":"aaa-1","model":{"id":"x"}}`
	b := `{"session_id": "bbb-2"}`

	first, code := h.run(a)
	if code != 0 || first != "status 1 "+a+"\n" || h.nodeRuns() != 1 {
		t.Fatalf("first refresh: %q code %d runs %d", first, code, h.nodeRuns())
	}
	// Within the TTL the kept line is shown and Node does not start, also
	// through the resolution cache the first run wrote.
	for i := 0; i < 3; i++ {
		if again, code := h.run(a); again != first || code != 0 {
			t.Fatalf("cached refresh %d: %q code %d", i, again, code)
		}
	}
	if h.nodeRuns() != 1 {
		t.Fatalf("Node ran %d times for one session within the TTL", h.nodeRuns())
	}
	// Another session has its own line.
	if other, _ := h.run(b); other != "status 2 "+b+"\n" || h.nodeRuns() != 2 {
		t.Fatalf("second session: %q runs %d", other, h.nodeRuns())
	}
	// The kept line is private and starts with the time it was made.
	kept := filepath.Join(h.home, ".cache/relay/cc-status-out/aaa-1")
	info, e := os.Stat(kept)
	if e != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("kept line mode %v %v", info, e)
	}
	raw, _ := os.ReadFile(kept)
	stamp, body, _ := strings.Cut(string(raw), "\n")
	made, e := strconv.ParseInt(stamp, 10, 64)
	if e != nil || time.Now().Unix()-made > 5 || body != first {
		t.Fatalf("kept line %q", raw)
	}
	// After the TTL the line is made again.
	old := strconv.FormatInt(time.Now().Unix()-61, 10) + "\n" + body
	if e := os.WriteFile(kept, []byte(old), 0o600); e != nil {
		t.Fatal(e)
	}
	if fresh, _ := h.run(a); fresh != "status 3 "+a+"\n" || h.nodeRuns() != 3 {
		t.Fatalf("after the TTL: %q runs %d", fresh, h.nodeRuns())
	}
	// CC_STATUS_TTL=0 turns the cache off.
	if _, _ = h.run(a, "CC_STATUS_TTL=0"); h.nodeRuns() != 4 {
		t.Fatalf("TTL 0 still cached: runs %d", h.nodeRuns())
	}
	// Lines older than an hour are removed when Node next runs.
	stale := filepath.Join(h.home, ".cache/relay/cc-status-out/ended-session")
	if e := os.WriteFile(stale, []byte("x\n"), 0o600); e != nil {
		t.Fatal(e)
	}
	hourAgo := time.Now().Add(-2 * time.Hour)
	if e := os.Chtimes(stale, hourAgo, hourAgo); e != nil {
		t.Fatal(e)
	}
	h.run(`{"session_id":"ccc"}`)
	if _, e := os.Stat(stale); !os.IsNotExist(e) {
		t.Fatalf("an ended session's line was not removed: %v", e)
	}
}

func TestStatusLauncherWithoutASessionOrAfterAFailureRunsNodeEachTime(t *testing.T) {
	h := newStatusLauncherHost(t)
	for i := 1; i <= 2; i++ {
		if out, code := h.run(`{"model":{"id":"x"}}`); code != 0 || !strings.HasPrefix(out, "status ") || h.nodeRuns() != i {
			t.Fatalf("no session id, refresh %d: %q code %d runs %d", i, out, code, h.nodeRuns())
		}
	}
	// A session id that is not a plain name is not used as a file name.
	if h.run(`{"session_id":"../../escape"}`); h.nodeRuns() != 3 {
		t.Fatal("unsafe session id was not run directly")
	}
	if _, e := os.Stat(filepath.Join(h.home, ".cache/escape")); !os.IsNotExist(e) {
		t.Fatal("unsafe session id wrote outside the cache")
	}
	s := `{"session_id":"fails"}`
	for i := 4; i <= 5; i++ {
		out, code := h.run(s, "STUB_FAIL=1")
		if code != 3 || !strings.HasPrefix(out, "status ") || h.nodeRuns() != i {
			t.Fatalf("failed run %d: %q code %d runs %d", i, out, code, h.nodeRuns())
		}
	}
	entries, _ := os.ReadDir(filepath.Join(h.home, ".cache/relay/cc-status-out"))
	if len(entries) != 0 {
		t.Fatalf("a failed run left %d files", len(entries))
	}
	if out, code := h.run(s); code != 0 || h.nodeRuns() != 6 || !strings.HasPrefix(out, "status 6") {
		t.Fatalf("recovery after failure: %q code %d", out, code)
	}
}

func TestStatusLauncherShowsAKeptLineWithoutStartingAProcess(t *testing.T) {
	bash, e := exec.LookPath("bash")
	if e != nil {
		t.Fatal(e)
	}
	if v, _ := exec.Command(bash, "-c", `(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )) && echo ok`).Output(); string(v) != "ok\n" {
		t.Skip("bash older than 4.2 reads the time with date; the hosts run 4.4 and 5.x")
	}
	h := newStatusLauncherHost(t)
	s := `{"session_id":"nofork"}`
	first, _ := h.run(s)
	// Every command the launcher could start records itself instead.
	stubs := t.TempDir()
	starts := filepath.Join(t.TempDir(), "starts")
	for _, name := range []string{"cat", "date", "stat", "sed", "grep", "find", "nice", "mv", "rm", "mkdir", "head", "tail", "env", "printf", "read", "node", "bash", "sh"} {
		body := "#!/bin/sh\necho " + name + " >> " + starts + "\n"
		if e := os.WriteFile(filepath.Join(stubs, name), []byte(body), 0o700); e != nil {
			t.Fatal(e)
		}
	}
	cmd := exec.Command(bash, h.launcher)
	cmd.Env = []string{"HOME=" + h.home, "PATH=" + stubs}
	cmd.Stdin = strings.NewReader(s)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, e := cmd.Output()
	if e != nil || string(out) != first || stderr.Len() != 0 {
		t.Fatalf("kept line: %q %v stderr %q", out, e, stderr.String())
	}
	if raw, _ := os.ReadFile(starts); len(raw) != 0 || h.nodeRuns() != 1 {
		t.Fatalf("a kept line started processes: %q, node runs %d", raw, h.nodeRuns())
	}
	// A line kept by the previous launcher has no time and is made again.
	kept := filepath.Join(h.home, ".cache/relay/cc-status-out/nofork")
	if e := os.WriteFile(kept, []byte("status old\n"), 0o600); e != nil {
		t.Fatal(e)
	}
	if fresh, _ := h.run(s); fresh != "status 2 "+s+"\n" || h.nodeRuns() != 2 {
		t.Fatalf("previous format: %q runs %d", fresh, h.nodeRuns())
	}
}

func TestStatusLauncherCheckStillReportsNodeAndPlugin(t *testing.T) {
	h := newStatusLauncherHost(t)
	out, code := h.run("--check")
	if code != 0 || !strings.Contains(out, "Plugin: 1.2.3") || !strings.Contains(out, "/.claude/nodejs/bin/node") || h.nodeRuns() != 0 {
		t.Fatalf("--check: %q code %d runs %d", out, code, h.nodeRuns())
	}
}

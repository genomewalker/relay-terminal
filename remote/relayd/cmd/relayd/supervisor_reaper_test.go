package main

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// Test supervisors and their pane workers start their own sessions, so a
// failed assertion, a -timeout panic or an interrupted `go test` used to leave
// them running, with their socket directories in /tmp. A testRuntime owns one
// unique runtime directory. Every process whose arguments name a path inside
// it or the test's own directory, and every descendant of one, is reaped at
// cleanup, on SIGINT or SIGTERM, and shortly before the test deadline.

const testRuntimeOwnerFile = "owner.pid"

// testRuntimeDeadlineMargin leaves the reaper time to finish before the
// testing package's -timeout panic, which runs no cleanups.
const testRuntimeDeadlineMargin = 5 * time.Second

// testRuntimeAbandoned is how old a runtime path without a valid owner must
// be before a sweep reclaims it, so one still being created is never taken.
const testRuntimeAbandoned = time.Hour

type testRuntime struct {
	runtimeDir string
	roots      []string
	// mutex orders fence and close: a deadline callback already running when
	// the test ends finishes before close, and one arriving later is a no-op.
	mutex  sync.Mutex
	closed bool
}

var testRuntimes = struct {
	sync.Mutex
	active  map[*testRuntime]struct{}
	install sync.Once
}{active: map[*testRuntime]struct{}{}}

// newTestRuntime creates /tmp/<prefix>XXXX (short enough for a Unix socket)
// and reaps the processes that name it or owned when the test ends. It first
// removes paths left by earlier runs whose owner process is gone.
func newTestRuntime(t *testing.T, prefix, owned string) string {
	t.Helper()
	for _, err := range sweepStaleTestRuntimes(prefix) {
		t.Errorf("stale test runtime not removed: %v", err)
	}
	runtimeDir, err := os.MkdirTemp("/tmp", prefix)
	if err != nil {
		t.Fatal(err)
	}
	// A sweep sees either no owner (and the age guard) or a complete one.
	owner := filepath.Join(runtimeDir, testRuntimeOwnerFile)
	if err := os.WriteFile(owner+".new", testRuntimeOwner(), 0o600); err != nil {
		_ = os.RemoveAll(runtimeDir)
		t.Fatal(err)
	}
	if err := os.Rename(owner+".new", owner); err != nil {
		_ = os.RemoveAll(runtimeDir)
		t.Fatal(err)
	}
	runtime := &testRuntime{runtimeDir: runtimeDir, roots: []string{runtimeDir, owned}}
	testRuntimes.Lock()
	testRuntimes.active[runtime] = struct{}{}
	testRuntimes.Unlock()
	testRuntimes.install.Do(installTestRuntimeSignalReaper)

	var deadlineTimer *time.Timer
	if deadline, ok := t.Deadline(); ok {
		deadlineTimer = time.AfterFunc(max(time.Until(deadline)-testRuntimeDeadlineMargin, 0), runtime.fence)
	}
	// Registered before any process starts, so it runs on every failure path.
	t.Cleanup(func() {
		if deadlineTimer != nil {
			deadlineTimer.Stop()
		}
		if err := runtime.close(); err != nil {
			t.Errorf("test runtime not removed: %v", err)
		}
	})
	return runtimeDir
}

func testRuntimeOwner() []byte { return []byte(strconv.Itoa(os.Getpid())) }

// fence runs before the -timeout panic. It makes the runtime directory tree
// read-only, parent first, so no entry can appear below a directory once it
// is fenced: a supervisor or worker started afterwards can still MkdirAll its
// directory but cannot remove or bind a socket in it. Then it reaps what is
// running. Nothing is removed, so there is no window for a recreated
// directory. The runtime stays registered: the signal handler and the final
// cleanup reap again.
func (runtime *testRuntime) fence() {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	if runtime.closed {
		return
	}
	// Best effort: the deadline has no test to report to, and cleanup or a
	// later sweep restores permissions and removes the tree either way.
	_ = setTestRuntimeWritable(runtime.runtimeDir, false)
	reapTestProcesses(runtime.roots)
}

// close reaps, removes the runtime directory and unregisters. Only the first
// call does anything; it reports a directory it could not remove.
func (runtime *testRuntime) close() error {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	if runtime.closed {
		return nil
	}
	runtime.closed = true
	reapTestProcesses(runtime.roots)
	err := removeTestRuntime(runtime.runtimeDir)
	testRuntimes.Lock()
	delete(testRuntimes.active, runtime)
	testRuntimes.Unlock()
	return err
}

// setTestRuntimeWritable sets or clears owner write permission on every
// directory of the tree, visiting a directory before reading its entries.
// A missing root is not an error.
func setTestRuntimeWritable(root string, writable bool) error {
	mode := os.FileMode(0o500)
	if writable {
		mode = 0o700
	}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() {
			return nil
		}
		return os.Chmod(path, mode)
	})
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	return err
}

// removeTestRuntime removes a runtime directory, fenced or not: write
// permission comes back on every directory, top-down, before the removal
// (the chmod -R u+w a fenced tree needs).
func removeTestRuntime(root string) error {
	if err := setTestRuntimeWritable(root, true); err != nil {
		return fmt.Errorf("restore write permission on %s: %w", root, err)
	}
	if err := os.RemoveAll(root); err != nil {
		return fmt.Errorf("remove %s: %w", root, err)
	}
	return nil
}

func installTestRuntimeSignalReaper() {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		received := <-signals
		testRuntimes.Lock()
		runtimes := make([]*testRuntime, 0, len(testRuntimes.active))
		for runtime := range testRuntimes.active {
			runtimes = append(runtimes, runtime)
		}
		testRuntimes.Unlock()
		for _, runtime := range runtimes {
			_ = runtime.close() // the process is about to die; nothing to report to
		}
		// Die of the same signal, as the test binary would have.
		signal.Reset(received)
		_ = syscall.Kill(os.Getpid(), received.(syscall.Signal))
	}()
}

// sweepStaleTestRuntimes removes /tmp/<prefix>* directories of this user
// (fenced or not) whose owner test process has exited, with their processes.
// A directory without a readable, valid owner is reclaimed only once clearly
// old. It returns the directories it could not remove.
func sweepStaleTestRuntimes(prefix string) []error {
	var failures []error
	matches, _ := filepath.Glob(filepath.Join("/tmp", prefix+"*"))
	for _, path := range matches {
		info, err := os.Lstat(path)
		if err != nil || !info.IsDir() || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
			continue
		}
		if pid, ok := readTestRuntimeOwner(filepath.Join(path, testRuntimeOwnerFile)); ok {
			if err := syscall.Kill(pid, 0); err == nil || errors.Is(err, syscall.EPERM) {
				continue // a live test still owns it
			}
		} else if time.Since(info.ModTime()) < testRuntimeAbandoned {
			continue
		}
		reapTestProcesses([]string{path})
		if err := removeTestRuntime(path); err != nil {
			failures = append(failures, err)
		}
	}
	return failures
}

func readTestRuntimeOwner(path string) (int, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	return pid, err == nil && pid > 1
}

type testProcess struct {
	pid, ppid int
	args      string
}

func listTestProcesses() []testProcess {
	output, err := exec.Command("ps", "-axo", "pid=,ppid=,args=").Output()
	if err != nil {
		return nil
	}
	var processes []testProcess
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		pid, pidErr := strconv.Atoi(fields[0])
		ppid, ppidErr := strconv.Atoi(fields[1])
		if pidErr == nil && ppidErr == nil {
			processes = append(processes, testProcess{pid: pid, ppid: ppid, args: strings.Join(fields[2:], " ")})
		}
	}
	return processes
}

// argsNamePathUnder reports whether args contain a path inside root as a
// whole argument or an option value: bounded on the left by the start, a
// space, '=' or a quote, and on the right by the separator. So
// /tmp/relay-crash-1 matches neither /tmp/relay-crash-12/x nor
// /other/tmp/relay-crash-1/x.
func argsNamePathUnder(args, root string) bool {
	if root == "" {
		return false
	}
	needle := root + string(filepath.Separator)
	for offset := 0; ; {
		index := strings.Index(args[offset:], needle)
		if index < 0 {
			return false
		}
		index += offset
		if index == 0 || strings.ContainsRune(" =\"'", rune(args[index-1])) {
			return true
		}
		offset = index + 1
	}
}

// reapTestProcesses stops every process whose arguments name a path inside
// one of roots, and all their descendants (collected first, so a shell
// reparented by its worker's exit is still found). The test process itself
// is spared. It can run repeatedly.
func reapTestProcesses(roots []string) {
	processes := listTestProcesses()
	children := map[int][]int{}
	for _, process := range processes {
		children[process.ppid] = append(children[process.ppid], process.pid)
	}
	self := os.Getpid()
	targets := map[int]bool{}
	var visit func(int)
	visit = func(pid int) {
		if pid <= 1 || pid == self || targets[pid] {
			return
		}
		targets[pid] = true
		for _, child := range children[pid] {
			visit(child)
		}
	}
	for _, process := range processes {
		for _, root := range roots {
			if argsNamePathUnder(process.args, root) {
				visit(process.pid)
				break
			}
		}
	}
	for pid := range targets {
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}
	deadline := time.Now().Add(2 * time.Second)
	for len(targets) > 0 && time.Now().Before(deadline) {
		for pid := range targets {
			if syscall.Kill(pid, 0) != nil {
				delete(targets, pid)
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	for pid := range targets {
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
}

func TestReaperMatchesOnlyArgumentsInsideTheRoot(t *testing.T) {
	root := "/tmp/relay-crash-123"
	for args, want := range map[string]bool{
		"relayd-test daemon --socket /tmp/relay-crash-123/relayd.sock":                   true,
		"relayd-test worker --socket=/tmp/relay-crash-123/a.sock":                        true,
		`sh -c "exec x '/tmp/relay-crash-123/b.sock'"`:                                   true,
		"/tmp/relay-crash-123/relayd daemon":                                             true,
		"relayd-test daemon --socket /tmp/relay-crash-1234/relayd.sock":                  false,
		"relayd daemon --socket /different/tmp/relay-crash-123/relayd.sock":              false,
		"relayd daemon --socket /tmp/relay-crash-123":                                    false,
		"relayd daemon --socket /different/tmp/relay-crash-123/x /tmp/relay-crash-123/y": true,
	} {
		if got := argsNamePathUnder(args, root); got != want {
			t.Errorf("argsNamePathUnder(%q) = %v, want %v", args, got, want)
		}
	}
	if argsNamePathUnder("anything /x/", "") {
		t.Error("an empty root matched")
	}
}

func TestStaleSweepKeepsOwnedAndFreshUnownedRuntimes(t *testing.T) {
	prefix := "relay-reaper-sweep-" + strconv.Itoa(os.Getpid()) + "-"
	exited := exec.Command("true")
	if err := exited.Run(); err != nil {
		t.Fatal(err)
	}
	deadPID := strconv.Itoa(exited.ProcessState.Pid())
	old := time.Now().Add(-2 * testRuntimeAbandoned)
	type fixture struct {
		name, owner string
		old, fenced bool
		kept        bool
	}
	fixtures := []fixture{
		{name: "live", owner: strconv.Itoa(os.Getpid()), kept: true},
		{name: "dead", owner: deadPID, kept: false},
		{name: "empty-fresh", owner: "", kept: true},
		{name: "invalid-fresh", owner: "12x", kept: true},
		{name: "missing-fresh", owner: "-", kept: true},
		{name: "empty-old", owner: "", old: true, kept: false},
		{name: "fenced-live", owner: strconv.Itoa(os.Getpid()), fenced: true, kept: true},
		{name: "fenced-dead", owner: deadPID, fenced: true, kept: false},
	}
	paths := map[string]string{}
	for _, f := range fixtures {
		path := filepath.Join("/tmp", prefix+f.name)
		paths[f.name] = path
		t.Cleanup(func() { _ = removeTestRuntime(path) })
		if err := os.MkdirAll(filepath.Join(path, "relay-workers"), 0o700); err != nil {
			t.Fatal(err)
		}
		if f.owner != "-" {
			if err := os.WriteFile(filepath.Join(path, testRuntimeOwnerFile), []byte(f.owner), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		if f.fenced {
			if err := setTestRuntimeWritable(path, false); err != nil {
				t.Fatal(err)
			}
		}
		if f.old {
			if err := os.Chtimes(path, old, old); err != nil {
				t.Fatal(err)
			}
		}
	}
	for _, err := range sweepStaleTestRuntimes(prefix) {
		t.Errorf("sweep: %v", err)
	}
	for _, f := range fixtures {
		_, err := os.Lstat(paths[f.name])
		if kept := err == nil; kept != f.kept {
			t.Errorf("%s: kept=%v, want %v", f.name, kept, f.kept)
		}
	}
}

// assertNoTestRuntimeLeft fails unless nothing matches /tmp/<prefix>*.
func assertNoTestRuntimeLeft(t *testing.T, prefix string) {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join("/tmp", prefix+"*"))
	if err != nil || len(matches) > 0 {
		t.Errorf("left in /tmp: %v %v", matches, err)
	}
}

// newFenceFixture makes a runtime under a prefix of its own, so a test can
// prove that nothing with that prefix is left in /tmp.
func newFenceFixture(t *testing.T, name string) (*testRuntime, string) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	prefix := "relay-reaper-fence-" + strconv.Itoa(os.Getpid()) + "-" + name + "-"
	runtimeDir, err := os.MkdirTemp("/tmp", prefix)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = removeTestRuntime(runtimeDir) })
	if err := os.Mkdir(filepath.Join(runtimeDir, "relay-workers"), 0o700); err != nil {
		t.Fatal(err)
	}
	runtime := &testRuntime{runtimeDir: runtimeDir, roots: []string{runtimeDir}}
	testRuntimes.Lock()
	testRuntimes.active[runtime] = struct{}{}
	testRuntimes.Unlock()
	t.Cleanup(func() { _ = runtime.close() })
	return runtime, prefix
}

func closeAndAssertGone(t *testing.T, runtime *testRuntime, prefix string) {
	t.Helper()
	if err := runtime.close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if _, err := os.Lstat(runtime.runtimeDir); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("final cleanup left %s: %v", runtime.runtimeDir, err)
	}
	assertNoTestRuntimeLeft(t, prefix)
}

func TestDeadlineFenceBlocksLaterSocketsAndStaysRegistered(t *testing.T) {
	runtime, prefix := newFenceFixture(t, "late")
	runtimeDir := runtime.runtimeDir
	existing := filepath.Join(runtimeDir, "relay-workers", "existing.sock")
	listener, err := net.Listen("unix", existing)
	if err != nil {
		t.Fatal(err)
	}
	_ = listener.Close()

	runtime.fence()
	runtime.fence() // repeatable: a second deadline-time reap is harmless
	// Late starts as relayd does them: MkdirAll the socket's directory,
	// remove a stale socket, bind. None may bind anywhere in the tree.
	for _, socket := range []string{
		filepath.Join(runtimeDir, "relayd.sock"),
		filepath.Join(runtimeDir, "relay-workers", "late.sock"),
		existing,
		filepath.Join(runtimeDir, "new-dir", "late.sock"),
	} {
		_ = os.MkdirAll(filepath.Dir(socket), 0o700)
		_ = os.Remove(socket)
		if listener, err := net.Listen("unix", socket); err == nil {
			_ = listener.Close()
			t.Errorf("bound %s after the deadline fence", socket)
		}
	}
	if info, err := os.Lstat(runtimeDir); err != nil || !info.IsDir() {
		t.Fatalf("the fence must leave the runtime directory in place: %v", err)
	}
	testRuntimes.Lock()
	_, registered := testRuntimes.active[runtime]
	testRuntimes.Unlock()
	if !registered {
		t.Fatal("the deadline fence unregistered the runtime; signals and final cleanup could not reap it")
	}
	closeAndAssertGone(t, runtime, prefix)
}

func TestDeadlineFenceDuringWorkerStartupLeavesNothing(t *testing.T) {
	runtime, prefix := newFenceFixture(t, "startup")
	runtimeDir := runtime.runtimeDir
	// A worker that bound before the fence keeps its socket open throughout.
	bound, err := net.Listen("unix", filepath.Join(runtimeDir, "relay-workers", "bound.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer bound.Close()
	// Workers starting while the fence runs, as relayd starts them.
	stop := make(chan struct{})
	var starters sync.WaitGroup
	for index := range 4 {
		starters.Add(1)
		go func() {
			defer starters.Done()
			directory := filepath.Join(runtimeDir, "relay-workers", "starting-"+strconv.Itoa(index))
			for attempt := 0; ; attempt++ {
				select {
				case <-stop:
					return
				default:
				}
				socket := filepath.Join(directory, strconv.Itoa(attempt)+".sock")
				_ = os.MkdirAll(directory, 0o700)
				_ = os.Remove(socket)
				if listener, err := net.Listen("unix", socket); err == nil {
					_ = listener.Close()
				}
			}
		}()
	}
	time.Sleep(20 * time.Millisecond)
	runtime.fence()
	time.Sleep(20 * time.Millisecond)
	close(stop)
	starters.Wait()
	closeAndAssertGone(t, runtime, prefix)
}

func TestStaleSweepRemovesAFencedRuntimeOfADeadOwner(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	exited := exec.Command("true")
	if err := exited.Run(); err != nil {
		t.Fatal(err)
	}
	prefix := "relay-reaper-dead-" + strconv.Itoa(os.Getpid()) + "-"
	runtimeDir, err := os.MkdirTemp("/tmp", prefix)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = removeTestRuntime(runtimeDir) })
	owner := []byte(strconv.Itoa(exited.ProcessState.Pid()))
	if err := os.WriteFile(filepath.Join(runtimeDir, testRuntimeOwnerFile), owner, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(runtimeDir, "relay-workers", "deep"), 0o700); err != nil {
		t.Fatal(err)
	}
	// The deadline fenced it, then the -timeout panic ran no cleanup.
	runtime := &testRuntime{runtimeDir: runtimeDir, roots: []string{runtimeDir}}
	runtime.fence()
	if err := os.WriteFile(filepath.Join(runtimeDir, "probe"), nil, 0o600); err == nil {
		t.Fatal("the fixture is not fenced")
	}
	for _, err := range sweepStaleTestRuntimes(prefix) {
		t.Errorf("sweep: %v", err)
	}
	if _, err := os.Lstat(runtimeDir); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the sweep left %s: %v", runtimeDir, err)
	}
	assertNoTestRuntimeLeft(t, prefix)
}

func TestDeadlineFenceAfterCloseChangesNothing(t *testing.T) {
	runtime, prefix := newFenceFixture(t, "after")
	closeAndAssertGone(t, runtime, prefix)
	// A deadline callback that was already running resumes after cleanup.
	runtime.fence()
	if _, err := os.Lstat(runtime.runtimeDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a fence after close recreated %s: %v", runtime.runtimeDir, err)
	}
	assertNoTestRuntimeLeft(t, prefix)
	testRuntimes.Lock()
	_, registered := testRuntimes.active[runtime]
	testRuntimes.Unlock()
	if registered {
		t.Fatal("a fence after close registered the runtime again")
	}

	// A fence in flight when cleanup starts completes first; cleanup then
	// still removes everything.
	second, secondPrefix := newFenceFixture(t, "racing")
	second.mutex.Lock()
	fenced, closed := make(chan struct{}), make(chan error, 1)
	go func() { second.fence(); close(fenced) }()
	go func() { closed <- second.close() }()
	time.Sleep(50 * time.Millisecond)
	second.mutex.Unlock()
	<-fenced
	if err := <-closed; err != nil {
		t.Fatalf("close racing a fence: %v", err)
	}
	if _, err := os.Lstat(second.runtimeDir); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("cleanup racing a fence left %s: %v", second.runtimeDir, err)
	}
	assertNoTestRuntimeLeft(t, secondPrefix)
}

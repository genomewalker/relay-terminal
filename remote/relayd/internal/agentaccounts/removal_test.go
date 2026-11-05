package agentaccounts

import (
	"bufio"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestRemovalHolderHelper is a process that holds a folder open: as itself
// (RELAY_REMOVAL_HOLDER) or, with RELAY_REMOVAL_ADMIT, as Relay's launcher
// admitting the account and then exec'ing another program.
func TestRemovalHolderHelper(t *testing.T) {
	if path := os.Getenv("RELAY_REMOVAL_ADMIT"); path != "" {
		if err := AdmitLaunch(os.Getenv("HOME"), "claude", path); err != nil {
			os.Exit(3)
		}
		_ = syscall.Exec("/bin/sh", []string{"sh", "-c", "echo ready; exec cat >/dev/null"}, []string{"PATH=/usr/bin:/bin"})
		os.Exit(4)
	}
	path := os.Getenv("RELAY_REMOVAL_HOLDER")
	if path == "" {
		return
	}
	file, err := os.Open(path)
	if err != nil {
		os.Exit(2)
	}
	defer file.Close()
	os.Stdout.WriteString("ready\n")
	_, _ = io.Copy(io.Discard, os.Stdin)
	os.Exit(0)
}

func startHolder(t *testing.T, env ...string) int {
	t.Helper()
	command := exec.Command(os.Args[0], "-test.run=^TestRemovalHolderHelper$")
	command.Env = env
	out, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	in, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = in.Close(); _ = command.Process.Kill(); _ = command.Wait() })
	if line, err := bufio.NewReader(out).ReadString('\n'); err != nil || line != "ready\n" {
		t.Fatalf("holder did not start: %q %v", line, err)
	}
	return command.Process.Pid
}

func registered(t *testing.T, home string) bool {
	t.Helper()
	loaded, err := Load(home)
	if err != nil {
		t.Fatal(err)
	}
	_, ok := loaded.Find("claude", "personal")
	return ok
}

func pendingCount(t *testing.T, home string) int {
	t.Helper()
	entries, _ := os.ReadDir(removalsDir(home))
	return len(entries)
}

// stagedFolders lists the account folders set aside beside root.
func stagedFolders(t *testing.T, root string) []string {
	t.Helper()
	found, err := filepath.Glob(filepath.Join(filepath.Dir(root), ".claude-personal.removing-*"))
	if err != nil {
		t.Fatal(err)
	}
	return found
}

func retiredFolders(t *testing.T, home string) []string {
	t.Helper()
	found, _ := filepath.Glob(filepath.Join(home, ".local", "share", "relay", "retired-accounts-*", "claude-personal-*"))
	return found
}

func TestRemoveForgetsTheSlotAndFencesTheFolderBeforeSignOut(t *testing.T) {
	home, registry, root := removeFixture(t)
	writeFile(t, filepath.Join(root, "original-data"), "original")
	logoutRunner = func(ctx context.Context, provider, override string) error {
		if registered(t, home) {
			t.Error("signed out while the slot was still registered")
		}
		if present(root) {
			t.Error("signed out while the folder was still at its path")
		}
		if err := LaunchRefusal(home, "claude", root); err == nil {
			t.Error("a launch was admitted during the removal")
		}
		if string(mustRead(t, filepath.Join(override, "original-data"))) != "original" {
			t.Error("sign-out did not run in the set-aside folder")
		}
		return nil
	}
	_, removed, err := Remove(home, registry, "claude", "personal", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if string(mustRead(t, filepath.Join(removed.MovedTo, "original-data"))) != "original" || len(stagedFolders(t, root)) != 0 ||
		pendingCount(t, home) != 0 || removed.Recreated != "" {
		t.Fatalf("removal did not end cleanly: %+v", removed)
	}
}

// A process that holds the folder open, as Relay's launcher leaves it in
// every agent it admits, keeps the account: the folder returns and the slot
// is restored at its place.
func TestRemovePutsBackAFolderAProcessHoldsOpen(t *testing.T) {
	home, registry, root := removeFixture(t)
	pid := startHolder(t, "HOME="+home, "RELAY_REMOVAL_HOLDER="+root)
	called := false
	logoutRunner = func(ctx context.Context, provider, override string) error { called = true; return nil }
	_, _, err := Remove(home, registry, "claude", "personal", time.Now())
	if err == nil || !strings.Contains(err.Error(), strconv.Itoa(pid)) {
		t.Fatalf("removed a folder held open by pid %d: %v", pid, err)
	}
	if called {
		t.Error("signed out a folder in use")
	}
	if info, err := os.Lstat(root); err != nil || !info.IsDir() || len(stagedFolders(t, root)) != 0 {
		t.Fatal("the folder was not put back")
	}
	if loaded, _ := Load(home); !reflect.DeepEqual(loaded, registry) {
		t.Fatalf("the slot was not restored at its place: %+v", loaded)
	}
	if pendingCount(t, home) != 0 {
		t.Error("a refused removal left its record")
	}
}

// Relay's launcher keeps the admitted folder open across exec: the program
// it becomes is found by a removal that starts afterwards.
func TestAnAdmittedLaunchKeepsTheFolderOpenAcrossExec(t *testing.T) {
	home, registry, root := removeFixture(t)
	pid := startHolder(t, "HOME="+home, "RELAY_REMOVAL_ADMIT="+root)
	_, _, err := Remove(home, registry, "claude", "personal", time.Now())
	if err == nil || !strings.Contains(err.Error(), strconv.Itoa(pid)) {
		t.Fatalf("removed the folder of an admitted launch (pid %d): %v", pid, err)
	}
	if !present(root) || !registered(t, home) {
		t.Fatal("the admitted launch's account was not kept")
	}
}

// When something recreates the old path while the folder is set aside,
// neither is replaced: the original stays set aside, unregistered and
// reported, and the recreated folder is left as it is.
func TestRemoveNeverReplacesARecreatedFolder(t *testing.T) {
	home, registry, root := removeFixture(t)
	writeFile(t, filepath.Join(root, "original-data"), "original")
	original := inUse
	t.Cleanup(func() { inUse = original })
	calls := 0
	inUse = func(provider string, roots ...string) (string, error) {
		if calls++; calls == 2 {
			writeFile(t, filepath.Join(root, "new-agent-state"), "new")
			return "4242", nil
		}
		return "", nil
	}
	called := false
	logoutRunner = func(ctx context.Context, provider, override string) error { called = true; return nil }
	_, removed, err := Remove(home, registry, "claude", "personal", time.Now())
	if err == nil || !strings.Contains(err.Error(), "4242") || !strings.Contains(err.Error(), "Nothing was deleted") {
		t.Fatalf("remove went on: %v", err)
	}
	staged := stagedFolders(t, root)
	if called || len(staged) != 1 || removed.KeptAt != staged[0] {
		t.Fatalf("the original was not kept set aside: %v %+v", staged, removed)
	}
	if string(mustRead(t, filepath.Join(staged[0], "original-data"))) != "original" ||
		string(mustRead(t, filepath.Join(root, "new-agent-state"))) != "new" || present(filepath.Join(root, "original-data")) {
		t.Fatal("a folder was replaced or merged")
	}
	if registered(t, home) {
		t.Fatal("the slot was registered on a recreated folder")
	}
	if err := LaunchRefusal(home, "claude", root); err == nil {
		t.Fatal("a launch was admitted on the recreated folder")
	}
	// Recovery reports it and changes nothing.
	notes := RecoverRemovals(home)
	if len(notes) != 1 || !strings.Contains(notes[0], staged[0]) || registered(t, home) || !present(staged[0]) || pendingCount(t, home) != 1 {
		t.Fatalf("recovery changed a kept removal: %v", notes)
	}
}

// Every crash point leaves the slot either registered with its folder at
// its path, or forgotten with the folder set aside or retired (and, between
// forgetting the slot and setting the folder aside, forgotten with the
// folder at its path and the removal journaled, which no launch admits).
// Recovery then undoes everything before the sign-out and finishes
// everything after it.
func TestEveryRemovalCrashPointIsCoherentAndRecovers(t *testing.T) {
	steps := []struct {
		step     string
		finished bool
	}{
		{"recorded", false}, {"unregistered", false}, {"staged", false}, {"checked", false},
		{"signed_out", true}, {"retired", true},
	}
	for _, c := range steps {
		t.Run(c.step, func(t *testing.T) {
			home, registry, root := removeFixture(t)
			writeFile(t, filepath.Join(root, "original-data"), "original")
			original := removeCrash
			t.Cleanup(func() { removeCrash = original })
			removeCrash = func(step string) bool { return step == c.step }
			signedOut := false
			logoutRunner = func(ctx context.Context, provider, override string) error { signedOut = true; return nil }
			if _, _, err := Remove(home, registry, "claude", "personal", time.Now()); !errors.Is(err, errRemovalCrashed) {
				t.Fatalf("no crash at %s: %v", c.step, err)
			}
			removeCrash = original
			staged, retired := stagedFolders(t, root), retiredFolders(t, home)
			switch {
			case registered(t, home):
				if !present(filepath.Join(root, "original-data")) || len(staged)+len(retired) != 0 {
					t.Fatal("a registered slot does not have its folder at its path")
				}
			case present(root):
				if c.step != "unregistered" || pendingCount(t, home) != 1 || LaunchRefusal(home, "claude", root) == nil {
					t.Fatal("a forgotten slot left its folder at its path without a journaled removal")
				}
			case len(staged)+len(retired) != 1:
				t.Fatalf("the folder is neither at its path, set aside nor retired: %v %v", staged, retired)
			}
			if signedOut != c.finished {
				t.Fatalf("signed out=%t at %s", signedOut, c.step)
			}
			RecoverRemovals(home)
			if pendingCount(t, home) != 0 || len(stagedFolders(t, root)) != 0 {
				t.Fatal("recovery left a removal pending")
			}
			if c.finished {
				retired = retiredFolders(t, home)
				if registered(t, home) || present(root) || len(retired) != 1 ||
					string(mustRead(t, filepath.Join(retired[0], "original-data"))) != "original" {
					t.Fatal("recovery did not finish a signed-out removal")
				}
				return
			}
			if loaded, _ := Load(home); !reflect.DeepEqual(loaded, registry) ||
				string(mustRead(t, filepath.Join(root, "original-data"))) != "original" || len(retiredFolders(t, home)) != 0 {
				t.Fatal("recovery did not undo a removal stopped before its sign-out")
			}
		})
	}
}

// The next accounts request recovers an interrupted removal before anything
// else and says so.
func TestAccountsRequestsRecoverAnInterruptedRemoval(t *testing.T) {
	home, registry, root := removeFixture(t)
	t.Setenv("HOME", home)
	original := removeCrash
	t.Cleanup(func() { removeCrash = original })
	removeCrash = func(step string) bool { return step == "staged" }
	if _, _, err := Remove(home, registry, "claude", "personal", time.Now()); !errors.Is(err, errRemovalCrashed) {
		t.Fatal(err)
	}
	removeCrash = original
	response, err := Handle(Request{Action: "list"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(response.RemovalNotes) != 1 || !strings.Contains(response.RemovalNotes[0], "undone") || !present(root) || !registered(t, home) {
		t.Fatalf("not recovered: %v", response.RemovalNotes)
	}
}

func TestLaunchesAdmitOnlyRegisteredAccounts(t *testing.T) {
	home, registry, root := removeFixture(t)
	for _, value := range []string{"", root, filepath.Join(home, ".claude")} {
		if err := LaunchRefusal(home, "claude", value); err != nil {
			t.Errorf("refused %q: %v", value, err)
		}
	}
	if err := LaunchRefusal(home, "codex", filepath.Join(home, ".codex")); err != nil {
		t.Errorf("refused Codex's main folder: %v", err)
	}
	for _, value := range []string{filepath.Join(home, ".claude-other"), ".claude-personal", filepath.Join(home, ".codex-personal")} {
		if err := LaunchRefusal(home, "claude", value); err == nil {
			t.Errorf("admitted %q", value)
		}
	}
	if _, _, err := Remove(home, registry, "claude", "personal", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := LaunchRefusal(home, "claude", root); err == nil || !strings.Contains(err.Error(), "Nothing was started") {
		t.Fatalf("a removed account was admitted: %v", err)
	}
	if err := os.Chmod(Path(home), 0o666); err != nil {
		t.Fatal(err)
	}
	if err := LaunchRefusal(home, "claude", filepath.Join(home, ".codex-personal")); err == nil {
		t.Fatal("admitted a folder while the account list could not be read")
	}
}

// Both renames refuse an existing target, empty or not.
func TestRenamesNeverReplaceAFolder(t *testing.T) {
	for _, rename := range []func(string, string) error{renameNoReplace, renameChecked} {
		dir := t.TempDir()
		from, empty, full := filepath.Join(dir, "from"), filepath.Join(dir, "empty"), filepath.Join(dir, "full")
		writeFile(t, filepath.Join(from, "data"), "x")
		writeFile(t, filepath.Join(full, "other"), "y")
		if err := os.Mkdir(empty, 0o700); err != nil {
			t.Fatal(err)
		}
		if rename(from, empty) == nil || rename(from, full) == nil || !present(filepath.Join(from, "data")) {
			t.Fatal("a rename replaced a folder")
		}
		if err := rename(from, filepath.Join(dir, "free")); err != nil || !present(filepath.Join(dir, "free", "data")) {
			t.Fatalf("rename to a free name failed: %v", err)
		}
	}
}

// A slot without a folder is forgotten only after the scan; a crash before
// it finished restores the slot.
func TestAFolderlessSlotIsScannedAndRecovers(t *testing.T) {
	for _, step := range []string{"recorded", "unregistered"} {
		home, registry, root := removeFixture(t)
		if err := os.Remove(root); err != nil {
			t.Fatal(err)
		}
		original := removeCrash
		removeCrash = func(at string) bool { return at == step }
		_, _, err := Remove(home, registry, "claude", "personal", time.Now())
		removeCrash = original
		if !errors.Is(err, errRemovalCrashed) {
			t.Fatalf("%s: %v", step, err)
		}
		RecoverRemovals(home)
		if loaded, _ := Load(home); !reflect.DeepEqual(loaded, registry) || pendingCount(t, home) != 0 {
			t.Fatalf("%s: the slot was not restored", step)
		}
	}
	home, registry, root := removeFixture(t)
	if err := os.Remove(root); err != nil {
		t.Fatal(err)
	}
	pid := startHolder(t, "HOME="+home, "CLAUDE_CONFIG_DIR="+root, "RELAY_REMOVAL_HOLDER="+home)
	if _, _, err := Remove(home, registry, "claude", "personal", time.Now()); err == nil || !strings.Contains(err.Error(), strconv.Itoa(pid)) {
		t.Fatalf("forgot a slot a process names: %v", err)
	}
	if loaded, _ := Load(home); !reflect.DeepEqual(loaded, registry) || pendingCount(t, home) != 0 {
		t.Fatal("a refused removal changed the registry")
	}
}

// A signed-out removal that recovery could not retire because something
// used the folder is retired by a later request once nothing does.
func TestRecoveryRetiresOnceTheFolderIsFree(t *testing.T) {
	home, registry, root := removeFixture(t)
	original := removeCrash
	t.Cleanup(func() { removeCrash = original })
	removeCrash = func(step string) bool { return step == "signed_out" }
	if _, _, err := Remove(home, registry, "claude", "personal", time.Now()); !errors.Is(err, errRemovalCrashed) {
		t.Fatal(err)
	}
	removeCrash = original
	users := accountUsers
	t.Cleanup(func() { accountUsers = users })
	accountUsers = func(string, ...string) (string, error) { return "4242", nil }
	if notes := RecoverRemovals(home); len(notes) != 1 || !strings.Contains(notes[0], "4242") || len(stagedFolders(t, root)) != 1 {
		t.Fatalf("retired a folder in use: %v", notes)
	}
	accountUsers = func(string, ...string) (string, error) { return "", errors.New("lsof failed") }
	if RecoverRemovals(home); len(stagedFolders(t, root)) != 1 || pendingCount(t, home) != 1 {
		t.Fatal("retired a folder after a failed scan")
	}
	accountUsers = users
	RecoverRemovals(home)
	if len(retiredFolders(t, home)) != 1 || pendingCount(t, home) != 0 || registered(t, home) {
		t.Fatal("a free folder was not retired")
	}
}

// A launch whose account folder exists but cannot be held open is refused;
// a registered account without a folder yet is admitted (its variable is in
// its environment), except for a rotation worker, which must hold it.
func TestAdmissionFailsClosedWhenTheFolderCannotBeHeld(t *testing.T) {
	home, _, root := removeFixture(t)
	if err := AdmitLaunch(home, "claude", root); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(root); err != nil {
		t.Fatal(err)
	}
	if err := AdmitLaunch(home, "claude", root); err != nil {
		t.Fatalf("a registered account before its first sign-in was refused: %v", err)
	}
	if err := AdmitHeldLaunch(home, "claude", root); err == nil {
		t.Fatal("a rotation worker was admitted without holding its folder")
	}
	writeFile(t, root, "not a folder")
	if err := AdmitLaunch(home, "claude", root); err == nil || !strings.Contains(err.Error(), "could not be opened") {
		t.Fatalf("admitted a folder that cannot be held open: %v", err)
	}
}

// After sign-out, recovery says so.
func TestRecoveryNotesASignedOutPutBack(t *testing.T) {
	home := t.TempDir()
	registry, err := Save(home, DefaultRegistry())
	if err != nil {
		t.Fatal(err)
	}
	account, _ := registry.Find("claude", "personal")
	root := account.Root(home)
	writeFile(t, filepath.Join(root, "x"), "x")
	job := removal{ID: "0123456789abcdef", Account: account, Index: 1, Root: root,
		Staged: filepath.Join(home, ".claude-personal.removing-0123456789abcdef"), Destination: filepath.Join(home, "retired", "x"),
		Step: removalSignedOut}
	if err := writeRemoval(home, job); err != nil {
		t.Fatal(err)
	}
	kept := Registry{Version: registryVersion}
	for _, other := range registry.Accounts {
		if other.Label != "personal" || other.Provider != "claude" {
			kept.Accounts = append(kept.Accounts, other)
		}
	}
	if _, err := Save(home, kept); err != nil {
		t.Fatal(err)
	}
	notes := RecoverRemovals(home)
	if len(notes) != 1 || !strings.Contains(notes[0], "signed out") || strings.Contains(notes[0], "nothing was signed out") || !registered(t, home) {
		t.Fatalf("notes %v", notes)
	}
}

// With the fallback rename, a crash after Relay created its empty
// placeholder and before the folder moved onto it leaves the placeholder
// journaled: recovery removes it (empty only) and never takes it for the
// account folder.
func TestFallbackPlaceholdersAreNeverTakenForTheFolder(t *testing.T) {
	cases := []struct {
		crash, then string
		retired     bool
	}{
		{crash: "reserved:stage"},
		{crash: "reserved:put_back", then: "refuse"},
		{crash: "reserved:retire", retired: true},
	}
	for _, c := range cases {
		t.Run(c.crash, func(t *testing.T) {
			home, registry, root := removeFixture(t)
			writeFile(t, filepath.Join(root, "original-data"), "original")
			crash, users := removeCrash, accountUsers
			t.Cleanup(func() { removeCrash, accountUsers, forceRenameFallback = crash, users, false })
			forceRenameFallback = true
			removeCrash = func(step string) bool { return step == c.crash }
			if c.then == "refuse" {
				accountUsers = func(string, ...string) (string, error) { return "4242", nil }
			}
			if _, _, err := Remove(home, registry, "claude", "personal", time.Now()); !errors.Is(err, errRemovalCrashed) {
				t.Fatalf("no crash: %v", err)
			}
			removeCrash, accountUsers = crash, users
			notes := RecoverRemovals(home)
			for _, note := range notes {
				if strings.Contains(note, "is kept at") || strings.Contains(note, "recreated") {
					t.Fatalf("a placeholder was taken for the folder: %v", notes)
				}
			}
			if pendingCount(t, home) != 0 || len(stagedFolders(t, root)) != 0 {
				t.Fatalf("recovery left state behind: %v", notes)
			}
			if c.retired {
				retired := retiredFolders(t, home)
				if len(retired) != 1 || string(mustRead(t, filepath.Join(retired[0], "original-data"))) != "original" || registered(t, home) {
					t.Fatalf("not retired: %v", notes)
				}
				return
			}
			if loaded, _ := Load(home); !reflect.DeepEqual(loaded, registry) || string(mustRead(t, filepath.Join(root, "original-data"))) != "original" {
				t.Fatalf("not restored: %v", notes)
			}
		})
	}
}

// A placeholder that is not empty, or a staging name that holds the account
// folder itself, is never removed.
func TestRecoveryRemovesOnlyEmptyPlaceholders(t *testing.T) {
	home, registry, root := removeFixture(t)
	account, _ := registry.Find("claude", "personal")
	dev, inode, _ := folderIdentity(root)
	job := removal{ID: "0123456789abcdef", Account: account, Index: 1, Root: root, Dev: dev, Inode: inode,
		Staged: filepath.Join(filepath.Dir(root), ".claude-personal.removing-0123456789abcdef"), Destination: filepath.Join(home, "retired", "x")}
	writeFile(t, filepath.Join(job.Staged, "someone-elses"), "y")
	if err := writeRemoval(home, job); err != nil {
		t.Fatal(err)
	}
	notes := RecoverRemovals(home)
	if !present(filepath.Join(job.Staged, "someone-elses")) || !registered(t, home) || pendingCount(t, home) != 0 {
		t.Fatalf("a non-empty staging folder was removed or the slot not restored: %v", notes)
	}
	// The account folder moved to its staging name and the old path was
	// recreated empty: the account folder is kept, never removed.
	home, registry, root = removeFixture(t)
	writeFile(t, filepath.Join(root, "original-data"), "original")
	account, _ = registry.Find("claude", "personal")
	dev, inode, _ = folderIdentity(root)
	job = removal{ID: "0123456789abcdef", Account: account, Index: 1, Root: root, Dev: dev, Inode: inode,
		Staged: filepath.Join(filepath.Dir(root), ".claude-personal.removing-0123456789abcdef"), Destination: filepath.Join(home, "retired", "x")}
	if err := writeRemoval(home, job); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(root, job.Staged); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	notes = RecoverRemovals(home)
	if string(mustRead(t, filepath.Join(job.Staged, "original-data"))) != "original" || !present(root) || pendingCount(t, home) != 1 ||
		len(notes) != 1 || !strings.Contains(notes[0], "is kept at "+job.Staged) {
		t.Fatalf("the moved account folder was not kept: %v", notes)
	}
}

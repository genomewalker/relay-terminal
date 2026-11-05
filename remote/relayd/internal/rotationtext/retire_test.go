package rotationtext

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// ---- fixtures ----

// helperDir returns a directory with one rotation-text executable, whose
// SHA-256 reviewedImages allowlists unless unreviewed is set.
func helperDir(t *testing.T, unreviewed bool) string {
	dir := t.TempDir()
	body := "#!/bin/sh\n# reviewed rotation-text ledger.log helper\n"
	if unreviewed {
		body = "#!/bin/sh\n# unreviewed rotation-text ledger.log helper\n"
	}
	if err := os.WriteFile(filepath.Join(dir, "relayd"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	// Non-executables and executables that never name rotation-text are not writers.
	os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("rotation-text"), 0o644)
	os.WriteFile(filepath.Join(dir, "relay-mcp"), []byte("#!/bin/sh\n"), 0o755)
	return dir
}

// reviewedImages is the allowlist for tests: the reviewed helper script and,
// when withSelf, this test binary (the image of the lock helper process).
func reviewedImages(t *testing.T, withSelf bool) []string {
	images := []string{bytesSHA256([]byte("#!/bin/sh\n# reviewed rotation-text ledger.log helper\n"))}
	if withSelf {
		executable, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		images = append(images, fileSHA256(executable))
	}
	return images
}

func retireOptions(t *testing.T, withSelf bool, dirs ...string) ReconcileOptions {
	return ReconcileOptions{Apply: true, Retire: true, HelperDirs: dirs, AllowedImages: reviewedImages(t, withSelf)}
}

func lstat(t *testing.T, path string) os.FileInfo {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info
}

func retiredFiles(t *testing.T, root string) []string {
	matches, err := filepath.Glob(filepath.Join(root, legacyJournalName+retiredSuffix+"*"))
	if err != nil {
		t.Fatal(err)
	}
	return matches
}

// sqliteSession is an interactive sqlite3 process: a pre-ledger writer whose
// image is not ledger-aware.
type sqliteSession struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	out *bufio.Reader
}

func startSQLite(t *testing.T, path string) *sqliteSession {
	t.Helper()
	tool, err := exec.LookPath("sqlite3")
	if err != nil {
		t.Fatalf("sqlite3 is required for the legacy-writer emulation: %v", err)
	}
	cmd := exec.Command(tool, "-batch", path)
	in, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	s := &sqliteSession{cmd, in, bufio.NewReader(stdout)}
	t.Cleanup(s.close)
	return s
}

// run sends one statement and waits for a marker line, so the file is open
// when it returns.
func (s *sqliteSession) run(t *testing.T, sql string) string {
	t.Helper()
	fmt.Fprintf(s.in, "%s\nSELECT 'done-marker';\n", sql)
	var lines []string
	for {
		line, err := s.out.ReadString('\n')
		if err != nil {
			t.Fatalf("sqlite3 session: %v (%q)", err, lines)
		}
		if strings.TrimSpace(line) == "done-marker" {
			return strings.Join(lines, "")
		}
		lines = append(lines, line)
	}
}

func (s *sqliteSession) close() {
	if s.in != nil {
		s.in.Close()
		s.cmd.Wait()
		s.in = nil
	}
}

const legacyInsert = "INSERT INTO operations (id,fingerprint,settings_digest,state,day,month,reserved,charged,result) " +
	"VALUES ('%s','fp-%s','s','complete','2026-10-29','2026-10',10,7,'{}');"

// ---- the fenced retirement ----

// Fold and retire in one locked step: the legacy rows are in the ledger, the
// legacy path holds a sealed read-only copy that ledger-aware relayds of
// this (pre-r1) code accept, and a writer starting afterwards cannot commit.
func TestRetireFoldsAndSeals(t *testing.T) {
	root, imported := divergedRoot(t)
	legacy := filepath.Join(root, legacyJournalName)
	original := lstat(t, legacy)
	legacySHA := fileSHA(t, legacy)

	report, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false)))
	if err != nil || !report.Applied || report.Retire == nil || !report.Retire.Retired {
		t.Fatalf("retire: err=%v report=%+v retire=%+v", err, report, report.Retire)
	}
	if len(report.Retire.HelpersOK) != 1 {
		t.Fatalf("helper inventory %v", report.Retire.HelpersOK)
	}
	sealed := lstat(t, legacy)
	if os.SameFile(sealed, original) || sealed.Mode().Perm() != 0o400 || fileSHA(t, legacy) != legacySHA ||
		!sealed.ModTime().Equal(original.ModTime()) {
		t.Fatalf("legacy path is not the sealed copy: same=%v mode=%v mtime=%v/%v", os.SameFile(sealed, original),
			sealed.Mode(), sealed.ModTime(), original.ModTime())
	}
	retired := retiredFiles(t, root)
	if len(retired) != 1 || retired[0] != report.Retire.RetiredPath || !os.SameFile(lstat(t, retired[0]), original) ||
		fileSHA(t, retired[0]) != legacySHA {
		t.Fatalf("retired file %v (report %s)", retired, report.Retire.RetiredPath)
	}

	// The deployed (pre-r1) ledger code accepts the sealed copy.
	ledger := openLedger(t, root)
	if rows := rowCount(t, ledger); rows != imported+2 {
		t.Fatalf("rows %d, want %d", rows, imported+2)
	}
	insertRows(t, ledger, 900002, 1, "after-retire")
	ledger.Close()

	// A pre-ledger writer starting now cannot commit to the path...
	tool, err := exec.LookPath("sqlite3")
	if err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(tool, legacy, fmt.Sprintf(legacyInsert, "late", "late")).CombinedOutput()
	if err == nil || !strings.Contains(strings.ToLower(string(out)), "readonly") {
		t.Fatalf("a new legacy writer committed to the sealed copy: %v %s", err, out)
	}
	if _, err := os.OpenFile(legacy, os.O_RDWR, 0); !errors.Is(err, os.ErrPermission) {
		t.Fatalf("sealed copy opened read-write: %v", err)
	}
	// ...nor recreate it, and the ledger still opens with nothing diverged.
	if fileSHA(t, legacy) != legacySHA || !os.SameFile(lstat(t, legacy), sealed) {
		t.Fatal("the sealed copy changed")
	}
	openLedger(t, root).Close()
}

// An already-open writer with no lock (an idle sqlite3 connection opened
// before the retirement) could commit to the retired inode later: refused,
// swapped back, and what it writes afterwards is folded by the next run.
func TestRetireRefusesAnOpenPreLedgerHolder(t *testing.T) {
	root, _ := divergedRoot(t)
	legacy := filepath.Join(root, legacyJournalName)
	original := lstat(t, legacy)
	session := startSQLite(t, legacy)
	if out := session.run(t, "SELECT count(*) FROM operations;"); strings.TrimSpace(out) == "" {
		t.Fatal("sqlite3 did not read the legacy journal")
	}
	report, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false)))
	var refused *errRetireRefused
	if !errors.As(err, &refused) || !strings.Contains(err.Error(), strconv.Itoa(session.cmd.Process.Pid)) ||
		!strings.Contains(err.Error(), "not a reviewed image") || report.Retire == nil || !report.Retire.SwappedBack {
		t.Fatalf("open holder not refused: err=%v retire=%+v", err, report.Retire)
	}
	if !os.SameFile(lstat(t, legacy), original) || len(retiredFiles(t, root)) != 0 {
		t.Fatal("refusal did not restore the legacy file")
	}
	// The fold itself was applied before the refusal; the ledger opens.
	openLedger(t, root).Close()

	// The holder commits after the refusal: to the original path, not lost.
	session.run(t, fmt.Sprintf(legacyInsert, "holder-after-refusal", "holder-after-refusal"))
	session.close()
	report, err = ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false)))
	if err != nil || !report.Retire.Retired || len(report.AddedRows) != 1 || report.AddedRows[0] != "holder-after-refusal" {
		t.Fatalf("second run: err=%v report=%+v", err, report)
	}
}

// TestRetireHelperProcess holds a descriptor on RT_RETIRE_FILE, without any
// lock, until stdin closes. Its image (the test binary) contains both
// "rotation-text" and "ledger.log".
func TestRetireHelperProcess(t *testing.T) {
	if os.Getenv("RT_RETIRE_HELPER") != "hold-open" {
		return
	}
	file, err := os.Open(os.Getenv("RT_RETIRE_FILE"))
	if err != nil {
		os.Exit(2)
	}
	fmt.Println("open")
	io.Copy(io.Discard, os.Stdin)
	file.Close()
	os.Exit(0)
}

// A holder whose binary contains the ledger marker but is not on the
// reviewed allowlist is refused: the marker is not an identity.
func TestRetireRefusesAnUnreviewedImageWithTheMarker(t *testing.T) {
	executable, _ := os.Executable()
	if data, _ := os.ReadFile(executable); !strings.Contains(string(data), "ledger.log") || !strings.Contains(string(data), textRootMarker) {
		t.Fatal("setup: the test binary should contain both markers")
	}
	root, _ := divergedRoot(t)
	legacy := filepath.Join(root, legacyJournalName)
	original := lstat(t, legacy)
	command := exec.Command(os.Args[0], "-test.run=^TestRetireHelperProcess$", "-test.count=1")
	command.Env = append(os.Environ(), "RT_RETIRE_HELPER=hold-open", "RT_RETIRE_FILE="+legacy)
	stdin, _ := command.StdinPipe()
	stdout, _ := command.StdoutPipe()
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { stdin.Close(); command.Wait() }()
	if line, _ := bufio.NewReader(stdout).ReadString('\n'); line != "open\n" {
		t.Fatalf("helper: %q", line)
	}
	report, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, false, helperDir(t, false)))
	if err == nil || !strings.Contains(err.Error(), strconv.Itoa(command.Process.Pid)) || !strings.Contains(err.Error(), "not a reviewed image") ||
		!report.Retire.SwappedBack || !os.SameFile(lstat(t, legacy), original) {
		t.Fatalf("unreviewed marker image not refused: err=%v retire=%+v", err, report.Retire)
	}
	// The same holder with its exact image reviewed is accepted.
	report, err = ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false)))
	if err != nil || !report.Retire.Retired {
		t.Fatalf("reviewed holder refused: err=%v retire=%+v", err, report.Retire)
	}
}

// A helper that contains the ledger marker but is not reviewed blocks too.
func TestRetireRefusesAnUnreviewedHelperWithTheMarker(t *testing.T) {
	root, _ := divergedRoot(t)
	before := fileSHA(t, filepath.Join(root, ledgerLogName))
	if _, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, true))); err == nil ||
		!strings.Contains(err.Error(), "is not a reviewed image") {
		t.Fatalf("unreviewed helper accepted: %v", err)
	}
	if fileSHA(t, filepath.Join(root, ledgerLogName)) != before {
		t.Fatal("a refused precondition wrote something")
	}
}

// A transaction in progress (RESERVED held) by a process whose image is
// ledger-aware is still refused: the lock probe, not the image check, sees it.
func TestRetireRefusesATransactionInProgress(t *testing.T) {
	root, _ := divergedRoot(t)
	legacy := filepath.Join(root, legacyJournalName)
	original := lstat(t, legacy)
	command := helperProcess(t, "sqlite-lock", "RT_LEDGER_FILE="+legacy, "RT_LEDGER_BYTE="+strconv.FormatInt(sqliteReservedByte, 10))
	stdin, _ := command.StdinPipe()
	stdout, _ := command.StdoutPipe()
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { stdin.Close(); command.Wait() }()
	if line, _ := bufio.NewReader(stdout).ReadString('\n'); line != "locked\n" {
		t.Fatalf("helper lock: %q", line)
	}
	report, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false)))
	if err == nil || !strings.Contains(err.Error(), "RESERVED") || !report.Retire.SwappedBack {
		t.Fatalf("transaction not refused: err=%v retire=%+v", err, report.Retire)
	}
	for _, seen := range report.Retire.HoldersSeen {
		if strings.Contains(seen, strconv.Itoa(command.Process.Pid)) && !strings.Contains(seen, "allowlisted=true") {
			t.Fatalf("the test helper image should be allowlisted: %s", seen)
		}
	}
	if !os.SameFile(lstat(t, legacy), original) || len(retiredFiles(t, root)) != 0 {
		t.Fatal("refusal did not restore the legacy file")
	}
}

// A writer that opens the legacy path after any pre-swap check but before the
// swap still holds the original inode: only a check after the swap sees it.
func TestRetireSeesAnOpenerRacingTheSwap(t *testing.T) {
	root, _ := divergedRoot(t)
	legacy := filepath.Join(root, legacyJournalName)
	original := lstat(t, legacy)
	saved := swapNames
	defer func() { swapNames = saved }()
	var session *sqliteSession
	swapNames = func(a, b string) error {
		if session == nil {
			session = startSQLite(t, legacy)
			session.run(t, "SELECT count(*) FROM operations;")
		}
		return saved(a, b)
	}
	report, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false)))
	if err == nil || session == nil || !strings.Contains(err.Error(), strconv.Itoa(session.cmd.Process.Pid)) {
		t.Fatalf("racing opener not refused: err=%v retire=%+v", err, report.Retire)
	}
	if !os.SameFile(lstat(t, legacy), original) {
		t.Fatal("refusal did not restore the legacy file")
	}
}

// A pre-ledger image still installed on an exec path refuses everything
// before anything is written.
func TestRetireRefusesAnInstalledPreLedgerHelper(t *testing.T) {
	root, _ := divergedRoot(t)
	logPath := filepath.Join(root, ledgerLogName)
	before, legacyBefore := fileSHA(t, logPath), fileSHA(t, filepath.Join(root, legacyJournalName))
	report, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false), helperDir(t, true)))
	var refused *errRetireRefused
	if !errors.As(err, &refused) || !strings.Contains(err.Error(), "is not a reviewed image") || report.Applied {
		t.Fatalf("pre-ledger helper not refused: err=%v report=%+v", err, report)
	}
	if fileSHA(t, logPath) != before || fileSHA(t, filepath.Join(root, legacyJournalName)) != legacyBefore {
		t.Fatal("a refused precondition wrote something")
	}
	if _, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, filepath.Join(root, "missing"))); err == nil {
		t.Fatal("an unreadable helper directory was accepted")
	}
	if _, err := ReconcileLegacyWith(context.Background(), root, ReconcileOptions{Retire: true}); err == nil {
		t.Fatal("retire without apply was accepted")
	}
	for _, images := range [][]string{nil, {"not-a-hash"}, {strings.Repeat("g", 64)}} {
		options := retireOptions(t, true, helperDir(t, false))
		options.AllowedImages = images
		if _, err := ReconcileLegacyWith(context.Background(), root, options); err == nil {
			t.Fatalf("allowlist %q accepted", images)
		}
	}
	if fileSHA(t, logPath) != before {
		t.Fatal("a refused allowlist wrote something")
	}
}

// Sqlite side files, a failing holder scan and an existing retired name
// refuse and leave the legacy path in place.
func TestRetireRefusalsLeaveTheLegacyFile(t *testing.T) {
	t.Run("side-file", func(t *testing.T) {
		root, _ := divergedRoot(t)
		legacy := filepath.Join(root, legacyJournalName)
		original := lstat(t, legacy)
		os.WriteFile(legacy+"-wal", nil, 0o600)
		if _, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false))); err == nil ||
			!strings.Contains(err.Error(), "-wal") {
			t.Fatalf("side file: %v", err)
		}
		if !os.SameFile(lstat(t, legacy), original) || len(retiredFiles(t, root)) != 0 {
			t.Fatal("legacy file moved")
		}
	})
	t.Run("scan-failure", func(t *testing.T) {
		root, _ := divergedRoot(t)
		legacy := filepath.Join(root, legacyJournalName)
		original := lstat(t, legacy)
		saved := listLegacyHolders
		defer func() { listLegacyHolders = saved }()
		listLegacyHolders = func(context.Context, string, os.FileInfo) ([]legacyHolder, error) {
			return nil, errors.New("injected scan failure")
		}
		report, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false)))
		if err == nil || !report.Retire.SwappedBack || !os.SameFile(lstat(t, legacy), original) || len(retiredFiles(t, root)) != 0 {
			t.Fatalf("scan failure: err=%v retire=%+v", err, report.Retire)
		}
	})
	t.Run("name-taken", func(t *testing.T) {
		root, _ := divergedRoot(t)
		legacy := filepath.Join(root, legacyJournalName)
		saved := retireNow
		defer func() { retireNow = saved }()
		fixed := time.Date(2026, 11, 2, 1, 2, 3, 0, time.UTC)
		retireNow = func() time.Time { return fixed }
		taken := legacy + retiredSuffix + "20261102T010203Z"
		os.WriteFile(taken, []byte("operator's"), 0o600)
		if _, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false))); err == nil {
			t.Fatal("existing retired name accepted")
		}
		if data, _ := os.ReadFile(taken); string(data) != "operator's" {
			t.Fatal("an existing file was overwritten or removed")
		}
	})
}

// ---- folded continuation (replaces TestDifferentialLedgerContinuation) ----

// prepareFoldedRoot turns a copied fixture into a ledger that reached the
// fixture's state by the r0 fold instead of the automatic import: either an
// empty ledger, or one that imported only the first half of the operations,
// followed by a fold (and, without sqlite side files, the fenced retirement)
// of the full fixture.
func prepareFoldedRoot(t *testing.T, root, mode string) {
	t.Helper()
	aside := t.TempDir()
	names, _ := filepath.Glob(filepath.Join(root, legacyJournalName+"*"))
	if len(names) == 0 {
		t.Fatalf("fixture has no legacy journal")
	}
	for _, name := range names {
		if err := os.Rename(name, filepath.Join(aside, filepath.Base(name))); err != nil {
			t.Fatal(err)
		}
	}
	switch mode {
	case "empty":
	case "prefix":
		half := filepath.Join(t.TempDir(), legacyJournalName)
		for _, name := range names {
			data, _ := os.ReadFile(filepath.Join(aside, filepath.Base(name)))
			os.WriteFile(filepath.Join(filepath.Dir(half), filepath.Base(name)), data, 0o600)
		}
		sqliteExec(t, half, "DELETE FROM operations WHERE rowid > (SELECT (max(rowid)+1)/2 FROM operations);")
		data, _ := os.ReadFile(half)
		if err := os.WriteFile(filepath.Join(root, legacyJournalName), data, 0o600); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("fold mode %q", mode)
	}
	openLedger(t, root).Close()
	os.Remove(filepath.Join(root, legacyJournalName))
	side := false
	for _, name := range names {
		data, _ := os.ReadFile(filepath.Join(aside, filepath.Base(name)))
		if err := os.WriteFile(name, data, 0o600); err != nil {
			t.Fatal(err)
		}
		side = side || filepath.Base(name) != legacyJournalName
	}
	options := ReconcileOptions{Apply: true}
	if !side {
		options = retireOptions(t, false, t.TempDir())
	}
	report, err := ReconcileLegacyWith(context.Background(), root, options)
	// A fixture whose second half is empty has nothing to fold in prefix mode.
	if err != nil || report.Diverged != report.Applied || mode == "empty" && !report.Applied ||
		options.Retire && !report.Retire.Retired {
		t.Fatalf("fold (%s): err=%v report=%+v", mode, err, report)
	}
	t.Logf("fold %s %s: diverged=%v rows %d->%d added_changes=%d settings_adopted=%v retired=%v", filepath.Base(root), mode,
		report.Diverged, report.LedgerRowsBefore, report.LedgerRowsAfter, len(report.AddedChanges), report.SettingsAdopted,
		options.Retire && report.Retire.Retired)
}

// Usage, request and spending limits, reconciliation holds and configuration
// identity carry across the fold exactly as across the import: the same
// continuation, started from a folded ledger, must give the canonical outputs
// pinned for TestDifferentialLedgerContinuation.
func TestFoldedLedgerContinuation(t *testing.T) {
	f := newCLIFixture(t)
	for i, name := range ledgerFixtures {
		for _, mode := range []string{"empty", "prefix"} {
			c := continuation(f, "continue-"+name, fixtureDir(t, name))
			b, err := json.Marshal(c)
			if err != nil {
				t.Fatal(err)
			}
			expected := referenceLookup(t, fmt.Sprint(i), string(b), caseRoots(c), c.Env, c.Unset, nil,
				fmt.Sprintf("TestDifferentialLedgerContinuation/%d", i))
			// State oracle: the folded ledger holds exactly what the deployed
			// automatic import of the same fixture holds (rows in order,
			// configuration changes, settings identity and value).
			imported := filepath.Join(t.TempDir(), "rotation-text")
			copyFixture(t, c.Fixture, imported)
			folded := filepath.Join(t.TempDir(), "rotation-text")
			copyFixture(t, c.Fixture, folded)
			prepareFoldedRoot(t, folded, mode)
			if want, got := ledgerStateOf(t, imported), ledgerStateOf(t, folded); want != got {
				t.Errorf("%s folded from %s: state differs from the import\n import: %s\n folded: %s", name, mode, clip(want, 800), clip(got, 800))
			}
			c.fold = mode
			got := runGo(t, c)
			if compact(parseJSON(expected)) != compact(finite(got)) {
				t.Errorf("%s folded from %s differs from the canonical continuation", name, mode)
			}
		}
	}
}

func ledgerStateOf(t *testing.T, root string) string {
	t.Helper()
	ledger := openLedger(t, root)
	defer ledger.Close()
	state := ledger.state
	b, err := json.Marshal(struct {
		HasSettings               bool
		SettingsID, SettingsValue string
		Changes                   []ledgerChange
		Rows                      []Operation
	}{state.HasSettings, state.SettingsID, state.SettingsValue, state.Changes, state.Rows})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

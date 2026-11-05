//go:build darwin

package rotationtext

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The scan's answers go through the real retirement gate: every incomplete
// or unparsable answer refuses and swaps back; none counts as "no holders".
func TestRetireRefusesIncompleteDarwinScans(t *testing.T) {
	self := strconv.Itoa(os.Getpid())
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if executable, err = filepath.EvalSymlinks(executable); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name   string
		stdout string
		stderr string
		code   int
		err    error
		want   string
	}{
		// The real result of a failed lookup on this Mac (9cc's probe).
		{"exit1-empty-diagnostic", "", "lsof: status error on /missing: No such file or directory\nlsof 4.91\n usage: ...\n", 1, nil, "lsof exit 1"},
		{"exit1-empty-silent", "", "", 1, nil, "lsof exit 1"},
		{"exit0-with-diagnostic", "p" + self + "\nf9\n", "lsof: WARNING: can't stat() nfs file system\n", 0, nil, "diagnostics"},
		{"self-missing", "p999999\nf9\n", "", 0, nil, "own descriptor"},
		{"malformed", "p" + self + "\nf9\npX\nf3\n", "", 0, nil, "grammar"},
		{"truncated", "p" + self + "\nf9", "", 0, nil, "grammar"},
		{"did-not-run", "", "", -1, errors.New("exec: no such file"), "did not run"},
	} {
		t.Run(c.name, func(t *testing.T) {
			root, _ := divergedRoot(t)
			legacy := filepath.Join(root, legacyJournalName)
			original := lstat(t, legacy)
			saved := runLsof
			defer func() { runLsof = saved }()
			runLsof = func(ctx context.Context, args ...string) ([]byte, []byte, int, error) {
				if strings.Contains(strings.Join(args, " "), "-d txt") {
					// pid 999999 runs a reviewed image (this test binary).
					st := lstat(t, executable).Sys().(*syscall.Stat_t)
					return []byte("p999999\nftxt\nD0x" + strconv.FormatUint(uint64(uint32(st.Dev)), 16) + "\ni" +
						strconv.FormatUint(uint64(st.Ino), 10) + "\nn" + executable + "\n"), nil, 0, nil
				}
				return []byte(c.stdout), []byte(c.stderr), c.code, c.err
			}
			report, err := ReconcileLegacyWith(context.Background(), root, retireOptions(t, true, helperDir(t, false)))
			var scan *errHolderScan
			if !errors.As(err, &scan) || !strings.Contains(err.Error(), c.want) || report.Retire == nil || !report.Retire.SwappedBack {
				t.Fatalf("incomplete scan not refused: err=%v retire=%+v", err, report.Retire)
			}
			if !os.SameFile(lstat(t, legacy), original) || len(retiredFiles(t, root)) != 0 {
				t.Fatal("refusal did not restore the legacy file")
			}
		})
	}
	// The scan must see this process itself: a real scan of a file nobody
	// holds is exit 1 with no output, which is refused, not "no holders".
	unheld := filepath.Join(t.TempDir(), "unheld")
	os.WriteFile(unheld, nil, 0o600)
	info := lstat(t, unheld)
	if holders, err := platformLegacyHolders(context.Background(), unheld, info); err == nil {
		t.Fatalf("an empty real scan was accepted: %v", holders)
	}
}

// lsof runs under the caller's bounded context: a context that has already
// ended never runs it, and the gate turns that into an incomplete scan.
func TestRetireLsofHonoursTheContext(t *testing.T) {
	path := filepath.Join(t.TempDir(), "held")
	os.WriteFile(path, nil, 0o600)
	held, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if stdout, _, code, err := runLsof(ctx, "-n", "-P", "-F", "p", "--", path); err == nil && code == 0 {
		t.Fatalf("lsof ran under an ended context: %q", stdout)
	}
	var scan *errHolderScan
	if _, err := platformLegacyHolders(ctx, path, lstat(t, path)); !errors.As(err, &scan) {
		t.Fatalf("ended context: %v", err)
	}
	if holders, err := platformLegacyHolders(context.Background(), path, lstat(t, path)); err != nil || len(holders) != 1 || holders[0].PID != os.Getpid() {
		t.Fatalf("live scan of a self-held file: %v %v", holders, err)
	}
}

// startCopiedHolder runs a copy of this test binary, at a path the test can
// replace, as a process holding legacy open with no lock.
func startCopiedHolder(t *testing.T, legacy string) (string, *exec.Cmd) {
	t.Helper()
	executable, _ := os.Executable()
	data, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	image := filepath.Join(dir, "holder-image")
	if err := os.WriteFile(image, data, 0o755); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(image, "-test.run=^TestRetireHelperProcess$", "-test.count=1")
	command.Env = append(os.Environ(), "RT_RETIRE_HELPER=hold-open", "RT_RETIRE_FILE="+legacy)
	stdin, _ := command.StdinPipe()
	stdout, _ := command.StdoutPipe()
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { stdin.Close(); command.Wait() })
	if line, _ := bufio.NewReader(stdout).ReadString('\n'); line != "open\n" {
		t.Fatalf("helper: %q", line)
	}
	return image, command
}

// replaceWith atomically renames a new file with content over path.
func replaceWith(t *testing.T, path string, content []byte) {
	t.Helper()
	next := path + ".next"
	if err := os.WriteFile(next, content, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(next, path); err != nil {
		t.Fatal(err)
	}
}

// The holder keeps running its old (unreviewed) vnode while its pathname is
// replaced by a reviewed file: between the identity check and the hash, or
// before the scan. The hash must come from the running vnode, so both refuse.
func TestRetireImageReplacedDuringTheCheck(t *testing.T) {
	replacement := []byte("#!/bin/sh\n# a reviewed file that is not the running image\n")
	for _, when := range []string{"between-check-and-hash", "before-the-scan"} {
		t.Run(when, func(t *testing.T) {
			root, _ := divergedRoot(t)
			legacy := filepath.Join(root, legacyJournalName)
			original := lstat(t, legacy)
			image, holder := startCopiedHolder(t, legacy)
			saved := imageCheckHook
			defer func() { imageCheckHook = saved }()
			if when == "before-the-scan" {
				replaceWith(t, image, replacement)
			} else {
				imageCheckHook = func(path string) {
					if path == image {
						replaceWith(t, image, replacement)
					}
				}
			}
			options := retireOptions(t, false, helperDir(t, false))
			options.AllowedImages = append(options.AllowedImages, bytesSHA256(replacement))
			report, err := ReconcileLegacyWith(context.Background(), root, options)
			if err == nil || !strings.Contains(err.Error(), strconv.Itoa(holder.Process.Pid)) || !strings.Contains(err.Error(), "not a reviewed image") ||
				!report.Retire.SwappedBack || !os.SameFile(lstat(t, legacy), original) {
				t.Fatalf("replaced image accepted: err=%v retire=%+v", err, report.Retire)
			}
		})
	}
}

// Capture is bounded while the command runs: an overflow on either stream
// kills it and is an error, never partial output.
func TestRunCappedRefusesOverflow(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	for _, script := range []string{
		"head -c 3000000 /dev/zero",
		"head -c 200000 /dev/zero 1>&2",
		"exec /usr/bin/yes", // never ends by itself
	} {
		started := time.Now()
		if out, _, _, err := runCapped(ctx, "/bin/sh", "-c", script); !errors.Is(err, errCaptureOverflow) || out != nil {
			t.Fatalf("%s: err=%v, %d bytes", script, err, len(out))
		}
		if time.Since(started) > 10*time.Second {
			t.Fatalf("%s: overflow did not stop the command", script)
		}
	}
	if out, _, code, err := runCapped(ctx, "/bin/sh", "-c", "printf p1"); err != nil || code != 0 || string(out) != "p1" {
		t.Fatalf("small output: %q %d %v", out, code, err)
	}
}

package helperbundle

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestInstallFixtureExecutableHolder(t *testing.T) {
	if os.Getenv("RELAY_TEST_INSTALL_UNAME_HOLDER") != "1" {
		return
	}
	if _, err := os.Stdout.Write([]byte("ready\n")); err != nil {
		os.Exit(93)
	}
	var data [1]byte
	if _, err := io.ReadFull(os.Stdin, data[:]); err != io.EOF {
		os.Exit(94)
	}
	os.Exit(0)
}

func TestInstallFixtureReplacesExecutingHelper(t *testing.T) {
	home := t.TempDir()
	tools := filepath.Join(home, "tools")
	if err := os.MkdirAll(tools, 0700); err != nil {
		t.Fatal(err)
	}
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	executable, err := os.ReadFile(binary)
	if err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(tools, "uname")
	if err = os.WriteFile(target, executable, 0700); err != nil {
		t.Fatal(err)
	}
	child := exec.Command(target, "-test.run=^TestInstallFixtureExecutableHolder$")
	child.Env = append(os.Environ(), "RELAY_TEST_INSTALL_UNAME_HOLDER=1", "GORACE=atexit_sleep_ms=0")
	input, err := child.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = child.Start(); err != nil {
		t.Fatal(err)
	}
	waited := make(chan error, 1)
	go func() { waited <- child.Wait() }()
	joined := false
	t.Cleanup(func() {
		_ = input.Close()
		if joined {
			return
		}
		select {
		case <-waited:
		case <-time.After(5 * time.Second):
			_ = child.Process.Kill()
			<-waited
			t.Error("owned fixture child did not exit after release")
		}
	})
	ready := make(chan error, 1)
	go func() {
		var b [6]byte
		_, err := io.ReadFull(output, b[:])
		if err == nil && !bytes.Equal(b[:], []byte("ready\n")) {
			err = io.ErrUnexpectedEOF
		}
		ready <- err
	}()
	select {
	case err = <-ready:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("owned fixture child did not become ready")
	}
	before, err := os.Stat(target)
	if err != nil {
		t.Fatal(err)
	}
	if out, err := install(t, home, archive(t, ""), false); err != nil {
		t.Fatalf("FIXTURE_EXECUTABLE_PUBLICATION: installation failed: %v %s", err, out)
	}
	after, err := os.Stat(target)
	if err != nil || os.SameFile(before, after) {
		t.Fatalf("FIXTURE_EXECUTABLE_PUBLICATION: running helper inode was reused: %v", err)
	}
	select {
	case err = <-waited:
		joined = true
		t.Fatalf("FIXTURE_EXECUTABLE_PUBLICATION: replaced helper stopped the existing child: %v", err)
	default:
	}
	if err = input.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err = <-waited:
		joined = true
		if err != nil {
			t.Fatalf("owned fixture child exited incorrectly: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("owned fixture child did not exit after release")
	}
	waitForDetachedInstall(t, home)
}

// A previous receipt remains observable until the detached installer atomically
// publishes its replacement. Equal bytes are expected; inode identity changes.
func installReceiptIsCurrent(previous, current os.FileInfo) bool {
	return current != nil && current.Mode().IsRegular() && current.Size() > 0 &&
		(previous == nil || !os.SameFile(previous, current))
}

func waitForInstallReceiptGeneration(t *testing.T, home string, previous os.FileInfo) {
	t.Helper()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	path := filepath.Join(home, ".local/share/relay/upgrade-workers-last.json")
	for {
		current, err := os.Lstat(path)
		if err == nil && installReceiptIsCurrent(previous, current) {
			return
		}
		select {
		case <-timer.C:
			t.Fatal("FIXTURE_RECEIPT_GENERATION: current detached receipt missing before cleanup")
		case <-tick.C:
		}
	}
}

func TestInstallReceiptGeneration(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "receipt")
	body := []byte("fixture upgrade-workers\n")
	if err := os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
	previous, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if installReceiptIsCurrent(previous, previous) {
		t.Fatal("FIXTURE_RECEIPT_GENERATION: previous receipt admitted as current")
	}
	if installReceiptIsCurrent(previous, nil) {
		t.Fatal("FIXTURE_RECEIPT_GENERATION: absent receipt admitted")
	}
	if !installReceiptIsCurrent(nil, previous) {
		t.Fatal("FIXTURE_RECEIPT_GENERATION: first receipt refused")
	}
	next := filepath.Join(dir, "new")
	if err = os.WriteFile(next, body, 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.Rename(next, path); err != nil {
		t.Fatal(err)
	}
	current, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(data, body) {
		t.Fatal("FIXTURE_RECEIPT_GENERATION: receipt bytes changed")
	}
	if !installReceiptIsCurrent(previous, current) {
		t.Fatal("FIXTURE_RECEIPT_GENERATION: replacement inode refused")
	}
	empty := filepath.Join(dir, "empty")
	if err = os.WriteFile(empty, nil, 0600); err != nil {
		t.Fatal(err)
	}
	emptyInfo, err := os.Lstat(empty)
	if err != nil {
		t.Fatal(err)
	}
	dirInfo, err := os.Lstat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if installReceiptIsCurrent(previous, emptyInfo) || installReceiptIsCurrent(previous, dirInfo) {
		t.Fatal("FIXTURE_RECEIPT_GENERATION: empty or directory receipt admitted")
	}
}

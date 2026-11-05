//go:build darwin

package appupdate

import (
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWatcherChild(t *testing.T) {
	if os.Getenv("RELAY_UPDATE_WATCH_CHILD") != "1" {
		return
	}
	io.Copy(io.Discard, os.Stdin)
	os.Exit(0)
}
func TestKernelIdentityAndExitEvent(t *testing.T) {
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	cmd := exec.Command(exe, "-test.run=^TestWatcherChild$")
	cmd.Env = append(os.Environ(), "RELAY_UPDATE_WATCH_CHILD=1")
	input, e := cmd.StdinPipe()
	if e != nil {
		t.Fatal(e)
	}
	if e = cmd.Start(); e != nil {
		t.Fatal(e)
	}
	defer func() {
		input.Close()
		if cmd.ProcessState == nil {
			cmd.Wait()
		}
	}()
	pid := cmd.Process.Pid
	id, e := kernelIdentity(pid)
	if e != nil {
		t.Fatal(e)
	}
	info, e := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if e != nil {
		t.Fatal(e)
	}
	suffix := fmt.Sprintf(":%d:%d:%d:%d", pid, info.Eproc.Ucred.Uid, info.Proc.P_starttime.Sec, info.Proc.P_starttime.Usec)
	if !strings.HasPrefix(id, "darwin-v1:") || !strings.HasSuffix(id, suffix) {
		t.Fatal("exact kernel incarnation changed")
	}
	watch, e := newWatcher()
	if e != nil {
		t.Fatal(e)
	}
	defer watch.Close()
	if e = watch.Register(pid); e != nil {
		t.Fatal(e)
	}
	input.Close()
	events, e := watch.Wait(1, 5*time.Second)
	if e != nil || len(events) != 1 || events[0] != pid {
		t.Fatal("native exit event lost", events, e)
	}
	if e = cmd.Wait(); e != nil {
		t.Fatal(e)
	}
	if _, e = kernelIdentity(pid); e == nil {
		t.Fatal("reaped process identity accepted")
	}
}
func TestBinaryPlistAdapter(t *testing.T) {
	p := filepath.Join(t.TempDir(), "preferences.plist")
	put(t, p, plistStrings(map[string]string{"relay.workspace.v1": "fixture", "CFBundleIdentifier": "dev.relay.terminal"}), 0600)
	e := &Engine{Run: execute}
	if _, err := e.command(15*time.Second, "/usr/bin/plutil", "-convert", "binary1", p); err != nil {
		t.Fatal(err)
	}
	m, err := e.plist(p)
	if err != nil || m["relay.workspace.v1"] != "fixture" {
		t.Fatal("binary plist adapter failed", err)
	}
}

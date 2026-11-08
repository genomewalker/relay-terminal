//go:build darwin && cgo

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func requireResponsibilityLookup(t *testing.T) int {
	t.Helper()
	own, ok := responsiblePID(os.Getpid())
	if !ok {
		t.Skip("responsibility_get_pid_responsible_for_pid is unavailable on this macOS")
	}
	return own
}

func openSpawnLog(t *testing.T) (*os.File, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "relayd.log")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { file.Close() })
	return file, path
}

func reapLater(t *testing.T, process *os.Process) {
	t.Cleanup(func() {
		_ = process.Kill()
		_, _ = process.Wait()
	})
}

// A disclaimed launch makes the child its own responsible process. To show
// that the check discriminates, a disclaimed helper (this test binary) starts
// one ordinary exec.Cmd child, which must be attributed to the helper, and one
// disclaimed child, which must be attributed to itself. The helper is needed
// because a test runner whose original responsible process has exited is
// reported as responsible for itself, which would hide the difference.
func TestSupervisorSpawnDisclaimsResponsibility(t *testing.T) {
	requireResponsibilityLookup(t)
	logFile, logPath := openSpawnLog(t)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	helper, disclaimed, err := spawnSupervisorDisclaimed(executable,
		[]string{executable, "-test.run=^TestSupervisorSpawnResponsibilityHelper$"},
		append(os.Environ(), "RELAY_RESPONSIBILITY_HELPER=1"), logFile)
	if err != nil {
		t.Fatal(err)
	}
	if !disclaimed {
		reapLater(t, helper)
		t.Skip("responsibility_spawnattrs_setdisclaim is unavailable on this macOS")
	}
	if state, err := helper.Wait(); err != nil || !state.Success() {
		data, _ := os.ReadFile(logPath)
		t.Fatalf("helper exited with %v, %v:\n%s", state, err, data)
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	values := map[string][2]int{}
	for _, line := range strings.Split(string(data), "\n") {
		var name string
		var pid, responsible int
		if n, _ := fmt.Sscanf(line, "responsibility %s %d %d", &name, &pid, &responsible); n == 3 {
			values[name] = [2]int{pid, responsible}
		}
	}
	self, plain, disclaimedChild := values["helper"], values["plain"], values["disclaimed"]
	if self[0] != helper.Pid || self[1] != helper.Pid {
		t.Fatalf("disclaimed helper %d is attributed to %v, want itself:\n%s", helper.Pid, self, data)
	}
	if plain[0] == 0 || plain[1] != helper.Pid {
		t.Fatalf("plain child %v is not attributed to its helper %d:\n%s", plain, helper.Pid, data)
	}
	if disclaimedChild[0] == 0 || disclaimedChild[1] != disclaimedChild[0] {
		t.Fatalf("disclaimed child %v is not attributed to itself:\n%s", disclaimedChild, data)
	}
}

func TestSupervisorSpawnResponsibilityHelper(t *testing.T) {
	if os.Getenv("RELAY_RESPONSIBILITY_HELPER") != "1" {
		t.Skip("runs only as the disclaimed helper of TestSupervisorSpawnDisclaimsResponsibility")
	}
	report := func(name string, pid int) {
		responsible, _ := responsiblePID(pid)
		fmt.Printf("responsibility %s %d %d\n", name, pid, responsible)
	}
	report("helper", os.Getpid())
	plain := exec.Command("/bin/sleep", "30")
	if err := plain.Start(); err != nil {
		t.Fatal(err)
	}
	reapLater(t, plain.Process)
	report("plain", plain.Process.Pid)
	devNull, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer devNull.Close()
	child, _, err := spawnSupervisorDisclaimed("/bin/sleep", []string{"sleep", "30"}, os.Environ(), devNull)
	if err != nil {
		t.Fatal(err)
	}
	reapLater(t, child)
	report("disclaimed", child.Pid)
}

// The disclaimed path must keep the exec.Cmd launch contract: new session,
// stdin from /dev/null, stdout and stderr in the log, environment as given,
// and no inherited descriptors beyond stdio.
func TestSupervisorSpawnKeepsExecContract(t *testing.T) {
	logFile, logPath := openSpawnLog(t)
	// A descriptor without close-on-exec must not reach the supervisor.
	leaked, err := syscall.Dup(int(logFile.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(leaked)

	script := `echo "pgid=$(ps -o pgid= -p $$ | tr -d ' ') pid=$$"
echo "env=$RELAY_SPAWN_PROBE"
echo "fds=$(ls /dev/fd | tr '\n' ' ')"
if read line; then echo stdin=data; else echo stdin=eof; fi
echo stderr-line >&2`
	child := exec.Command("/bin/sh", "-c", script)
	child.Env = append(os.Environ(), "RELAY_SPAWN_PROBE=kept")
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	process, err := startSupervisorProcess(child, logFile)
	if err != nil {
		t.Fatal(err)
	}
	state, err := process.Wait()
	if err != nil || !state.Success() {
		t.Fatalf("probe exited with %v, %v", state, err)
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	output := string(data)
	pid := strconv.Itoa(process.Pid)
	if !strings.Contains(output, "pgid="+pid+" pid="+pid) {
		t.Fatalf("probe is not a process group/session leader:\n%s", output)
	}
	for _, want := range []string{"env=kept", "stdin=eof", "stderr-line"} {
		if !strings.Contains(output, want) {
			t.Fatalf("missing %q in probe output:\n%s", want, output)
		}
	}
	fds := ""
	for _, line := range strings.Split(output, "\n") {
		if strings.HasPrefix(line, "fds=") {
			fds = " " + strings.TrimPrefix(line, "fds=")
		}
	}
	if fds == "" || strings.Contains(fds, " "+strconv.Itoa(leaked)+" ") {
		t.Fatalf("probe inherited descriptor %d:\n%s", leaked, output)
	}
}

// Informational: whether a grandchild of a disclaimed process that has already
// exited is attributed to itself, to the vanished parent, or elsewhere.
func TestSupervisorSpawnGrandchildAttributionProbe(t *testing.T) {
	requireResponsibilityLookup(t)
	logFile, logPath := openSpawnLog(t)
	process, disclaimed, err := spawnSupervisorDisclaimed("/bin/sh",
		[]string{"sh", "-c", "/bin/sleep 5 & echo $!"}, os.Environ(), logFile)
	if err != nil {
		t.Fatal(err)
	}
	if !disclaimed {
		t.Skip("responsibility_spawnattrs_setdisclaim is unavailable on this macOS")
	}
	_, _ = process.Wait()
	var grandchild int
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		data, _ := os.ReadFile(logPath)
		if value, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
			grandchild = value
			break
		}
	}
	if grandchild == 0 {
		t.Fatal("grandchild pid was not reported")
	}
	defer syscall.Kill(grandchild, syscall.SIGKILL)
	got, _ := responsiblePID(grandchild)
	t.Logf("disclaimed parent %d exited; grandchild %d is attributed to %d", process.Pid, grandchild, got)
}

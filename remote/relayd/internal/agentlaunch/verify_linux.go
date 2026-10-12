//go:build linux

package agentlaunch

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
)

// VerifyProcess checks the original owner, incarnation, executable, working
// directory and pane at the last possible moment before a new launch.
func VerifyProcess(snapshot Snapshot) error {
	root := filepath.Join("/proc", strconv.Itoa(snapshot.PID))
	info, err := os.Stat(root)
	if err != nil {
		return errors.New("source process is unavailable")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return errors.New("source process owner changed")
	}
	before, err := startFor(snapshot.PID)
	if err != nil || before != snapshot.ProcessStart {
		return errors.New("source process incarnation changed")
	}
	executable, err := os.Stat(snapshot.Executable)
	if err != nil {
		return errors.New("source executable is unavailable")
	}
	actual, err := os.Stat(filepath.Join(root, "exe"))
	if err != nil || !os.SameFile(executable, actual) {
		return errors.New("source executable changed")
	}
	cwd, err := os.Readlink(filepath.Join(root, "cwd"))
	if err != nil || cwd != snapshot.CWD {
		return errors.New("source working directory changed")
	}
	command, err := boundedRead(filepath.Join(root, "cmdline"))
	if err != nil {
		return errors.New("source arguments are unavailable")
	}
	argv := strings.Split(strings.TrimRight(string(command), "\x00"), "\x00")
	if len(argv) == 0 || !reflect.DeepEqual(argv[1:], snapshot.EffectiveArgs) {
		return errors.New("source arguments changed")
	}
	environment, err := boundedRead(filepath.Join(root, "environ"))
	if err != nil {
		return errors.New("source pane is unavailable")
	}
	joined := "\x00" + string(environment)
	if !strings.Contains(joined, "\x00RELAY_SESSION="+snapshot.RelayPaneID+"\x00") {
		return errors.New("source pane changed")
	}
	after, err := startFor(snapshot.PID)
	if err != nil || after != snapshot.ProcessStart {
		return errors.New("source process incarnation changed")
	}
	return nil
}

//go:build darwin

package appupdate

import (
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"os"
	"strings"
	"time"
)

func kernelIdentity(pid int) (string, error) {
	if pid <= 0 || pid > 1<<31-1 {
		return "", errors.New("invalid pid")
	}
	boot, err := unix.Sysctl("kern.bootsessionuuid")
	if err != nil {
		return "", err
	}
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return "", err
	}
	if info == nil || int(info.Proc.P_pid) != pid || info.Proc.P_stat == 5 || info.Proc.P_starttime.Sec <= 0 || info.Proc.P_starttime.Usec < 0 || info.Proc.P_starttime.Usec >= 1000000 {
		return "", errors.New("kernel process identity unavailable")
	}
	boot = strings.TrimSpace(boot)
	if boot == "" {
		return "", errors.New("boot identity unavailable")
	}
	return fmt.Sprintf("darwin-v1:%s:%d:%d:%d:%d", boot, pid, info.Eproc.Ucred.Uid, info.Proc.P_starttime.Sec, info.Proc.P_starttime.Usec), nil
}

type procWatcher struct{ fd int }

func newWatcher() (Watcher, error) {
	fd, err := unix.Kqueue()
	if err != nil {
		return nil, err
	}
	unix.CloseOnExec(fd)
	return &procWatcher{fd}, nil
}
func (w *procWatcher) Register(pid int) error {
	event := unix.Kevent_t{Ident: uint64(pid), Filter: unix.EVFILT_PROC, Flags: unix.EV_ADD | unix.EV_ONESHOT, Fflags: unix.NOTE_EXIT}
	_, err := unix.Kevent(w.fd, []unix.Kevent_t{event}, nil, nil)
	if err == unix.ESRCH {
		return os.ErrProcessDone
	}
	return err
}
func (w *procWatcher) Wait(n int, d time.Duration) ([]int, error) {
	if n < 1 || n > 65536 || d <= 0 {
		return nil, errors.New("invalid exit wait bound")
	}
	events := make([]unix.Kevent_t, n)
	timeout := unix.NsecToTimespec(d.Nanoseconds())
	count, err := unix.Kevent(w.fd, nil, events, &timeout)
	if err != nil {
		return nil, err
	}
	out := []int{}
	for _, v := range events[:count] {
		if v.Flags&unix.EV_ERROR != 0 {
			return nil, fmt.Errorf("process event error: %d", v.Data)
		}
		if v.Filter == unix.EVFILT_PROC && v.Fflags&unix.NOTE_EXIT != 0 {
			out = append(out, int(v.Ident))
		}
	}
	return out, nil
}
func (w *procWatcher) Close() error { return unix.Close(w.fd) }

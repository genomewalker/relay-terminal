//go:build linux

package daemon

import (
	"errors"
	"strconv"
	"syscall"

	"golang.org/x/sys/unix"
)

// forceAccountObserveLinux accepts only an immediate child of the verified
// provider, with stable owner, full start time, parent and complete argv.
func forceAccountObserveLinux(server *Server, target forceAccountTarget) (forceAccountObservation, error) {
	out := forceAccountObservation{Target: target}
	if !forceAccountDefaultStateRoot(server) {
		return out, errors.New("custom host state root unsupported")
	}
	var binding AgentBindingRecord
	var err error
	switch target.Provider {
	case "claude":
		binding, err = ReadNativeClaudeBinding(target.Pane)
	case "codex":
		binding, err = ReadNativeCodexBinding(target.Pane)
	default:
		return out, errors.New("unsupported provider")
	}
	if err != nil || binding.SessionID != target.Session || binding.Producer.ProcessID != target.ProviderPID || strconv.FormatUint(binding.Producer.ProcessStart, 10) != target.ProviderStart {
		return out, errors.New("provider binding unavailable or changed")
	}
	process, err := forceLinuxReadProcess("/proc", target.BlockerPID)
	if err != nil {
		if syscall.Kill(target.BlockerPID, 0) == syscall.ESRCH {
			out.Complete = true
			return out, nil
		}
		return out, errors.New("selected process identity unavailable")
	}
	if process.Parent != target.ProviderPID || process.Start != target.BlockerStart || forceAccountCommandDigest(process.Argv) != target.CommandDigest {
		return out, errors.New("selected process identity, ancestry or command changed")
	}
	out.Complete, out.Present, out.Descendant, out.CommandMatches = true, true, true, true
	return out, nil
}

func forceAccountPreviewLinux(server *Server, target forceAccountTarget) (forceAccountTarget, []string, error) {
	process, err := forceLinuxReadProcess("/proc", target.BlockerPID)
	if err != nil {
		return target, nil, errors.New("selected process preview unavailable")
	}
	if target.BlockerStart != "" && target.BlockerStart != process.Start {
		return target, nil, errors.New("selected process incarnation changed")
	}
	target.BlockerStart = process.Start
	target.CommandDigest = forceAccountCommandDigest(process.Argv)
	if err := forceAccountValidateReviewedArgv(target, process.Argv); err != nil {
		return target, nil, err
	}
	observation, err := forceAccountObserveLinux(server, target)
	if err != nil || !observation.Complete || !observation.Present {
		return target, nil, errors.New("selected process preview unavailable or changed")
	}
	inventory, err := server.processInventory()
	if err != nil || !forceAccountInventoryMember(inventory, target, processStartIdentity) {
		return target, nil, errors.New("selected process is not in pane host inventory")
	}
	observation, err = forceAccountObserveLinux(server, target)
	if err != nil || !observation.Complete || !observation.Present {
		return target, nil, errors.New("selected process preview changed during inventory lookup")
	}
	return target, process.Argv, nil
}

func (a *forceAccountAttempt) forceAccountStopLinux(server *Server, target forceAccountTarget) (forceAccountResult, error) {
	if server == nil || target.BlockerPID <= 1 {
		return forceAccountUnknown, errors.New("host server and selected PID required")
	}
	// pidfd pins the process where the kernel supports it. Older kernels (such
	// as dandy-07's 4.18) lack pidfd_open; the numeric fallback retains the
	// documented PID reuse and ancestry race between observation and signal.
	fd, err := forceLinuxProcessHandle(target.BlockerPID)
	if err != nil {
		return forceAccountUnknown, errors.New("could not pin selected process")
	}
	if fd >= 0 {
		defer unix.Close(fd)
	}
	return a.signalSelected(target, func() (forceAccountObservation, error) {
		observed, err := forceAccountObserveLinux(server, target)
		if err != nil || !observed.Present {
			return observed, err
		}
		inventory, err := server.processInventory()
		if err != nil {
			return forceAccountObservation{}, err
		}
		if !forceAccountInventoryMember(inventory, target, processStartIdentity) {
			return forceAccountObservation{}, errors.New("selected process is not in pane host inventory")
		}
		return forceAccountObserveLinux(server, target)
	}, func(pid int) error {
		return forceLinuxSignal(fd, pid)
	})
}

func forceLinuxProcessHandle(pid int) (int, error) {
	fd, err := unix.PidfdOpen(pid, 0)
	if err == unix.ENOSYS {
		return -1, nil
	}
	return fd, err
}

func forceLinuxSignal(fd, pid int) error {
	if fd >= 0 {
		return unix.PidfdSendSignal(fd, unix.SIGTERM, nil, 0)
	}
	return syscall.Kill(pid, syscall.SIGTERM)
}

func accountForcePreviewPlatform(server *Server, target forceAccountTarget) (any, error) {
	target, argv, err := forceAccountPreviewLinux(server, target)
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": "ready", "target": target, "argv": argv}, nil
}

func accountForceCommitPlatform(server *Server, target forceAccountTarget, reviewedArgv []string) (forceAccountResult, error) {
	if err := forceAccountValidateReviewedArgv(target, reviewedArgv); err != nil {
		return forceAccountUnknown, err
	}
	return (&forceAccountAttempt{}).forceAccountStopLinux(server, target)
}

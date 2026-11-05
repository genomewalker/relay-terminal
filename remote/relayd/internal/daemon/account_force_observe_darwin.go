//go:build darwin

package daemon

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"syscall"
)

// forceAccountObserveDarwin only accepts an immediate child of the verified
// provider. It observes the process's owner, start, parent and complete argv.
// It does not classify process roles, freeze ancestry, or eliminate PID reuse.
func forceAccountObserveDarwin(server *Server, target forceAccountTarget) (forceAccountObservation, error) {
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
	info, err := darwinProcessInfo(target.BlockerPID)
	if err != nil {
		if syscall.Kill(target.BlockerPID, 0) == syscall.ESRCH {
			out.Complete = true
			return out, nil
		}
		return out, errors.New("selected process identity unavailable")
	}
	if int(info.Eproc.Ucred.Uid) != os.Getuid() || int(info.Eproc.Ppid) != target.ProviderPID {
		return out, errors.New("selected process owner or parent changed")
	}
	before, err := processStartTime(target.BlockerPID)
	if err != nil || strconv.FormatUint(before, 10) != target.BlockerStart {
		return out, errors.New("selected process identity changed")
	}
	var argv []string
	if phCatchAll(func() { argv = phProcessArguments(int64(target.BlockerPID)) }) || len(argv) == 0 {
		return out, errors.New("selected process arguments unavailable")
	}
	after, err := processStartTime(target.BlockerPID)
	if err != nil || after != before {
		return out, errors.New("selected process identity changed while reading command")
	}
	info, err = darwinProcessInfo(target.BlockerPID)
	if err != nil || int(info.Eproc.Ppid) != target.ProviderPID || int(info.Eproc.Ucred.Uid) != os.Getuid() {
		return out, errors.New("selected process ancestry changed")
	}
	if forceAccountCommandDigest(argv) != target.CommandDigest {
		return out, fmt.Errorf("selected process command changed")
	}
	out.Complete, out.Present, out.Descendant, out.CommandMatches = true, true, true, true
	return out, nil
}

// forceAccountStopDarwin sends a single SIGTERM only after the attempt guard's
// two observations. A missing/uncertain post-observation is never success.
func (a *forceAccountAttempt) forceAccountStopDarwin(server *Server, target forceAccountTarget) (forceAccountResult, error) {
	if server == nil {
		return forceAccountUnknown, errors.New("host server required")
	}
	return a.signalSelected(target, func() (forceAccountObservation, error) {
		observed, err := forceAccountObserveDarwin(server, target)
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
		// Recheck binding, PID/start, parent and argv after the inventory lookup.
		return forceAccountObserveDarwin(server, target)
	}, func(pid int) error { return syscall.Kill(pid, syscall.SIGTERM) })
}

// forceAccountPreviewDarwin returns the full strict-UTF-8 argv for display and
// a target bound to its digest. Caller supplies explicitly selected identities.
func forceAccountPreviewDarwin(server *Server, target forceAccountTarget) (forceAccountTarget, []string, error) {
	// The inventory's display start has only second resolution. Resolve the
	// selected PID to its full kernel start here, then bind the card to that
	// incarnation. A supplied exact start remains an additional constraint.
	start, err := processStartTime(target.BlockerPID)
	if err != nil || start == 0 {
		return target, nil, errors.New("selected process incarnation unavailable")
	}
	exactStart := strconv.FormatUint(start, 10)
	if target.BlockerStart != "" && target.BlockerStart != exactStart {
		return target, nil, errors.New("selected process incarnation changed")
	}
	target.BlockerStart = exactStart
	var argv []string
	if phCatchAll(func() { argv = phProcessArguments(int64(target.BlockerPID)) }) || len(argv) == 0 {
		return target, nil, errors.New("selected process arguments unavailable")
	}
	target.CommandDigest = forceAccountCommandDigest(argv)
	if err := forceAccountValidateReviewedArgv(target, argv); err != nil {
		return target, nil, err
	}
	observation, err := forceAccountObserveDarwin(server, target)
	if err != nil || !observation.Complete || !observation.Present {
		return target, nil, errors.New("selected process preview unavailable or changed")
	}
	// A preview must describe a process the existing pane inventory permits
	// this host to signal. The commit repeats these checks; this preview is not
	// a reservation or authorization to act later.
	inventory, err := server.processInventory()
	if err != nil || !forceAccountInventoryMember(inventory, target, processStartIdentity) {
		return target, nil, errors.New("selected process is not in pane host inventory")
	}
	observation, err = forceAccountObserveDarwin(server, target)
	if err != nil || !observation.Complete || !observation.Present {
		return target, nil, errors.New("selected process preview changed during inventory lookup")
	}
	return target, argv, nil
}

func accountForcePreviewPlatform(server *Server, target forceAccountTarget) (any, error) {
	target, argv, err := forceAccountPreviewDarwin(server, target)
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": "ready", "target": target, "argv": argv}, nil
}
func accountForceCommitPlatform(server *Server, target forceAccountTarget, reviewedArgv []string) (forceAccountResult, error) {
	if err := forceAccountValidateReviewedArgv(target, reviewedArgv); err != nil {
		return forceAccountUnknown, err
	}
	return (&forceAccountAttempt{}).forceAccountStopDarwin(server, target)
}

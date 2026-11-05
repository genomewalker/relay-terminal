package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"sync/atomic"
	"unicode/utf8"
)

// forceAccountTarget names a single observed blocker belonging to an exact
// provider incarnation. It never authorizes signaling the provider itself.
type forceAccountTarget struct {
	Pane          string `json:"pane"`
	Provider      string `json:"provider"`
	Session       string `json:"session"`
	ProviderPID   int    `json:"provider_pid"`
	ProviderStart string `json:"provider_start"`
	BlockerPID    int    `json:"blocker_pid"`
	BlockerStart  string `json:"blocker_start"`
	CommandDigest string `json:"command_digest,omitempty"`
}

// forceAccountObservation is evidence from a trusted host observer. Complete
// means each field was verified, including command fingerprint and
// ancestry, for this observation; it does not assert a complete process tree.
// Present=false is valid only when the observer can establish the exact blocker
// incarnation has exited and the provider binding is still verified.
type forceAccountObservation struct {
	Target                                        forceAccountTarget
	Complete, Present, Descendant, CommandMatches bool
}

type forceAccountResult string

const (
	forceAccountBlocked forceAccountResult = "blocked"
	forceAccountUnknown forceAccountResult = "unknown"
	forceAccountExited  forceAccountResult = "exited"
)

// forceAccountAttempt is single use, including failures and uncertain outcomes.
// A caller must retain this object for the lifetime of its request receipt; a
// new object must not be created to replay an ambiguous request.
type forceAccountAttempt struct{ used atomic.Bool }

// signalSelected signals one explicitly selected blocker. The observer must
// fail closed on unreadable identity, ancestry, or fingerprint and must not
// infer ownership merely from process name. The signal callback must target one
// PID only, never a process group. This helper is not an authorization gate.
//
// Numeric PID signaling retains a race between the final observation and the
// signal: PID reuse or ancestry changes may occur in that interval. A kernel
// identity handle and containment would be needed to eliminate those races.
// There is also no assertion that unobserved or reparented descendants are gone.
func (a *forceAccountAttempt) signalSelected(target forceAccountTarget, observe func() (forceAccountObservation, error), signal func(int) error) (forceAccountResult, error) {
	if a == nil || !a.used.CompareAndSwap(false, true) {
		return forceAccountUnknown, errors.New("force attempt already used")
	}
	if target.Pane == "" || target.Session == "" || (target.Provider != "claude" && target.Provider != "codex") || target.ProviderPID <= 1 || target.ProviderStart == "" || target.BlockerPID <= 1 || target.BlockerPID == target.ProviderPID || target.BlockerStart == "" || target.CommandDigest == "" || observe == nil || signal == nil {
		return forceAccountUnknown, errors.New("exact provider and distinct blocker identities required")
	}
	check := func() (forceAccountObservation, error) {
		observation, err := observe()
		if err != nil {
			return observation, err
		}
		if !observation.Complete || observation.Target != target {
			return observation, errors.New("incomplete or changed process evidence")
		}
		if observation.Present && (!observation.Descendant || !observation.CommandMatches) {
			return observation, errors.New("blocker ownership or command fingerprint unverified")
		}
		return observation, nil
	}
	for i := 0; i < 2; i++ {
		observation, err := check()
		if err != nil {
			return forceAccountUnknown, err
		}
		if !observation.Present {
			return forceAccountExited, nil
		}
	}
	if err := signal(target.BlockerPID); err != nil {
		return forceAccountUnknown, err
	}
	observation, err := check()
	if err != nil {
		return forceAccountUnknown, err
	}
	if observation.Present {
		return forceAccountBlocked, nil
	}
	return forceAccountExited, nil
}

// forceAccountInventoryMember narrows this operation to a process which the
// existing host process_signal inventory can address for this exact pane.
func forceAccountInventoryMember(inventory []hostProcess, target forceAccountTarget, identity func(int) (string, error)) bool {
	if identity == nil {
		return false
	}
	for _, p := range inventory {
		if p.PID != target.BlockerPID || p.PaneID != target.Pane || !p.CanSignal || p.Start == "" {
			continue
		}
		current, err := identity(p.PID)
		if err == nil && current == p.Start {
			return true
		}
	}
	return false
}

// forceAccountCommandDigest binds the reviewed, argument-separated command.
func forceAccountCommandDigest(argv []string) string {
	data, _ := json.Marshal(argv)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
func forceAccountValidateReviewedArgv(target forceAccountTarget, argv []string) error {
	if len(argv) == 0 || len(argv) > 128 {
		return errors.New("bounded reviewed argv required")
	}
	total := 0
	for _, arg := range argv {
		total += len(arg)
		if total > 65536 || !utf8.ValidString(arg) || strings.ContainsRune(arg, 0) {
			return errors.New("invalid reviewed argv")
		}
	}
	if forceAccountCommandDigest(argv) != target.CommandDigest {
		return errors.New("reviewed argv digest does not match")
	}
	return nil
}

// Native binding and incarnation helpers currently create NewServer(), so
// restrict this feature to the exact default state root they will inspect.
func forceAccountDefaultStateRoot(server *Server) bool {
	if server == nil || server.stateDir == "" || !filepath.IsAbs(server.stateDir) {
		return false
	}
	defaultRoot := defaultWorkerStateDir()
	return filepath.IsAbs(defaultRoot) && filepath.Clean(server.stateDir) == filepath.Clean(defaultRoot)
}

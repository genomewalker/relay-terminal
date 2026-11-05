// Package nativemsg is relayd's native provider messaging adapter: it finds
// the exact live Claude or Codex conversation of a pane and delivers one
// collaborator message to its own inbox. It is a line-by-line port of the
// former communication_runtime/pane_messaging.py and the parts of
// agent_conversation.py it used, and keeps their output, their errors and
// every identity fence: process owner and incarnation re-checks, relayd's
// authenticated binding, kernel peer credentials of every socket, and the
// exact expected endpoint before any write. It never starts, resumes or
// retries an agent and never writes terminal input.
package nativemsg

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/user"
	"strconv"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/desktoproute"
)

// Host is what the adapter took from relayd and its own process.
type Host struct {
	// RootPID is the desktop's renderer hint; zero reads the retained worker.
	// It never replaces the ancestry, owner, incarnation or session fences.
	RootPID int64
	// Binding is `relayd agent-binding PANE [--session SESSION]`: the
	// encoded record, or an error where that command exits 1.
	Binding func(pane, session string) ([]byte, error)
	// InboundClass is `relayd peer-inbound-class PID SESSION`.
	InboundClass func(pid int, session string) (class, reason string)
	// NativeProcessStart is relayd's kernel-validated agent incarnation.
	NativeProcessStart func(pane string, pid int64, provider string) (uint64, error)
	// Getenv is os.LookupEnv unless a test supplies its own.
	Getenv func(key string) (string, bool)

	workDeliver func(context.Context, string, string, string, desktoproute.Envelope, func(context.Context) error) desktoproute.Delivery
	proc        processSource
	random      func(int) []byte
	// beforeSocketCheck runs before every socket identity read; tests
	// replace the socket there.
	beforeSocketCheck func(path string)
}

func (h Host) getenv(key string) (string, bool) {
	if h.Getenv == nil {
		return os.LookupEnv(key)
	}
	return h.Getenv(key)
}

var errProcessDiscovery = unbound("Process discovery is unavailable.")

// call runs fn with a timeout, as the adapter ran a relayd subcommand. A
// panic is the subcommand's crash; a timeout is subprocess.TimeoutExpired.
func call[T any](ctx context.Context, timeout time.Duration, fn func() T) (result T, crashed, finished bool) {
	type outcome struct {
		value   T
		crashed bool
	}
	done := make(chan outcome, 1)
	go func() {
		defer func() {
			if recover() != nil {
				done <- outcome{crashed: true}
			}
		}()
		done <- outcome{value: fn()}
	}()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case got := <-done:
		return got.value, got.crashed, !got.crashed
	case <-timer.C:
	case <-ctx.Done():
	}
	return result, false, false
}

type bindingOutput struct {
	data []byte
	err  error
}

func (h Host) binding(ctx context.Context, pane, session string) ([]byte, error) {
	if h.Binding == nil {
		return nil, errors.New("no binding reader")
	}
	// relayd's argument parser for `agent-binding PANE [--session SESSION]`.
	if session == "" && pane == "--native" || session != "" && (pane == "" || strings.HasPrefix(pane, "--")) {
		return nil, errors.New("usage")
	}
	got, crashed, finished := call(ctx, 5*time.Second, func() bindingOutput {
		data, err := h.Binding(pane, session)
		return bindingOutput{data, err}
	})
	switch {
	case crashed:
		return nil, errProcessDiscovery
	case !finished:
		return nil, errors.New("timed out")
	case got.err != nil:
		return nil, got.err
	case len(got.data) > 2<<20:
		return nil, unbound("Process inventory exceeded its limit.")
	}
	return got.data, nil
}

func (h Host) inboundClass(ctx context.Context, pid int, session string) (string, bool) {
	if h.InboundClass == nil {
		return "", false
	}
	got, _, finished := call(ctx, 10*time.Second, func() string {
		class, _ := h.InboundClass(pid, session)
		return class
	})
	return got, finished
}

type runner struct {
	ctx         context.Context
	host        Host
	workDeliver func(context.Context, string, string, string, desktoproute.Envelope, func(context.Context) error) desktoproute.Delivery
	proc        processSource
	uid         int64
	home        string
	cwd         string
	random      func(int) []byte
}

// home is pathlib.Path.home(): $HOME, else the password database.
func (h Host) home(uid int64) string {
	home, ok := h.getenv("HOME")
	if !ok {
		if account, err := user.LookupId(strconv.FormatInt(uid, 10)); err == nil {
			home = account.HomeDir
		}
	}
	home = strings.TrimRight(home, "/")
	if home == "" {
		home = "/"
	}
	return pathNorm(home)
}

// Run performs one messaging operation for pane. request is the encoded
// packet the adapter received; the result is what it printed.
func Run(ctx context.Context, host Host, pane string, request []byte) (result map[string]any) {
	r := &runner{ctx: ctx, host: host, proc: host.proc, random: host.random, uid: int64(os.Getuid())}
	if r.proc == nil {
		r.proc = defaultSource()
	}
	if r.random == nil {
		r.random = urandom
	}
	r.home = host.home(r.uid)
	r.cwd, _ = os.Getwd()
	packet, err := loadsBytes(request)
	if err != nil {
		return map[string]any{"status": "unavailable", "error": err.Error(), "replay_permitted": false}
	}
	defer func() {
		if failure := recover(); failure != nil {
			result = r.failure(packet, &pyErr{class: classInternal, msg: fmt.Sprint("internal error: ", failure)})
		}
	}()
	result, err = r.run(pane, packet)
	if err != nil {
		return r.failure(packet, err)
	}
	return result
}

// failure is the adapter's reply to any exception: a send's outcome is
// unknown, and nothing is ever replayed.
func (r *runner) failure(packet any, err error) map[string]any {
	status := "unavailable"
	if operation, _ := pyGet(packet, "operation", nil); pyEqual(operation, "send") {
		status = "outcome_unknown"
	}
	return map[string]any{"status": status, "error": err.Error(), "replay_permitted": false}
}

func (r *runner) run(pane string, packet any) (map[string]any, error) {
	targetValue, err := pyGet(packet, "targetSessionID", nil)
	if err != nil {
		return nil, err
	}
	target := ""
	if pyTruthy(targetValue) {
		s, ok := targetValue.(string)
		if !ok || !sessionPattern.MatchString(s) {
			return nil, valueError("Invalid target session")
		}
		target = s
	}
	endpoint, err := r.discover(pane, target)
	if err != nil {
		return nil, err
	}
	if required, _ := pyGet(packet, "requireAuthenticatedBinding", nil); pyTruthy(required) || target != "" {
		verified, err := r.authenticated(pane, endpoint["pid"].(int64), endpoint["provider"].(string), target)
		if err != nil {
			return nil, err
		}
		if pyTruthy(verified) {
			session, err := pyIndex(verified, "session_id")
			if err != nil {
				return nil, err
			}
			if !pyEqual(session, endpoint["sessionID"]) {
				return nil, valueError("Native inbox session disagrees with the authenticated binding")
			}
		} else {
			ok, err := r.authenticateNativePeer(endpoint)
			if err != nil {
				return nil, err
			}
			if !ok {
				return nil, valueError("This pane has no kernel-validated native session endpoint")
			}
		}
	}
	operation, err := pyIndex(packet, "operation")
	if err != nil {
		return nil, err
	}
	switch {
	case pyEqual(operation, "discover"):
		return map[string]any{"endpoint": endpoint}, nil
	case pyEqual(operation, "send"):
		expected, err := pyIndex(packet, "expected")
		if err != nil {
			return nil, err
		}
		if !pyEqual(endpoint, expected) {
			// Name the changed fields, never their values. Nothing was written.
			return nil, valueError("Recipient session or socket changed before delivery (no write; changed: " +
				pySlice(strings.Join(changedFields(endpoint, expected), ", "), 200) + ")")
		}
		delivered, err := r.deliver(endpoint, packet)
		if err != nil {
			return nil, err
		}
		delivered["transport"] = endpoint["transport"]
		return delivered, nil
	}
	return nil, valueError("Unknown messaging operation")
}

func changedFields(endpoint map[string]any, expected any) []string {
	other := dictItems(expected)
	keys := map[string]bool{}
	for key := range endpoint {
		keys[key] = true
	}
	for key := range other {
		keys[key] = true
	}
	var changed []string
	for key := range keys {
		if !pyEqual(endpoint[key], other[key]) {
			changed = append(changed, key)
		}
	}
	sortStrings(changed)
	return changed
}

// Output is the line the adapter printed: json.dumps(result, sort_keys=True).
func Output(result map[string]any) []byte {
	return []byte(dumps(result, true) + "\n")
}

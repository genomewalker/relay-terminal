package desktoproute

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type hostJob struct {
	ID        string `json:"job_id"`
	State     string `json:"state"`
	PID       int    `json:"pid"`
	Successor string `json:"successor"`
	ExitCode  *int   `json:"exit_code"`
}
type hostResult struct {
	Job       hostJob `json:"job"`
	State     string  `json:"state"`
	Successor string  `json:"successor"`
	Stdout    string  `json:"stdout"`
	Stderr    string  `json:"stderr"`
	OutOffset int64   `json:"stdout_offset"`
	ErrOffset int64   `json:"stderr_offset"`
	Process   string  `json:"process_state"`
}
type hostAPI interface {
	request(context.Context, string, string, map[string]any) (hostResult, error)
}
type hostTransport struct {
	readHeaders      func(context.Context, string) ([]byte, error)
	host, token, exe string
	client           *http.Client
}
type hostHTTPError struct{ code int }

func (e hostHTTPError) Error() string { return fmt.Sprintf("Relay host request refused (%d)", e.code) }
func (t *hostTransport) request(ctx context.Context, job, operation string, values map[string]any) (hostResult, error) {
	var result hostResult
	if t.token == "" {
		reader := t.readHeaders
		if reader == nil {
			reader = func(commandCtx context.Context, exe string) ([]byte, error) {
				return exec.CommandContext(commandCtx, filepath.Join(filepath.Dir(exe), "relay-mcp"), "--use-relay-token", "--print-http-headers").Output()
			}
		}
		tokenCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		raw, e := reader(tokenCtx, t.exe)
		cancel()
		if e != nil {
			return result, errors.New("Relay token unavailable")
		}
		var header map[string]string
		if decodeJSON(raw, 16384, &header) != nil || !strings.HasPrefix(header["Authorization"], "Bearer ") {
			return result, errors.New("invalid Relay token response")
		}
		t.token = strings.TrimPrefix(header["Authorization"], "Bearer ")
		if len(t.token) < 16 || len(t.token) > 4096 || strings.ContainsAny(t.token, "\r\n") {
			return result, errors.New("invalid Relay token")
		}
	}
	body := map[string]any{"host": t.host, "request_id": "rpc-" + strings.ReplaceAll(uuid(), "-", ""), "operation": operation, "job_id": job}
	for k, v := range values {
		body[k] = v
	}
	raw, e := json.Marshal(body)
	if e != nil {
		return result, e
	}
	req, e := http.NewRequestWithContext(ctx, "POST", "http://127.0.0.1:47471/api/host/request", bytes.NewReader(raw))
	if e != nil {
		return result, e
	}
	req.Header.Set("X-Relay-Token", t.token)
	req.Header.Set("Content-Type", "application/json")
	response, e := t.client.Do(req)
	if e != nil {
		return result, errors.New("Relay host transport unavailable")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		if response.StatusCode == 401 || response.StatusCode == 403 {
			t.token = ""
		}
		return result, hostHTTPError{response.StatusCode}
	}
	raw, e = readBounded(response.Body, 1<<20)
	if e != nil {
		return result, e
	}
	var envelope struct {
		Result json.RawMessage `json:"result"`
		Error  json.RawMessage `json:"error"`
	}
	if e = decodeJSON(raw, 1<<20, &envelope); e != nil {
		return result, e
	}
	if len(envelope.Error) > 0 && string(envelope.Error) != "null" && string(envelope.Error) != "\"\"" {
		return result, errors.New("Relay host operation refused")
	}
	e = decodeJSON(envelope.Result, 1<<20, &result)
	return result, e
}
func terminal(state string) bool {
	return state == "exited" || state == "failed" || state == "unknown_after_daemon_restart"
}
func validJob(id string) bool { return strings.HasPrefix(id, "job-") && identifier.MatchString(id) }
func streamData(result hostResult, outOffset, errOffset int64) ([]byte, []byte, error) {
	out, e := base64.StdEncoding.Strict().DecodeString(result.Stdout)
	if e != nil {
		return nil, nil, e
	}
	errs, e := base64.StdEncoding.Strict().DecodeString(result.Stderr)
	if e != nil {
		return nil, nil, e
	}
	if result.OutOffset != outOffset+int64(len(out)) || result.ErrOffset != errOffset+int64(len(errs)) {
		return nil, nil, errors.New("host output offset mismatch")
	}
	return out, errs, nil
}
func sendHost(ctx context.Context, t hostAPI, argv []string, input []byte) ([]byte, error) {
	job := "job-" + strings.ReplaceAll(uuid(), "-", "")
	started, e := t.request(ctx, job, "exec", map[string]any{"argv": argv, "stdin": base64.StdEncoding.EncodeToString(input)})
	if e != nil {
		return nil, e
	}
	if started.State != "running" && started.State != "exited" {
		return nil, errors.New("send execution outcome unresolved")
	}
	var output []byte
	var outOffset, errOffset int64
	for {
		result, e := t.request(ctx, job, "status", map[string]any{"stdout_offset": outOffset, "stderr_offset": errOffset, "wait_millis": 15000})
		if e != nil {
			return output, e
		}
		data, errs, e := streamData(result, outOffset, errOffset)
		if e != nil {
			return output, e
		}
		if len(output)+len(data) > 1<<20 {
			return output, errors.New("host output exceeds limit")
		}
		output = append(output, data...)
		outOffset, errOffset = result.OutOffset, result.ErrOffset
		if terminal(result.Job.State) && len(data) == 0 && len(errs) == 0 {
			if result.Job.State != "exited" || result.Job.ExitCode == nil || *result.Job.ExitCode != 0 {
				return output, errors.New("host command did not exit successfully")
			}
			return output, nil
		}
	}
}

type checkpointState struct {
	Job     string `json:"job_id"`
	Purpose string `json:"purpose"`
	Pending bool   `json:"launch_pending,omitempty"`
	Out     int64  `json:"stdout_offset"`
	Err     int64  `json:"stderr_offset"`
}
type listenerCheckpoint struct {
	path    string
	lock    *os.File
	state   checkpointState
	present bool
}

func openCheckpoint(root, host string, argv []string) (*listenerCheckpoint, error) {
	if e := privateDirectory(root, true); e != nil {
		return nil, e
	}
	identity, _ := json.Marshal([]any{host, argv})
	key := hash(identity)
	lock, e := fileLock(filepath.Join(root, key+".lock"), true)
	if e != nil {
		return nil, e
	}
	c := &listenerCheckpoint{path: filepath.Join(root, key+".json"), lock: lock, state: checkpointState{Job: "job-" + strings.ReplaceAll(uuid(), "-", "")}}
	if exists(c.path) {
		if e = readJSONFile(c.path, 16384, &c.state); e != nil {
			lock.Close()
			return nil, e
		}
		c.present = true
	}
	if !validJob(c.state.Job) || c.state.Out < 0 || c.state.Err < 0 {
		lock.Close()
		return nil, errors.New("invalid saved listener checkpoint")
	}
	return c, nil
}
func (c *listenerCheckpoint) save() error {
	e := atomicJSON(c.path, c.state)
	if e == nil {
		c.present = true
	}
	return e
}
func (c *listenerCheckpoint) rotate(next string) error {
	if next == "" {
		next = "job-" + strings.ReplaceAll(uuid(), "-", "")
	}
	if !validJob(next) || next == c.state.Job {
		return errors.New("invalid listener successor")
	}
	prior := c.path + ".previous-" + c.state.Job
	if exists(prior) {
		return errors.New("listener history already exists")
	}
	if e := os.Rename(c.path, prior); e != nil {
		return e
	}
	c.state = checkpointState{Job: next, Purpose: "peer_listener"}
	return c.save()
}
func unreadHost(ctx context.Context, t hostAPI, c *listenerCheckpoint) (bool, error) {
	result, e := t.request(ctx, c.state.Job, "status", map[string]any{"stdout_offset": c.state.Out, "stderr_offset": c.state.Err})
	if e != nil {
		return false, e
	}
	out, _, e := streamData(result, c.state.Out, c.state.Err)
	return bytes.Contains(out, []byte{'\n'}), e
}
func readyHost(ctx context.Context, t hostAPI, c *listenerCheckpoint, handle func([]byte) error) error {
	result, e := t.request(ctx, c.state.Job, "status", map[string]any{"stdout_offset": 0, "stderr_offset": c.state.Err})
	if e != nil {
		return e
	}
	if result.Job.State != "running" {
		return errors.New("listener not running")
	}
	data, _, e := streamData(result, 0, c.state.Err)
	if e != nil {
		return e
	}
	line, _, ok := bytes.Cut(data, []byte{'\n'})
	if !ok && len(line) == 0 {
		return nil
	}
	var ready Mailbox
	if decodeJSON(line, 131072, &ready) != nil || ready.Type != "ready" || ready.PID != result.Job.PID {
		return errors.New("saved listener mailbox changed")
	}
	return handle(line)
}
func waitContext(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// oldRemoteListenRefusal is the exact diagnostic a relayd from before the
// recorded-account listen argument exits with when given that argument: its
// desktop-remote accepts only five or seven arguments, so a six-argument
// listen fails its first count check.
const oldRemoteListenRefusal = "relayd: desktop-remote requires exact mode and process identity"

var errAccountArgumentRefused = errors.New("remote relayd refused the recorded account argument")

// errOwnerAbsent is a listener's final report that the owner is gone. The
// event is consumed, so the next attempt launches a new listener that searches
// again instead of rereading this stale report from the exited one.
var errOwnerAbsent = errors.New("remote session absent; waiting for same session")

func listenHost(ctx context.Context, t hostAPI, c *listenerCheckpoint, spec map[string]any, handle func([]byte) error) error {
	if spec == nil {
		return errors.New("unrecognized native listener arguments")
	}
	resumed, drained, adopted := false, false, false
	if c.present && !c.state.Pending {
		result, e := t.request(ctx, c.state.Job, "status", nil)
		if e != nil {
			return e
		}
		job := result.Job
		switch {
		case job.State == "exited" || job.State == "failed":
			unread, e := unreadHost(ctx, t, c)
			if e != nil {
				return e
			}
			if unread {
				drained = true
			} else {
				if e = c.rotate(job.Successor); e != nil {
					return e
				}
				adopted = job.Successor != ""
			}
		case job.State == "running":
			resumed = true
		case job.State == "unknown_after_daemon_restart" && (result.Process == "absent" || result.Process == "replaced") && c.state.Purpose == "peer_listener":
			unread, e := unreadHost(ctx, t, c)
			if e != nil {
				return e
			}
			if unread {
				drained = true
			} else if e = c.rotate(""); e != nil {
				return e
			}
		default:
			return errors.New("saved listener outcome unresolved; explicit recovery required")
		}
	}
	c.state.Purpose = "peer_listener"
	if !resumed && !drained && !adopted {
		// Stable job reservation permits only the same typed listener to be admitted
		// after an uncertain HTTP response. Outgoing sends never use this path.
		c.state.Pending = true
		if e := c.save(); e != nil {
			return e
		}
		result, e := t.request(ctx, c.state.Job, "exec", map[string]any{"keep_stdin": true, "kind": "peer_listener_v1", "listener": spec})
		if e != nil {
			return e
		}
		c.state.Pending = false
		if e = c.save(); e != nil {
			return e
		}
		if result.State == "failed" && result.Successor != "" {
			if e = c.rotate(result.Successor); e != nil {
				return e
			}
		} else if result.State != "running" {
			return errors.New("listener launch did not establish running state")
		}
	} else {
		if e := c.save(); e != nil {
			return e
		}
		if resumed {
			if e := readyHost(ctx, t, c, handle); e != nil {
				return e
			}
		}
	}
	offset, errorOffset := c.state.Out, c.state.Err
	var pending, diagnostics []byte
	failures := 0
	for {
		result, e := t.request(ctx, c.state.Job, "status", map[string]any{"stdout_offset": offset, "stderr_offset": errorOffset, "wait_millis": 15000})
		if e != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			failures++
			category, message := "transport_unavailable", "Relay host channel unavailable; listener preserved"
			var he hostHTTPError
			if errors.As(e, &he) && (he.code == 401 || he.code == 403) {
				category, message = "permission_required", "Waiting for Relay permission"
			}
			b, _ := json.Marshal(map[string]string{"type": "transport_status", "state": category, "message": message})
			if e = handle(b); e != nil {
				return e
			}
			delay := time.Duration(1<<min(failures, 4)) * time.Second
			if e = waitContext(ctx, min(delay, 15*time.Second)); e != nil {
				return e
			}
			continue
		}
		if failures > 0 && result.Job.State == "running" {
			if e = readyHost(ctx, t, c, handle); e != nil {
				return e
			}
		}
		failures = 0
		output, errs, e := streamData(result, offset, errorOffset)
		if e != nil {
			return e
		}
		offset, errorOffset = result.OutOffset, result.ErrOffset
		diagnostics = append(diagnostics, errs...)
		if len(diagnostics) > 4096 {
			diagnostics = diagnostics[len(diagnostics)-4096:]
		}
		pending = append(pending, output...)
		for {
			line, rest, ok := bytes.Cut(pending, []byte{'\n'})
			if !ok {
				break
			}
			if len(line) > 131072 {
				return errors.New("listener event exceeds limit")
			}
			if e = handle(line); e != nil {
				if errors.Is(e, errOwnerAbsent) {
					c.state.Out = offset - int64(len(rest))
					c.state.Err = errorOffset
					if se := c.save(); se != nil {
						return se
					}
				}
				return e
			}
			pending = rest
			c.state.Out = offset - int64(len(pending))
			c.state.Err = errorOffset
			if e = c.save(); e != nil {
				return e
			}
		}
		if len(pending) > 131072 {
			return errors.New("unterminated listener event")
		}
		if terminal(result.Job.State) && len(output) == 0 && len(errs) == 0 {
			if len(pending) > 0 {
				return errors.New("listener ended with incomplete event")
			}
			if result.Job.Successor != "" {
				if e = c.rotate(result.Job.Successor); e != nil {
					return e
				}
				offset, errorOffset = 0, 0
				continue
			}
			if bytes.Contains(diagnostics, []byte(oldRemoteListenRefusal)) {
				return errAccountArgumentRefused
			}
			return errors.New("listener ended")
		}
	}
}

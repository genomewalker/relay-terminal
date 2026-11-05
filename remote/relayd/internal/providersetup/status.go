package providersetup

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const StatusInputLimit = 65536

// Runtime makes the process boundary explicit; tests use private fake commands,
// never the real quota CLI (which may access host credentials).
type Runtime struct {
	Home string
	Env  []string
	Run  func(context.Context, string, []string, []byte, io.Writer, io.Writer) (int, error)
}

func (r Runtime) run(ctx context.Context, program string, args []string, raw []byte, out, errout io.Writer) (int, error) {
	if r.Run != nil {
		return r.Run(ctx, program, args, raw, out, errout)
	}
	cmd := exec.CommandContext(ctx, program, args...)
	cmd.WaitDelay = time.Second
	cmd.Env = r.Env
	cmd.Stdin = bytes.NewReader(raw)
	cmd.Stdout = out
	cmd.Stderr = errout
	e := cmd.Run()
	if e == nil {
		return 0, nil
	}
	var exit *exec.ExitError
	if errors.As(e, &exit) {
		if st, ok := exit.Sys().(syscall.WaitStatus); ok && st.Signaled() {
			return -int(st.Signal()), nil
		}
		return exit.ExitCode(), nil
	}
	return 1, e
}
func (r Runtime) Statusline(ctx context.Context, in io.Reader, out, errout io.Writer) (int, error) {
	raw, e := io.ReadAll(io.LimitReader(in, StatusInputLimit+1))
	if e != nil {
		return 1, e
	}
	if len(raw) > StatusInputLimit {
		return 1, errors.New("Claude status input exceeds bound")
	}
	pane := ""
	env := r.Env
	if env == nil {
		env = os.Environ()
	}
	for _, v := range env {
		if strings.HasPrefix(v, "RELAY_SESSION=") {
			pane = strings.TrimPrefix(v, "RELAY_SESSION=")
		}
	}
	// Capture is best effort and shares the original four-second budget. The
	// quota helper runs a no-op, so capture failure/absence cannot suppress the
	// user's renderer or leave a renderer descendant owned by the quota process.
	capture, cancelCapture := context.WithTimeout(ctx, 4*time.Second)
	if pane != "" {
		_, _ = r.run(capture, filepath.Join(r.Home, ".local/bin/relayd"), []string{"claude-status-capture", "--pane", pane}, raw, io.Discard, io.Discard)
	}
	_, _ = r.run(capture, filepath.Join(r.Home, ".local/bin/relayd"), []string{"subscription-quota-statusline", base64.StdEncoding.EncodeToString([]byte(":"))}, raw, io.Discard, io.Discard)
	cancelCapture()
	render, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	code, e := r.run(render, "bash", []string{filepath.Join(r.Home, ".config/relay/cc-status.sh")}, raw, out, errout)
	if render.Err() != nil || e != nil {
		return 1, errors.New("Claude status renderer unavailable")
	}
	return code, nil
}

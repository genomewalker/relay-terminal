package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

type projectInvocation struct {
	Argv           []string          `json:"argv"`
	Environment    map[string]string `json:"environment"`
	TimeoutSeconds int               `json:"timeout_seconds"`
}

func parseProjectInvocation(raw string) (projectInvocation, error) {
	var value projectInvocation
	if len(raw) > 8192 {
		return value, errors.New("command review exceeds 8 KiB")
	}
	d := json.NewDecoder(strings.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(&value); err != nil {
		return value, err
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return value, errors.New("expected one command object")
	}
	if len(value.Argv) == 0 || len(value.Argv) > 64 || !filepath.IsAbs(value.Argv[0]) || value.TimeoutSeconds < 1 || value.TimeoutSeconds > 60 || len(value.Environment) > 32 {
		return value, errors.New("review an absolute executable, at most 64 arguments, 32 environment variables and a 1–60 second timeout")
	}
	for _, arg := range value.Argv {
		if strings.ContainsRune(arg, 0) {
			return value, errors.New("argument contains NUL")
		}
	}
	key := regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	for k, v := range value.Environment {
		if !key.MatchString(k) || strings.ContainsRune(v, 0) {
			return value, errors.New("invalid environment")
		}
	}
	return value, nil
}

// No shell parsing and no inherited credentials or startup files. An explicitly
// reviewed executable may run arbitrary project code; this is not a sandbox.
func pluginProjectCommand(root, _ string, input string, _ ...string) (string, error) {
	v, err := parseProjectInvocation(input)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(v.TimeoutSeconds)*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, v.Argv[0], v.Argv[1:]...)
	cmd.Dir = root
	env := map[string]string{"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "LC_ALL": "C"}
	for k, value := range v.Environment {
		env[k] = value
	}
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		cmd.Env = append(cmd.Env, k+"="+env[k])
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	var out pluginBuffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err = cmd.Run()
	if err != nil {
		return out.String(), fmt.Errorf("command failed or timed out: %w", err)
	}
	return out.String(), nil
}

package agentaccounts

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// probeLimit bounds one provider status command; usageLimit one usage
// session. A provider that does not answer in time is ended with its whole
// process group, and its account is reported as unavailable with a reason.
const (
	probeLimit = 12 * time.Second
	usageLimit = 25 * time.Second
	// waitLimit bounds waiting for output pipes after the process ended.
	waitLimit = time.Second
	// usageExitLimit bounds a usage session's own exit after its answer, and
	// a SIGTERM before SIGKILL, so the CLI can remove its session records.
	usageExitLimit = 3 * time.Second
)

// printable keeps up to limit bytes of a value's printable characters.
func printable(value string, limit int) string {
	var builder strings.Builder
	for _, r := range value {
		if r == utf8.RuneError || !unicode.IsPrint(r) {
			continue
		}
		if builder.Len()+utf8.RuneLen(r) > limit {
			break
		}
		builder.WriteRune(r)
	}
	return strings.TrimSpace(builder.String())
}

// credentialPattern matches text shaped like credential material: JWTs,
// bearer values and sk- keys. longRun finds base64 runs, which count when
// they mix upper case, lower case and digits (a folder name does not).
var (
	credentialPattern = regexp.MustCompile(`(?i)(eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}|bearer\s+\S|\bsk-[A-Za-z0-9_-]{8,})`)
	longRun           = regexp.MustCompile(`[A-Za-z0-9+/_=-]{40,}`)
)

// withheld is a reason as it may be shown. Reasons are fixed texts; this is
// a backstop for any text that still looks like credential material.
func withheld(reason string) string {
	reason = printable(reason, 160)
	suspect := credentialPattern.MatchString(reason)
	for _, run := range longRun.FindAllString(reason, -1) {
		suspect = suspect || (strings.ContainsAny(run, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") &&
			strings.ContainsAny(run, "abcdefghijklmnopqrstuvwxyz") && strings.ContainsAny(run, "0123456789"))
	}
	if suspect {
		return "the reason was withheld because it may contain credential material"
	}
	return reason
}

// timeoutError names how long the provider was given. It does no file
// system work: a provider that hung may have hung on a slow file system.
func timeoutError(name string, started time.Time) error {
	seconds := int(time.Since(started).Round(time.Second) / time.Second)
	message := fmt.Sprintf("%s did not answer in %d s", name, seconds)
	if name == "codex" {
		message += "; a large tmp/arg0 folder in the account folder slows every Codex start"
	}
	return errors.New(message)
}

// failure is the reason a provider command ended without an answer. It is a
// fixed text: what a provider writes is never forwarded, since it can contain
// credential material.
func failure(ctx context.Context, name string, started time.Time, err error) error {
	var exit *exec.ExitError
	switch {
	case ctx.Err() != nil:
		return timeoutError(name, started)
	case errors.Is(err, exec.ErrWaitDelay):
		return fmt.Errorf("%s exited but left a process holding its output open", name)
	case errors.As(err, &exit) && exit.ExitCode() >= 0:
		return fmt.Errorf("%s exited with status %d", name, exit.ExitCode())
	case errors.As(err, &exit):
		return fmt.Errorf("%s was ended by a signal", name)
	case err != nil:
		return fmt.Errorf("%s could not be run", name)
	}
	return fmt.Errorf("%s gave no answer", name)
}

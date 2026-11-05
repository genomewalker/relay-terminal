package daemon

import (
	"context"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

var phAccountDirectoryPattern = regexp.MustCompile(`^(~/|/)[A-Za-z0-9._/-]{1,240}$`)

func phAccountDirectory(value, provider string) string {
	if value == "" {
		return ""
	}
	if !phAccountDirectoryPattern.MatchString(value) || strings.Contains(value, "//") || strings.HasSuffix(value, "/") {
		phRaise(phValueError, "The account directory is invalid.")
	}
	for _, part := range strings.Split(value, "/") {
		if part == ".." {
			phRaise(phValueError, "The account directory is invalid.")
		}
	}
	path := value
	if strings.HasPrefix(path, "~/") {
		path = phJoin(phHome(), path[2:])
	}
	if filepath.Clean(path) != path {
		phRaise(phValueError, "The account directory is invalid.")
	}
	if phSameAccount(provider, path, "") {
		return ""
	}
	return path
}

func (r *phReader) accountMoveCommand(provider, session, path, base, account, target, binary string) string {
	override := phAccountDirectory(target, provider)
	if phSameAccount(provider, override, account) {
		phRaise(phValueError, "The agent already uses that account.")
	}
	if base == "" {
		phRaise(phValueError, "The exact agent resume command is unavailable.")
	}
	seen := ""
	phCatch(func() {
		root := phMaintenanceAccountRoot(provider, override)
		if provider == "codex" {
			seen = r.exactCodexTranscript(session, root)
		} else {
			seen = r.exactClaudeTranscript(session, root)
		}
	}, phOSError, phValueError)
	if seen == "" || phResolve(seen, false) != phResolve(path, false) {
		phRaise(phValueError, "This conversation is not visible from the target account. Turn on shared conversation history for that account in Settings and sync it, then move again.")
	}
	var checked any
	phCatchAll(func() {
		selector := override
		if selector == "" {
			selector = "-"
		}
		checked = phLoads(r.run([]string{binary, "account-transcript-check", provider, selector, seen}, 5))
	})
	if !pyEqual(checked, pyObj("bindable", true)) {
		phRaise(phValueError, "The target account could not bind this conversation after the move. Sync that account's shared conversation history in Settings, then move again.")
	}
	return phAccountCommand(base, provider, override)
}

func nativeReaderFailure(field string, fn func() *pyObject) (value *pyObject) {
	defer func() {
		if recovered := recover(); recovered != nil {
			message := "Native reader could not complete."
			if exception := phExceptionOf(recovered); exception != nil {
				message = exception.msg
			}
			runes := []rune(message)
			if len(runes) > 240 {
				message = string(runes[:240])
			}
			value = pyObj("version", int64(1), field, message)
		}
	}()
	return fn()
}

func nativeReaderOutput(out io.Writer, value *pyObject, maximum int) error {
	data := pyEncode(value, pyEncodeOptions{itemSep: ",", keySep: ":"})
	if len(data)+1 > maximum {
		return errors.New("native reader output exceeds limit")
	}
	_, err := out.Write(append(data, '\n'))
	return err
}

// RunAgentMaintenance reads the same inspection, worker and context facts the
// desktop previously obtained from its bundled scripts. It has no input path.
func RunAgentMaintenance(ctx context.Context, args []string, out io.Writer) error {
	flags := flag.NewFlagSet("agent-maintenance", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	pane := flags.String("pane", "", "")
	expect := flags.String("expect-account", "", "")
	target := flags.String("target-account", "", "")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || !phSafeID.MatchString(*pane) {
		return errors.New("invalid maintenance selector")
	}
	var expected, targeted *string
	flags.Visit(func(f *flag.Flag) {
		if f.Name == "expect-account" {
			expected = expect
		}
		if f.Name == "target-account" {
			targeted = target
		}
	})
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	reader := newPHReader(ctx)
	value := nativeReaderFailure("unavailable", func() *pyObject { return reader.inspectAccounts(*pane, binary, expected, targeted) })
	value.Set("worker", reader.workerObservation(*pane, binary))
	value.Set("context", reader.contextObservation(*pane, binary))
	return nativeReaderOutput(out, value, 32<<10)
}

// RunPaneMessaging is the desktop adapter entry point. The caller's root hint
// is still checked against its exact process ancestry, incarnation, session and
// socket identities by nativemsg before any possible provider socket write.
func RunPaneMessaging(ctx context.Context, args []string, out io.Writer) error {
	flags := flag.NewFlagSet("pane-messaging", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	pane := flags.String("pane", "", "")
	root := flags.Int64("root-pid", 0, "")
	encoded := flags.String("request", "", "")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || !phSafeID.MatchString(*pane) || *root < 0 || len(*encoded) > 128<<10 {
		return errors.New("invalid messaging selector")
	}
	data, err := base64.StdEncoding.Strict().DecodeString(*encoded)
	if err != nil || len(data) > 64<<10 {
		return errors.New("invalid messaging request")
	}
	host := communicationNativeHost()
	host.RootPID = *root
	ctx, cancel := context.WithTimeout(ctx, communicationAdapterTimeout)
	defer cancel()
	result := nativemsg.Output(nativemsg.Run(ctx, host, *pane, data))
	if len(result) > 64<<10 {
		return fmt.Errorf("native messaging output exceeds limit")
	}
	_, err = out.Write(result)
	return err
}

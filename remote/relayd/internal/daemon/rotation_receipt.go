package daemon

// `relayd rotation-receipt` is the only command a rotated Claude session may
// run before its first turn: it fetches the fenced capsule from the chitta
// ledger, prints it and prints the receipt line. The rotation executor finds
// that exact output in the new session's transcript, re-parses the printed
// capsule and recomputes its digest, so the canonical digest and the receipt
// line reproduce the former claude_backend.py receipt byte for byte.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// errRotationReceiptRefused is a printed refusal: exit 1, nothing on stderr.
var errRotationReceiptRefused = errors.New("rotation receipt refused")

// IsRotationReceiptRefused reports a refusal that was already printed.
func IsRotationReceiptRefused(err error) bool { return errors.Is(err, errRotationReceiptRefused) }

// rotationReceiptLedgerCLI is the chitta CLI that serves the ledger.
var rotationReceiptLedgerCLI = func() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".claude", "bin", "chitta"), nil
}

const rotationReceiptLedgerLimit = 16 << 20

type rotationReceiptOutput struct{ bytes.Buffer }

func (b *rotationReceiptOutput) Write(p []byte) (int, error) {
	if len(p) > rotationReceiptLedgerLimit-b.Len() {
		return 0, errors.New("ledger reply exceeds limit")
	}
	return b.Buffer.Write(p)
}

// rotationReceiptLedger is one ledger_op tools/call over the chitta CLI's
// stdio: the structured value, or the tool's own error text.
func rotationReceiptLedger(ctx context.Context, op string, args *pyObject) (any, error) {
	cli, err := rotationReceiptLedgerCLI()
	if err != nil {
		return nil, err
	}
	payload := pyObj("v", int64(1))
	for _, key := range args.keys {
		payload.Set(key, args.values[key])
	}
	request := pyObj("jsonrpc", "2.0", "id", int64(1), "method", "tools/call",
		"params", pyObj("name", "ledger_op", "arguments", pyObj("op", op, "args", payload)))
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, cli)
	command.Stdin = bytes.NewReader(append(pyEncode(request, pyDumpsDefault), '\n'))
	var output rotationReceiptOutput
	command.Stdout = &output
	command.Stderr = io.Discard
	command.WaitDelay = time.Second
	// As subprocess.run without check: only the reply decides.
	if err := command.Run(); err != nil && ctx.Err() != nil {
		return nil, errors.New("ledger timed out")
	} else if err != nil && output.Len() == 0 {
		return nil, fmt.Errorf("ledger unavailable: %w", err)
	}
	reply, err := pyDecode(output.Bytes())
	if err != nil {
		return nil, fmt.Errorf("ledger reply is not JSON: %w", err)
	}
	return rotationReceiptLedgerValue(reply)
}

func rotationReceiptLedgerValue(reply any) (value any, err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			typed, ok := recovered.(pyTypeError)
			if !ok {
				panic(recovered)
			}
			value, err = nil, fmt.Errorf("ledger reply has an unexpected shape: %s", typed)
		}
	}()
	result := pyIndex(reply, "result")
	if pyTruthy(pyMustObject(result).Get("isError")) {
		first := pyMustList(pyIndex(result, "content"))
		if len(first.items) == 0 {
			panic(pyTypeError("empty error content"))
		}
		return nil, errors.New(pyStr(pyIndex(first.items[0], "text")))
	}
	return pyIndex(pyIndex(result, "structured"), "value"), nil
}

// rotationCapsuleDigest is sha256 of json.dumps(capsule, sort_keys=True,
// separators=(",", ":"), ensure_ascii=False).
func rotationCapsuleDigest(capsule any) string {
	sum := sha256.Sum256(pyEncode(capsule, pyDumpsCompact))
	return hex.EncodeToString(sum[:])
}

// pyIndentedSorted is json.dumps(value, indent=2, sort_keys=True,
// ensure_ascii=False).
func pyIndentedSorted(buffer *bytes.Buffer, v any, depth int) {
	newline := func(level int) {
		buffer.WriteByte('\n')
		buffer.WriteString(strings.Repeat("  ", level))
	}
	switch t := v.(type) {
	case *pyList:
		if len(t.items) == 0 {
			buffer.WriteString("[]")
			return
		}
		buffer.WriteByte('[')
		for i, item := range t.items {
			if i > 0 {
				buffer.WriteByte(',')
			}
			newline(depth + 1)
			pyIndentedSorted(buffer, item, depth+1)
		}
		newline(depth)
		buffer.WriteByte(']')
	case *pyObject:
		if t.Len() == 0 {
			buffer.WriteString("{}")
			return
		}
		keys := append([]string(nil), t.keys...)
		sort.Strings(keys)
		buffer.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				buffer.WriteByte(',')
			}
			newline(depth + 1)
			pyEncodeString(buffer, key, false)
			buffer.WriteString(": ")
			pyIndentedSorted(buffer, t.values[key], depth+1)
		}
		newline(depth)
		buffer.WriteByte('}')
	default:
		pyEncodeValue(buffer, v, pyDumpsCompact)
	}
}

// RotationReceipt runs `relayd rotation-receipt --old S --intent I --new N
// --revision R --project-dir D` in the new session: the fenced capsule of
// the old session, then the receipt line binding intent, new session,
// revision and capsule digest. A ledger status other than ok or another
// revision prints a refusal line instead.
func RotationReceipt(ctx context.Context, arguments []string, stdout io.Writer) error {
	flags := flag.NewFlagSet("rotation-receipt", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	old := flags.String("old", "", "old Claude session")
	intent := flags.String("intent", "", "rotation intent")
	fresh := flags.String("new", "", "new Claude session")
	revision := flags.String("revision", "", "fenced capsule revision")
	project := flags.String("project-dir", "", "project directory")
	if err := flags.Parse(arguments); err != nil || flags.NArg() != 0 {
		return errors.New("invalid rotation receipt request")
	}
	seen := 0
	flags.Visit(func(*flag.Flag) { seen++ })
	if seen != 5 {
		return errors.New("rotation receipt requires --old, --intent, --new, --revision and --project-dir")
	}
	reply, err := rotationReceiptLedger(ctx, "capsule_get", pyObj("project_dir", *project, "session_id", *old))
	if err != nil {
		return err
	}
	replyObject, ok := reply.(*pyObject)
	if !ok {
		return errors.New("ledger reply is not an object")
	}
	capsule := replyObject.Get("capsule")
	if !pyTruthy(capsule) {
		capsule = newPyObject()
	}
	capsuleObject, ok := capsule.(*pyObject)
	if !ok {
		return errors.New("ledger capsule is not an object")
	}
	status := replyObject.Get("status")
	if status != "ok" || pyStr(capsuleObject.Get("revision")) != *revision {
		_, err := fmt.Fprintf(stdout, "RELAY-RECEIPT-REFUSED status=%s revision=%s\n",
			pyStr(status), pyStr(capsuleObject.Get("revision")))
		if err != nil {
			return err
		}
		return errRotationReceiptRefused
	}
	revisionValue, ok := capsuleObject.Lookup("revision")
	if !ok {
		return errors.New("ledger capsule has no revision")
	}
	var output bytes.Buffer
	pyIndentedSorted(&output, capsuleObject, 0)
	fmt.Fprintf(&output, "\nRELAY-RECEIPT intent=%s session=%s revision=%s sha256=%s\n",
		*intent, *fresh, pyStr(revisionValue), rotationCapsuleDigest(capsuleObject))
	_, err = stdout.Write(output.Bytes())
	return err
}

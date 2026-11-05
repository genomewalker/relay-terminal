// Package pluginverify checks a staged helper against a disposable fixture.
package pluginverify

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

const responseLimit = 24 << 20
const chunkLimit = 4 << 20
const requestTimeout = 15 * time.Second

type Options struct{ Helper, Fixture, SSH string }
type Summary struct {
	Target string `json:"target"`
	Checks int    `json:"checks"`
	Result string `json:"result"`
}
type transfer struct {
	Mode    string `json:"mode"`
	Version string `json:"version"`
	Offset  int64  `json:"offset"`
}
type request struct {
	Operation string    `json:"operation"`
	Root      string    `json:"root"`
	Path      string    `json:"path"`
	Transfer  *transfer `json:"transfer,omitempty"`
}
type transferInfo struct {
	Size    *int64 `json:"size"`
	Version string `json:"version"`
	SHA256  string `json:"sha256"`
}
type response struct {
	Entries  []string      `json:"entries"`
	Text     string        `json:"text"`
	Content  *string       `json:"content"`
	SHA256   string        `json:"sha256"`
	Transfer *transferInfo `json:"transfer"`
}

func ParseArgs(args []string) (Options, error) {
	var o Options
	var positional []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--ssh":
			if o.SSH != "" || i+1 == len(args) {
				return o, errors.New("--ssh requires one host")
			}
			i++
			o.SSH = args[i]
			if o.SSH == "" || strings.HasPrefix(o.SSH, "-") || strings.ContainsAny(o.SSH, "\r\n\x00") {
				return o, errors.New("invalid SSH host")
			}
		default:
			if strings.HasPrefix(args[i], "-") {
				return o, fmt.Errorf("unknown argument %s", args[i])
			}
			positional = append(positional, args[i])
		}
	}
	if len(positional) != 2 {
		return o, errors.New("usage: relay-verify-plugin HELPER FIXTURE [--ssh HOST]")
	}
	o.Helper, o.Fixture = positional[0], positional[1]
	for _, p := range []string{o.Helper, o.Fixture} {
		if !strings.HasPrefix(p, "/tmp/") || !strings.HasPrefix(filepath.Clean(p), "/tmp/") || strings.ContainsRune(p, 0) {
			return o, errors.New("use explicit disposable /tmp paths only")
		}
	}
	return o, nil
}
func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }
func command(o Options) []string {
	if o.SSH != "" {
		return []string{"ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", o.SSH, quote(o.Helper) + " plugin"}
	}
	return []string{o.Helper, "plugin"}
}

type cappedBuffer struct {
	bytes.Buffer
	limit int
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	if len(p) > b.limit-b.Len() {
		return 0, errors.New("helper response exceeds limit")
	}
	return b.Buffer.Write(p)
}
func decode(data []byte) (response, error) {
	var r response
	if len(data) > responseLimit || !utf8.Valid(data) {
		return r, errors.New("invalid or oversized JSON response")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	if err := d.Decode(&r); err != nil {
		return r, err
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return r, errors.New("trailing JSON response")
	}
	if bytes.Equal(bytes.TrimSpace(data), []byte("null")) {
		return r, errors.New("null response")
	}
	return r, nil
}
func call(ctx context.Context, o Options, q request) (response, error) {
	ctx, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()
	argv := command(o)
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.WaitDelay = time.Second
	data, err := json.Marshal(q)
	if err != nil {
		return response{}, err
	}
	cmd.Stdin = bytes.NewReader(data)
	out := &cappedBuffer{limit: responseLimit}
	stderr := &cappedBuffer{limit: 64 << 10}
	cmd.Stdout = out
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return response{}, ctx.Err()
		}
		return response{}, err
	}
	return decode(out.Bytes())
}
func content(r response) ([]byte, error) {
	if r.Content == nil {
		return nil, errors.New("missing base64 content")
	}
	for _, c := range *r.Content {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '/' || c == '=') {
			return nil, errors.New("invalid base64 content")
		}
	}
	return base64.StdEncoding.DecodeString(*r.Content)
}
func digest(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func contains(items []string, want string) bool {
	for _, s := range items {
		if s == want {
			return true
		}
	}
	return false
}
func check(ok bool, name string) error {
	if !ok {
		return errors.New(name)
	}
	return nil
}

func Run(ctx context.Context, o Options) (Summary, error) {
	// Validate programmatic callers using the same rules as the CLI.
	args := []string{o.Helper, o.Fixture}
	if o.SSH != "" {
		args = append(args, "--ssh", o.SSH)
	}
	if _, err := ParseArgs(args); err != nil {
		return Summary{}, err
	}
	req := func(op, path string, t *transfer) (response, error) {
		return call(ctx, o, request{op, o.Fixture, path, t})
	}
	listing, err := req("artifacts", "", nil)
	if err != nil {
		return Summary{}, err
	}
	if err = check(contains(listing.Entries, "table.csv") && contains(listing.Entries, "empty.txt"), "artifact listing"); err != nil {
		return Summary{}, err
	}
	for _, pair := range [][2]string{{"artifacts", "table.csv"}, {"transfers", "empty.txt"}} {
		r, e := req(pair[0], pair[1], nil)
		if e != nil {
			return Summary{}, e
		}
		data, e := content(r)
		if e != nil {
			return Summary{}, e
		}
		if e = check(digest(data) == r.SHA256, "full-file SHA256"); e != nil {
			return Summary{}, e
		}
		if e = check(r.Text == pair[1], "file path identity"); e != nil {
			return Summary{}, e
		}
		if pair[1] == "empty.txt" {
			if e = check(len(data) == 0, "empty-file content"); e != nil {
				return Summary{}, e
			}
		}
	}
	projects, err := req("projectActions", "", nil)
	if err != nil {
		return Summary{}, err
	}
	pnpm := false
	for _, s := range projects.Entries {
		pnpm = pnpm || strings.Contains(s, "Detected pnpm lockfile")
	}
	if err = check(pnpm, "pnpm detection"); err != nil {
		return Summary{}, err
	}
	review, err := req("gitReview", "", nil)
	if err != nil {
		return Summary{}, err
	}
	if err = check(strings.Contains(review.Text, "Worktree and Git directory:") && contains(review.Entries, "table.csv"), "Git attribution"); err != nil {
		return Summary{}, err
	}
	diff, err := req("gitReview", "table.csv", nil)
	if err != nil {
		return Summary{}, err
	}
	if err = check(strings.Contains(diff.Text, "Staged changes:") && strings.Contains(diff.Text, "table.csv"), "staged diff"); err != nil {
		return Summary{}, err
	}
	for _, path := range []string{"../outside", "/etc/passwd"} {
		_, e := req("transfers", path, nil)
		var exit *exec.ExitError
		if !errors.As(e, &exit) {
			return Summary{}, fmt.Errorf("outside path must be rejected by helper: %s", path)
		}
	}
	for _, path := range []string{"table.csv", "empty.txt"} {
		metadata, e := req("transfers", path, &transfer{Mode: "stat"})
		if e != nil {
			return Summary{}, e
		}
		if metadata.Transfer == nil || metadata.Transfer.Size == nil || *metadata.Transfer.Size < 0 || *metadata.Transfer.Size > 64<<30 || metadata.Transfer.Version == "" {
			return Summary{}, errors.New("invalid transfer metadata")
		}
		offset := int64(0)
		hash := sha256.New()
		for offset < *metadata.Transfer.Size {
			chunk, e := req("transfers", path, &transfer{Mode: "chunk", Version: metadata.Transfer.Version, Offset: offset})
			if e != nil {
				return Summary{}, e
			}
			data, e := content(chunk)
			if e != nil {
				return Summary{}, e
			}
			if e = check(len(data) > 0 && len(data) <= chunkLimit, "chunk size"); e != nil {
				return Summary{}, e
			}
			if e = check(digest(data) == chunk.SHA256, "chunk SHA256"); e != nil {
				return Summary{}, e
			}
			if int64(len(data)) > *metadata.Transfer.Size-offset {
				return Summary{}, errors.New("chunk exceeds declared size")
			}
			hash.Write(data)
			offset += int64(len(data))
		}
		final, e := req("transfers", path, &transfer{Mode: "verify", Version: metadata.Transfer.Version, Offset: offset})
		if e != nil {
			return Summary{}, e
		}
		if e = check(final.Transfer != nil && hex.EncodeToString(hash.Sum(nil)) == final.Transfer.SHA256, "final transfer SHA256"); e != nil {
			return Summary{}, e
		}
	}
	target := o.SSH
	if target == "" {
		target = "local"
	}
	return Summary{target, 10, "passed"}, nil
}

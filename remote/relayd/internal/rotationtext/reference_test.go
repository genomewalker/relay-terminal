package rotationtext

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// This immutable corpus was captured from the canonical backend. Each generated
// input must still match. Hash preimages and fake CLI invocations retain the
// original byte comparisons while rebasing only private temporary directories.
const referenceSHA256 = "85f3e586c933984473b4ba781d2341f94bfee2acf8a7d09cfb480205eb9ca33a"
const referenceLimit = 32 << 20

type referenceEvent struct {
	Kind        string            `json:"kind"`
	Data        string            `json:"data,omitempty"`
	Digest      string            `json:"digest"`
	Argv        []string          `json:"argv,omitempty"`
	Input       string            `json:"input,omitempty"`
	Environment map[string]string `json:"environment,omitempty"`
}
type referenceRecord struct {
	Key         string           `json:"key"`
	Input       string           `json:"input"`
	Output      string           `json:"output"`
	Events      []referenceEvent `json:"events,omitempty"`
	LinuxOutput string           `json:"linux_output,omitempty"`
	LinuxEvents []referenceEvent `json:"linux_events,omitempty"`
}

func decodeReference(data []byte) (referenceRecord, error) {
	var v referenceRecord
	if len(data) == 0 || len(data) > referenceLimit {
		return v, errors.New("reference bounds")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(&v); err != nil {
		return v, err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return v, errors.New("reference trailing data")
	}
	if v.Key == "" || v.Input == "" || v.Output == "" {
		return v, errors.New("incomplete reference")
	}
	for _, e := range append(append([]referenceEvent{}, v.Events...), v.LinuxEvents...) {
		if e.Kind != "hash" && e.Kind != "cli" {
			return v, errors.New("unknown reference event")
		}
		b, err := hex.DecodeString(e.Digest)
		if err != nil || len(b) != sha256.Size {
			return v, errors.New("reference digest")
		}
		if e.Kind == "cli" && len(e.Argv) == 0 {
			return v, errors.New("missing fake invocation")
		}
	}
	if len(v.LinuxEvents) == 0 {
		v.LinuxEvents = nil
	}
	for i := range v.LinuxEvents {
		if len(v.LinuxEvents[i].Argv) == 0 {
			v.LinuxEvents[i].Argv = nil
		}
		if len(v.LinuxEvents[i].Environment) == 0 {
			v.LinuxEvents[i].Environment = nil
		}
	}
	if len(v.Events) == 0 {
		v.Events = nil
	}
	for i := range v.Events {
		if len(v.Events[i].Argv) == 0 {
			v.Events[i].Argv = nil
		}
		if len(v.Events[i].Environment) == 0 {
			v.Events[i].Environment = nil
		}
	}
	return v, nil
}

var referenceOnce sync.Once
var referenceRows map[string]referenceRecord
var referenceError error

func loadReferences() {
	b, e := os.ReadFile("testdata/backend-reference.jsonl.gz")
	if e != nil {
		referenceError = e
		return
	}
	sum := sha256.Sum256(b)
	if hex.EncodeToString(sum[:]) != referenceSHA256 {
		referenceError = errors.New("canonical reference corpus changed")
		return
	}
	r, e := gzip.NewReader(bytes.NewReader(b))
	if e != nil {
		referenceError = e
		return
	}
	defer r.Close()
	s := bufio.NewScanner(io.LimitReader(r, 512<<20))
	s.Buffer(make([]byte, 4096), referenceLimit)
	referenceRows = map[string]referenceRecord{}
	for s.Scan() {
		v, e := decodeReference(s.Bytes())
		if e != nil {
			referenceError = e
			return
		}
		if _, ok := referenceRows[v.Key]; ok {
			referenceError = errors.New("duplicate reference key")
			return
		}
		referenceRows[v.Key] = v
	}
	if e = s.Err(); e != nil {
		referenceError = e
		return
	}
	if len(referenceRows) != 18991 {
		referenceError = fmt.Errorf("reference count %d", len(referenceRows))
	}
}
func referenceReplace(value string, roots map[string]string) string {
	keys := make([]string, 0, len(roots))
	for k := range roots {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return len(keys[i]) > len(keys[j]) })
	for _, k := range keys {
		value = strings.ReplaceAll(value, k, roots[k])
	}
	return value
}
func caseRoots(c oracleCase) map[string]string {
	m := map[string]string{}
	if v := c.Env["TMPDIR"]; v != "" {
		m[filepath.Dir(v)] = "@FIXTURE@"
	}
	if c.Fixture != "" {
		m[c.Fixture] = "@LEDGER@"
	}
	return m
}

var referenceDigestPattern = regexp.MustCompile(`[0-9a-f]{64}`)

func referenceLookup(t *testing.T, key, input string, roots map[string]string, overrides map[string]string, unset []string, rebase map[string]string, sourceKey ...string) []byte {
	t.Helper()
	referenceOnce.Do(loadReferences)
	if referenceError != nil {
		t.Fatal(referenceError)
	}
	lookupKey := t.Name() + "/" + key
	if len(sourceKey) == 1 {
		lookupKey = sourceKey[0]
	}
	row, ok := referenceRows[lookupKey]
	if !ok {
		t.Fatalf("canonical case missing: %s/%s", t.Name(), key)
	}
	var selectErr error
	row, selectErr = platformReference(row, runtime.GOOS, strings.HasPrefix(lookupKey, "TestDifferentialBackends/") || strings.HasPrefix(lookupKey, "TestDifferentialJournal/") || strings.HasPrefix(lookupKey, "TestDifferentialLedgerContinuation/"))
	if selectErr != nil {
		t.Fatal(selectErr)
	}
	if actual := referenceReplace(input, roots); actual != row.Input {
		t.Fatalf("canonical input changed for %s: got %s want %s", key, clip(actual, 500), clip(row.Input, 500))
	}
	expand := map[string]string{"@UTC_DAY@": time.Now().UTC().Format("2006-01-02"), "@UTC_MONTH@": time.Now().UTC().Format("2006-01")}
	for from, to := range roots {
		expand[to] = from
	}
	output := referenceReplace(row.Output, expand)
	if rebase == nil {
		rebase = map[string]string{}
	}
	apply := func(s string) string { return referenceReplace(referenceReplace(s, expand), rebase) }
	for _, event := range row.Events {
		var value string
		switch event.Kind {
		case "hash":
			sum := sha256.Sum256([]byte(apply(event.Data)))
			value = hex.EncodeToString(sum[:])
		case "cli":
			fixture := expand["@FIXTURE@"]
			if fixture == "" {
				t.Fatal("reference CLI has no private fixture")
			}
			binary := apply(event.Argv[0])
			relative, e := filepath.Rel(fixture, binary)
			if e != nil || strings.HasPrefix(relative, "..") || strings.Contains(relative, string(filepath.Separator)) || !strings.HasPrefix(relative, "cli-") {
				t.Fatalf("reference invocation escaped fake fixture: %s", binary)
			}
			dir, e := os.MkdirTemp(overrides["TMPDIR"], "relay-capsule-text-")
			if e != nil {
				t.Fatal(e)
			}
			func() {
				defer os.RemoveAll(dir)
				ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
				defer cancel()
				expand["@EXEC@"] = dir
				defer delete(expand, "@EXEC@")
				argv := make([]string, len(event.Argv))
				for i, arg := range event.Argv {
					argv[i] = apply(arg)
				}
				env := map[string]string{}
				for k, v := range event.Environment {
					env[k] = apply(v)
				}
				// These inherited values were intentionally not fixed by the original
				// cases. Keep their current values; case overrides and omissions win.
				for _, k := range []string{"HOME", "PATH", "USER", "LOGNAME", "LANG", "LC_ALL", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "SSL_CERT_FILE", "SSL_CERT_DIR"} {
					if _, set := overrides[k]; set {
						continue
					}
					if strings.Contains(event.Environment[k], "@FIXTURE@") {
						continue
					}
					if (k == "CODEX_HOME" && strings.Contains(event.Environment["CLAUDE_CONFIG_DIR"], "@FIXTURE@")) || (k == "CLAUDE_CONFIG_DIR" && strings.Contains(event.Environment["CODEX_HOME"], "@FIXTURE@")) {
						delete(env, k)
						continue
					}
					removed := false
					for _, u := range unset {
						if k == u {
							removed = true
						}
					}
					if removed {
						delete(env, k)
						continue
					}
					if v, present := os.LookupEnv(k); present {
						env[k] = v
					} else {
						delete(env, k)
					}
				}
				cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
				cmd.Dir = dir
				for k, v := range env {
					cmd.Env = append(cmd.Env, k+"="+v)
				}
				cmd.Stdin = strings.NewReader(apply(event.Input))
				raw, e := cmd.Output()
				if e != nil {
					t.Fatalf("canonical fake CLI: %v", e)
				}
				value, e = canonicalCLIDigest(raw)
				if e != nil {
					t.Fatalf("canonical fake CLI fingerprint: %v", e)
				}
			}()
		}
		rebase[event.Digest] = value
	}
	return []byte(referenceReplace(output, rebase))
}
func runOracle(t *testing.T, cases []oracleCase) []any {
	t.Helper()
	if t.Name() == "TestLedgerRealCopyDifferential" {
		out := make([]any, len(cases))
		for i, c := range cases {
			c.nativeSQLite = true
			out[i] = finite(runGo(t, c))
		}
		return out
	}
	out := make([]any, len(cases))
	for i, c := range cases {
		b, e := json.Marshal(c)
		if e != nil {
			t.Fatal(e)
		}
		out[i] = parseJSON(referenceLookup(t, fmt.Sprint(i), string(b), caseRoots(c), c.Env, c.Unset, nil))
	}
	return out
}
func FuzzCanonicalReferenceRecord(f *testing.F) {
	for _, seed := range []string{`{"key":"test/0","input":"{}","output":"{}"}`, `{"key":"a","input":"x","output":"y","events":[{"kind":"hash","data":"x","digest":"2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"}]}`, `{`, `{"key":"x","input":"x","output":"x"} false`} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		v, e := decodeReference(raw)
		if e != nil {
			return
		}
		b, e := json.Marshal(v)
		if e != nil {
			t.Fatal(e)
		}
		again, e := decodeReference(b)
		if e != nil || !reflect.DeepEqual(v, again) {
			t.Fatal("canonical reference value/ID roundtrip changed")
		}
		if _, e := decodeReference(b[:len(b)-1]); e == nil {
			t.Fatal("truncated reference accepted")
		}
	})
}
func TestCanonicalReferenceIntegrity(t *testing.T) {
	referenceOnce.Do(loadReferences)
	if referenceError != nil {
		t.Fatal(referenceError)
	}
	if len(referenceRows) != 18991 {
		t.Fatal("reference cases lost")
	}
}

func TestCanonicalReferenceRecordRejections(t *testing.T) {
	for _, raw := range []string{`{`, `null`, `[]`, `{"key":"x","input":"x"}`, `{"key":"x","input":"x","output":"x","unknown":1}`, `{"key":"x","input":"x","output":"x"} false`, `{"key":"x","input":"x","output":"x","events":[{"kind":"command","digest":"2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"}]}`, `{"key":"x","input":"x","output":"x","events":[{"kind":"hash","digest":"broken"}]}`, `{"key":"x","input":"x","output":"x","events":[{"kind":"cli","digest":"2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"}]}`} {
		if _, err := decodeReference([]byte(raw)); err == nil {
			t.Fatalf("invalid reference accepted: %s", raw)
		}
	}
}

// Linux credential-store observations were separately captured from canonical
// source with an injected platform branch. Actual Linux execution is still a
// release gate; Darwin results must never substitute for these cases.
func platformReference(row referenceRecord, platform string, requireLinux bool) (referenceRecord, error) {
	if platform == "linux" {
		if row.LinuxOutput != "" {
			row.Output = row.LinuxOutput
			row.Events = row.LinuxEvents
		} else if requireLinux {
			return row, errors.New("missing canonical Linux credential-store branch")
		}
	}
	return row, nil
}
func TestCanonicalPlatformSelection(t *testing.T) {
	row := referenceRecord{Key: "x", Input: "x", Output: "darwin", LinuxOutput: "linux", Events: []referenceEvent{{Kind: "hash", Data: "darwin"}}, LinuxEvents: []referenceEvent{{Kind: "hash", Data: "linux"}}}
	for _, platform := range []string{"darwin", "linux"} {
		got, err := platformReference(row, platform, true)
		if err != nil || got.Output != platform || got.Events[0].Data != platform {
			t.Fatal("canonical platform branch changed")
		}
	}
	row.LinuxOutput = ""
	if _, err := platformReference(row, "linux", true); err == nil {
		t.Fatal("Darwin credential oracle substituted for Linux")
	}
	if _, err := platformReference(row, "linux", false); err != nil {
		t.Fatal("platform-independent corpus refused")
	}
}

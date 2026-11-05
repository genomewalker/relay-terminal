//go:build linux || darwin

package nativemsg

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
)

//go:embed testdata/differential-reference.json
var referenceJSON []byte

type referenceCase struct {
	Platform     string   `json:"platform"`
	Test         string   `json:"test"`
	Call         int      `json:"call"`
	Packet       string   `json:"packet"`
	Output       string   `json:"output"`
	Records      []string `json:"records"`
	SourceSHA256 string   `json:"source_sha256"`
}

var referenceOnce sync.Once
var referenceCases map[string][]referenceCase
var referenceError error

func loadReferences() error {
	referenceOnce.Do(func() {
		var corpus struct {
			Version int             `json:"version"`
			Cases   []referenceCase `json:"cases"`
		}
		if referenceError = json.Unmarshal(referenceJSON, &corpus); referenceError != nil {
			return
		}
		if corpus.Version != 1 || len(corpus.Cases) == 0 {
			referenceError = fmt.Errorf("invalid reference corpus")
			return
		}
		referenceCases = map[string][]referenceCase{}
		for _, row := range corpus.Cases {
			if row.Platform != runtime.GOOS {
				continue
			}
			if row.Call != len(referenceCases[row.Test])+1 || len(row.SourceSHA256) != 64 {
				referenceError = fmt.Errorf("invalid reference identity %s call %d", row.Test, row.Call)
				return
			}
			referenceCases[row.Test] = append(referenceCases[row.Test], row)
		}
	})
	return referenceError
}

var referenceToken = regexp.MustCompile(`@@REF:([^@]+)@@`)

// expandReference replaces only explicit fixture tokens. All other bytes,
// including spacing, key order, error text, frames and connection count, stay
// exactly as emitted by the independently captured canonical adapter.
func expandReference(template string, value func(kind, key string) (string, error)) (string, error) {
	var first error
	expanded := referenceToken.ReplaceAllStringFunc(template, func(token string) string {
		pair := strings.SplitN(strings.TrimSuffix(strings.TrimPrefix(token, "@@REF:"), "@@"), ":", 2)
		if len(pair) != 2 {
			first = fmt.Errorf("invalid reference token")
			return token
		}
		replacement, err := value(pair[0], pair[1])
		if err != nil {
			first = err
			return token
		}
		return replacement
	})
	if first != nil {
		return "", first
	}
	if strings.Contains(expanded, "@@REF:") {
		return "", fmt.Errorf("unexpanded reference token")
	}
	return expanded, nil
}

func (f *fixture) referenceValue(kind, key string) (string, error) {
	quoted := func(value any) (string, error) { b, e := json.Marshal(value); return string(b), e }
	pid := func(name string) (int, bool) {
		switch name {
		case "shell":
			return f.shell, true
		case "worker":
			return f.worker, true
		}
		p, ok := f.pids[name]
		return p, ok
	}
	switch kind {
	case "root":
		if key != "" {
			break
		}
		b, _ := json.Marshal(f.dir)
		return string(b[1 : len(b)-1]), nil
	case "pid":
		p, ok := pid(key)
		if !ok || p <= 1 {
			break
		}
		return strconv.Itoa(p), nil
	case "identity":
		if _, ok := pid(key); !ok {
			break
		}
		s, ok := f.starts[key]
		if !ok {
			break
		}
		return quoted(runtime.GOOS + ":" + s)
	case "procstart":
		if _, ok := f.pids[key]; !ok {
			break
		}
		// The captured native_peer field is a JSON string, including numeric Linux ticks.
		return quoted(f.starts[key])
	case "stat":
		if filepath.IsAbs(key) || key == ".." || strings.HasPrefix(key, "../") || filepath.Clean(key) != key {
			break
		}
		info, err := os.Lstat(f.path(key))
		if err != nil {
			return "", err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("reference stat is a symlink")
		}
		return quoted(devIno(statT(info)))
	}
	return "", fmt.Errorf("unknown or unsafe reference %q %q", kind, key)
}

func (f *fixture) reference(t *testing.T, packet []byte) ([]byte, []string) {
	t.Helper()
	if err := loadReferences(); err != nil {
		t.Fatal(err)
	}
	rows := referenceCases[t.Name()]
	if f.referenceCall >= len(rows) {
		t.Fatalf("missing independent reference %s call %d", t.Name(), f.referenceCall+1)
	}
	row := rows[f.referenceCall]
	f.referenceCall++
	expand := func(s string) string {
		v, e := expandReference(s, f.referenceValue)
		if e != nil {
			t.Fatal(e)
		}
		return v
	}
	expectedPacket := expand(row.Packet)
	if string(packet) != expectedPacket {
		t.Fatalf("reference input differs\nwant: %s\ngot: %s", expectedPacket, packet)
	}
	records := make([]string, len(row.Records))
	for i, s := range row.Records {
		records[i] = expand(s)
	}
	return []byte(expand(row.Output)), records
}

func (f *fixture) checkReferenceCount(t *testing.T) {
	t.Helper()
	if err := loadReferences(); err != nil {
		t.Fatal(err)
	}
	if rows := referenceCases[t.Name()]; len(rows) > 0 {
		t.Cleanup(func() {
			if f.referenceCall != len(rows) {
				t.Errorf("independent reference coverage: consumed %d of %d calls", f.referenceCall, len(rows))
			}
		})
	}
}

func (f *fixture) checkedReference(t *testing.T, packet []byte, want string) []byte {
	t.Helper()
	oracle, oracleRecords := f.reference(t, packet)
	f.clearRecords()
	port := f.runPort(t, packet)
	portRecords := f.settledRecords()
	if !bytes.Equal(oracle, port) {
		t.Fatalf("results differ\ncanonical: %s\ngo:        %s", oracle, port)
	}
	if !strings.Contains(string(port), want) {
		t.Fatalf("result lacks %q: %s", want, port)
	}
	if len(oracleRecords) != len(portRecords) {
		t.Fatalf("deliveries differ: canonical %d connections %q, go %d %q", len(oracleRecords), oracleRecords, len(portRecords), portRecords)
	}
	for i := range oracleRecords {
		if normalizeRecord(oracleRecords[i]) != normalizeRecord(portRecords[i]) {
			t.Fatalf("delivery %d differs\ncanonical: %q\ngo:        %q", i, oracleRecords[i], portRecords[i])
		}
	}
	return oracle
}

func TestReferenceExpansionPreservesAllUnrelatedBytes(t *testing.T) {
	in := "{ \"pid\" : @@REF:pid:claude@@,\"status\":\"held\" }\n"
	got, err := expandReference(in, func(kind, key string) (string, error) {
		if kind != "pid" || key != "claude" {
			return "", fmt.Errorf("unexpected")
		}
		return "12345", nil
	})
	if err != nil || got != "{ \"pid\" : 12345,\"status\":\"held\" }\n" {
		t.Fatalf("literal bytes changed: %q %v", got, err)
	}
	parent := t.TempDir()
	root := filepath.Join(parent, "root")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(parent, "outside"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	f := &fixture{dir: root, pids: map[string]int{}, starts: map[string]string{}}
	if _, err := expandReference("@@REF:stat:../outside@@", f.referenceValue); err == nil {
		t.Fatal("reference escaped fixture root")
	}

	for _, token := range []string{"@@REF:stat:../escape@@", "@@REF:stat:/absolute@@", "@@REF:unknown:field@@", "@@REF:pid:missing@@", "@@REF:broken@@", "@@REF:unterminated"} {
		if _, err := expandReference(token, f.referenceValue); err == nil {
			t.Fatalf("unsafe or unknown token admitted: %s", token)
		}
	}
}

func FuzzReferenceExpansion(f *testing.F) {
	for _, seed := range []string{"literal bytes\n", "@@REF:pid:agent@@", "@@REF:broken@@", "@@REF:stat:../x@@"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, input string) {
		if len(input) > 65536 {
			return
		}
		got, err := expandReference(input, func(kind, key string) (string, error) {
			if kind == "pid" && key == "agent" {
				return "123", nil
			}
			return "", fmt.Errorf("unknown token")
		})
		if err == nil {
			if len(got) > len(input) {
				t.Fatal("expansion exceeded input bound")
			}
			if !strings.Contains(input, "@@REF:") && got != input {
				t.Fatal("literal bytes changed")
			}
			if strings.Contains(got, "@@REF:") {
				t.Fatal("unexpanded token accepted")
			}
		}
	})
}

func TestReferenceCorpusInventory(t *testing.T) {
	var corpus struct {
		Cases []referenceCase `json:"cases"`
	}
	if err := json.Unmarshal(referenceJSON, &corpus); err != nil {
		t.Fatal(err)
	}
	want := map[string]int{"TestDifferentialClaudeDiscovery": 33, "TestDifferentialCodexDiscovery": 17, "TestDifferentialFences": 14, "TestDifferentialGroupWritable": 12, "TestDifferentialParkedClaude": 7, "TestDifferentialSend": 59}
	counts := map[string]map[string]int{}
	seen := map[string]bool{}
	for _, row := range corpus.Cases {
		key := fmt.Sprintf("%s/%s/%d", row.Platform, row.Test, row.Call)
		if seen[key] || row.Call < 1 || !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(row.SourceSHA256) {
			t.Fatalf("invalid independent reference identity %s", key)
		}
		seen[key] = true
		if row.Platform != "darwin" && row.Platform != "linux" {
			t.Fatalf("unknown corpus platform %s", row.Platform)
		}
		if counts[row.Platform] == nil {
			counts[row.Platform] = map[string]int{}
		}
		group := strings.SplitN(row.Test, "/", 2)[0]
		counts[row.Platform][group]++
	}
	for _, platform := range []string{"darwin", "linux"} {
		if len(counts[platform]) != len(want) {
			t.Fatalf("missing reference groups for %s: %v", platform, counts[platform])
		}
		for group, n := range want {
			if platform == "linux" && group == "TestDifferentialClaudeDiscovery" {
				n += 2
			}
			if counts[platform][group] != n {
				t.Fatalf("reference call count %s/%s: got %d want %d", platform, group, counts[platform][group], n)
			}
		}
	}
}

func TestReferenceProcStartPreservesCapturedStringType(t *testing.T) {
	f := &fixture{pids: map[string]int{"job": 123}, starts: map[string]string{"job": "1114078439"}}
	got, err := f.referenceValue("procstart", "job")
	if err != nil || got != `"1114078439"` {
		t.Fatalf("captured Linux scalar type changed: %q %v", got, err)
	}
	f.starts["job"] = "Sun Oct 25 10:20:30 2026"
	got, err = f.referenceValue("procstart", "job")
	if err != nil || got != `"Sun Oct 25 10:20:30 2026"` {
		t.Fatalf("captured Darwin scalar type changed: %q %v", got, err)
	}
}

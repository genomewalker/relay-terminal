package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func build(t *testing.T) string {
	t.Helper()
	binary := filepath.Join(t.TempDir(), "relay-evidence-reader")
	if out, err := exec.Command(filepath.Join(runtime.GOROOT(), "bin", "go"), "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, out)
	}
	return binary
}

func hash(b []byte) string { sum := sha256.Sum256(b); return hex.EncodeToString(sum[:]) }

func TestBinaryServesAndRefuses(t *testing.T) {
	binary := build(t)
	root := filepath.Join(t.TempDir(), "evidence")
	_ = os.MkdirAll(root, 0o700)
	content := []byte("Kap K\n")
	_ = os.WriteFile(filepath.Join(root, "a.txt"), content, 0o600)
	contract := strings.Repeat("c", 64)
	raw, _ := json.Marshal(map[string]any{"version": 1, "contract_sha256": contract, "root": root,
		"evidence": []map[string]string{{"id": "A", "path": "a.txt", "sha256": hash(content)}}})
	allowlist := filepath.Join(filepath.Dir(root), "allowlist.json")
	_ = os.WriteFile(allowlist, raw, 0o600)

	command := exec.Command(binary, "--allowlist", allowlist, "--allowlist-sha256", hash(raw), "--contract-sha256", contract)
	command.Stdin = strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}` + "\n" +
		`{"jsonrpc":"2.0","method":"notifications/initialized"}` + "\n" +
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}` + "\n" +
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read","arguments":{"id":"A"}}}` + "\n")
	out, err := command.Output()
	if err != nil {
		t.Fatal(err)
	}
	var lines []map[string]any
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		var line map[string]any
		if json.Unmarshal(scanner.Bytes(), &line) != nil {
			t.Fatalf("bad line %q", scanner.Text())
		}
		lines = append(lines, line)
	}
	if len(lines) != 3 || len(lines[1]["result"].(map[string]any)["tools"].([]any)) != 3 || !strings.Contains(string(out), `Kap K\\n`) {
		t.Fatalf("session output %s", out)
	}

	for name, args := range map[string][]string{
		"wrong contract": {"--allowlist", allowlist, "--allowlist-sha256", hash(raw), "--contract-sha256", strings.Repeat("d", 64)},
		"tampered list":  {"--allowlist", allowlist, "--allowlist-sha256", strings.Repeat("e", 64), "--contract-sha256", contract},
		"missing flags":  {"--allowlist", allowlist},
		"extra argument": {"--allowlist", allowlist, "--allowlist-sha256", hash(raw), "--contract-sha256", contract, "/etc/passwd"},
	} {
		command := exec.Command(binary, args...)
		command.Stdin = strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}` + "\n")
		out, err := command.Output()
		if err == nil || len(out) != 0 {
			t.Fatalf("%s: served %q (err %v)", name, out, err)
		}
	}
}

package researchworker

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
)

func TestPlanBindsTheEvidenceReaderToTheWorkerContract(t *testing.T) {
	allowlistSHA := strings.Repeat("a", 64)
	for _, provider := range []string{ProviderClaude, ProviderCodex} {
		p := basePolicy(provider)
		p.Reader = EvidenceReaderFor("/opt/relay/bin/relay-evidence-reader", "/private/var/relay/allowlist.json", allowlistSHA, testContract)
		launch, err := Plan(p, testWorkerDir)
		if err != nil {
			t.Fatalf("%s: %v", provider, err)
		}
		if !slices.Equal(launch.AllowedTools, []string{"mcp__evidence__list", "mcp__evidence__read", "mcp__evidence__search"}) {
			t.Fatalf("%s allowed %q", provider, launch.AllowedTools)
		}
		p.Reader = EvidenceReaderFor("/opt/relay/bin/relay-evidence-reader", "/private/var/relay/allowlist.json", allowlistSHA, strings.Repeat("b", 64))
		if _, err := Plan(p, testWorkerDir); err == nil || !strings.Contains(err.Error(), "different contract") {
			t.Fatalf("%s: reader for another contract accepted: %v", provider, err)
		}
		p.Reader.Args = p.Reader.Args[:len(p.Reader.Args)-1]
		if _, err := Plan(p, testWorkerDir); err == nil {
			t.Fatalf("%s: reader with a dangling --contract-sha256 accepted", provider)
		}
	}
}

// buildEvidenceReader compiles cmd/relay-evidence-reader into a temp dir.
func buildEvidenceReader(t *testing.T) string {
	t.Helper()
	binary := filepath.Join(t.TempDir(), "relay-evidence-reader")
	command := exec.Command(filepath.Join(runtime.GOROOT(), "bin", "go"), "build", "-o", binary, "github.com/relay-terminal/relayd/cmd/relay-evidence-reader")
	if out, err := command.CombinedOutput(); err != nil {
		t.Fatalf("build reader: %v %s", err, out)
	}
	return binary
}

func evidenceAllowlist(t *testing.T) (string, string) {
	t.Helper()
	root := filepath.Join(t.TempDir(), "evidence")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	content := []byte("Kap K permafrost\n")
	if err := os.WriteFile(filepath.Join(root, "s1.txt"), content, 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(content)
	raw, _ := json.Marshal(map[string]any{"version": 1, "contract_sha256": testContract, "root": root,
		"evidence": []map[string]string{{"id": "S001", "path": "s1.txt", "sha256": hex.EncodeToString(sum[:])}}})
	path := filepath.Join(filepath.Dir(root), "allowlist.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	listSum := sha256.Sum256(raw)
	return path, hex.EncodeToString(listSum[:])
}

// The worker's required reader is the real relay-evidence-reader. Codex starts
// it for a matching allowlist and refuses to start the session for a tampered
// one. Offline: empty CODEX_HOME, no credentials, prompt-input only.
func TestCodexStartsOnlyAMatchingEvidenceReader(t *testing.T) {
	codex := codexBinary(t)
	reader := buildEvidenceReader(t)
	allowlist, allowlistSHA := evidenceAllowlist(t)
	p := basePolicy(ProviderCodex)
	p.Reader = EvidenceReaderFor(reader, allowlist, allowlistSHA, testContract)
	launch, err := Plan(p, testWorkerDir)
	if err != nil {
		t.Fatal(err)
	}
	run := func(arguments []string) (string, error) {
		command := exec.Command(codex, append(append([]string{"debug", "prompt-input"}, arguments...), "probe")...)
		command.Dir = t.TempDir()
		command.Env = offlineEnv(t.TempDir())
		out, err := command.CombinedOutput()
		return string(out), err
	}
	if out, err := run(probeArguments(launch.Argv)); err != nil {
		t.Fatalf("Codex did not start with the matching reader: %v %.400s", err, out)
	}
	tampered := strings.Repeat("0", 64)
	p.Reader = EvidenceReaderFor(reader, allowlist, tampered, testContract)
	launch, err = Plan(p, testWorkerDir)
	if err != nil {
		t.Fatal(err)
	}
	out, err := run(probeArguments(launch.Argv))
	if err == nil || !strings.Contains(out, "required MCP servers failed to initialize") {
		t.Fatalf("Codex started with a reader whose allowlist hash does not match: %v %.400s", err, out)
	}
}

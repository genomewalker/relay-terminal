package agentaccounts

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Case 10 (7b68ee70, 2026-11-18): the business CODEX_HOME trusts only the
// parent project; Codex 0.170.0 launched in a non-git subfolder showed its
// folder-trust dialog. Fixture paths are temp-dir copies of that layout.
func codexTrustFixture(t *testing.T) (home, parent, sub string) {
	t.Helper()
	root := t.TempDir()
	home = filepath.Join(root, ".codex-business")
	parent = filepath.Join(root, "Documents", "Claude", "Projects", "Patent")
	sub = filepath.Join(parent, "drafts", "claims")
	for _, dir := range []string{home, sub} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	config := "model = \"gpt-rosalind-astra\"\n\n[projects." + tomlQuote(parent) + "]\ntrust_level = \"trusted\"\n"
	if err := os.WriteFile(filepath.Join(home, "config.toml"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	return home, parent, sub
}

func TestCodexTrustNonGitSubfolderOfTrustedParentNeedsTrust(t *testing.T) {
	home, parent, sub := codexTrustFixture(t)
	if got := CodexProjectTrust(home, sub); got.Status != CodexTrustParentOnly || got.Parent != parent || got.Dir != sub {
		t.Fatalf("subfolder: %+v", got)
	}
	if got := CodexProjectTrust(home, parent); got.Status != CodexTrustTrusted {
		t.Fatalf("parent: %+v", got)
	}
	// Inside a git repository whose root is trusted, the subfolder is trusted.
	if err := os.Mkdir(filepath.Join(parent, ".git"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got := CodexProjectTrust(home, sub); got.Status != CodexTrustTrusted {
		t.Fatalf("repository subfolder: %+v", got)
	}
	// A repository below the trusted parent, with its own root untrusted, is
	// not claimed as parent-only.
	if err := os.Mkdir(filepath.Join(sub, ".git"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got := CodexProjectTrust(home, sub); got.Status != CodexTrustUntrusted {
		t.Fatalf("nested repository: %+v", got)
	}
}

func TestCodexTrustOtherStates(t *testing.T) {
	home, _, sub := codexTrustFixture(t)
	if got := CodexProjectTrust(home, "/elsewhere"); got.Status != CodexTrustUntrusted {
		t.Fatalf("unrelated: %+v", got)
	}
	untrusted := filepath.Join(home, "config.toml")
	if err := os.WriteFile(untrusted, []byte("[projects."+tomlQuote(sub)+"]\ntrust_level = \"untrusted\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := CodexProjectTrust(home, sub); got.Status != CodexTrustUntrusted {
		t.Fatalf("explicitly untrusted: %+v", got)
	}
	if err := os.WriteFile(untrusted, []byte("x = '''\nmulti\n'''\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := CodexProjectTrust(home, sub); got.Status != CodexTrustUnknown {
		t.Fatalf("unreadable: %+v", got)
	}
	if got := CodexProjectTrust("relative", sub); got.Status != CodexTrustUnknown {
		t.Fatalf("relative home: %+v", got)
	}
}

// The opt-in writer adds only the exact entry, mirroring the parent, and
// keeps the rest of the file byte for byte; it refuses anything else.
func TestCodexTrustWriterMirrorsTheParentOnly(t *testing.T) {
	home, parent, sub := codexTrustFixture(t)
	path := filepath.Join(home, "config.toml")
	before, _ := os.ReadFile(path)
	mirrored, err := TrustCodexDirectoryLikeParent(home, sub)
	if err != nil || mirrored != parent {
		t.Fatalf("write: %q %v", mirrored, err)
	}
	after, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(after), string(before)) ||
		strings.TrimPrefix(string(after), string(before)) != "\n[projects."+tomlQuote(sub)+"]\ntrust_level = \"trusted\"\n" {
		t.Fatalf("file:\n%s", after)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", info.Mode())
	}
	if got := CodexProjectTrust(home, sub); got.Status != CodexTrustTrusted {
		t.Fatalf("after write: %+v", got)
	}
	// Now trusted: a second write refuses and changes nothing.
	if _, err := TrustCodexDirectoryLikeParent(home, sub); err == nil {
		t.Fatal("wrote twice")
	}
	if again, _ := os.ReadFile(path); string(again) != string(after) {
		t.Fatal("refused write changed the file")
	}
	if _, err := TrustCodexDirectoryLikeParent(home, "/elsewhere"); err == nil {
		t.Fatal("wrote trust for a directory with no trusted parent")
	}
}

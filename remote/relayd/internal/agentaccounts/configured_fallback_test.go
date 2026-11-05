package agentaccounts

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fallbackHome makes ~/.local/bin/claude a link to versions/<current>, as
// Claude's installer does, and returns the home and the current version file.
func fallbackHome(t *testing.T) (string, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	current := filepath.Join(home, ".local", "share", "claude", "versions", "2.1.308")
	writeFile(t, current, "#!/bin/sh\n")
	if err := os.Chmod(current, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(home, ".local", "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(current, filepath.Join(home, ".local", "bin", "claude")); err != nil {
		t.Fatal(err)
	}
	real, err := filepath.EvalSymlinks(current)
	if err != nil {
		t.Fatal(err)
	}
	return home, real
}

// A relayd started before Claude updated itself still names the deleted
// version; the launch and status probes use the version ~/.local/bin points to.
func TestMissingConfiguredVersionFallsBackToTheCurrentCLI(t *testing.T) {
	home, current := fallbackHome(t)
	t.Setenv("RELAY_CLAUDE_BIN", filepath.Join(home, ".local", "share", "claude", "versions", "2.1.301"))
	if found, ok := ConfiguredExecutableFallback("claude", os.Getenv("RELAY_CLAUDE_BIN")); !ok || found != current {
		t.Fatalf("%q %v, want %q", found, ok, current)
	}
	if found, err := ProviderExecutable("claude"); err != nil || found != current {
		t.Fatalf("%q %v, want %q", found, err, current)
	}
}

// Only a missing file falls back; one that exists but cannot run stays an error.
func TestConfiguredExecutableThatExistsIsNeverReplaced(t *testing.T) {
	home, _ := fallbackHome(t)
	configured := filepath.Join(home, "claude-custom")
	writeFile(t, configured, "#!/bin/sh\n")
	if err := os.Chmod(configured, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAY_CLAUDE_BIN", configured)
	if found, ok := ConfiguredExecutableFallback("claude", configured); ok {
		t.Fatalf("fell back to %q for an existing file", found)
	}
	if found, err := ProviderExecutable("claude"); err == nil {
		t.Fatalf("a non-runnable configured file resolved to %q", found)
	}
	if err := os.Chmod(configured, 0o700); err != nil {
		t.Fatal(err)
	}
	if found, err := ProviderExecutable("claude"); err != nil || found != configured {
		t.Fatalf("%q %v, want the configured file", found, err)
	}
}

// Without a usable ~/.local/bin/<name> the missing configured path stays an error.
func TestMissingConfiguredVersionWithoutAUsableFallbackStaysAnError(t *testing.T) {
	missing := func(home string) string {
		return filepath.Join(home, ".local", "share", "claude", "versions", "2.1.301")
	}
	cases := map[string]func(t *testing.T, home, current string){
		"no link": func(t *testing.T, home, _ string) {
			if err := os.Remove(filepath.Join(home, ".local", "bin", "claude")); err != nil {
				t.Fatal(err)
			}
		},
		"dangling link": func(t *testing.T, _, current string) {
			if err := os.Remove(current); err != nil {
				t.Fatal(err)
			}
		},
		"not executable": func(t *testing.T, _, current string) {
			if err := os.Chmod(current, 0o644); err != nil {
				t.Fatal(err)
			}
		},
		"directory": func(t *testing.T, home, current string) {
			link := filepath.Join(home, ".local", "bin", "claude")
			if err := os.Remove(link); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(link, 0o755); err != nil {
				t.Fatal(err)
			}
		},
		"relay launcher": func(t *testing.T, home, _ string) {
			shim := filepath.Join(home, ".local", "share", "relay", "shims", "claude")
			writeFile(t, shim, "#!/bin/sh\nexec relayd \"$@\"\n")
			if err := os.Chmod(shim, 0o755); err != nil {
				t.Fatal(err)
			}
			link := filepath.Join(home, ".local", "bin", "claude")
			if err := os.Remove(link); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(shim, link); err != nil {
				t.Fatal(err)
			}
		},
	}
	for name, breakFallback := range cases {
		t.Run(name, func(t *testing.T) {
			home, current := fallbackHome(t)
			breakFallback(t, home, current)
			t.Setenv("RELAY_CLAUDE_BIN", missing(home))
			t.Setenv("PATH", filepath.Join(home, ".local", "bin"))
			if found, ok := ConfiguredExecutableFallback("claude", missing(home)); ok {
				t.Fatalf("fell back to %q", found)
			}
			if found, err := ProviderExecutable("claude"); err == nil || !strings.Contains(err.Error(), "not runnable") {
				t.Fatalf("%q %v, want the configured-path error", found, err)
			}
		})
	}
}

// Without the running image's startup identity the fallback could re-enter
// relayd unnoticed, so none is offered; the configured-path error stands.
func TestMissingConfiguredVersionWithoutAStartupImageIdentityStaysAnError(t *testing.T) {
	home, current := fallbackHome(t)
	configured := filepath.Join(home, ".local", "share", "claude", "versions", "2.1.301")
	t.Setenv("RELAY_CLAUDE_BIN", configured)
	if found, ok := ConfiguredExecutableFallback("claude", configured); !ok || found != current {
		t.Fatalf("control: %q %v, want %q", found, ok, current)
	}
	saved := startupImage
	startupImage = nil
	t.Cleanup(func() { startupImage = saved })
	if found, ok := ConfiguredExecutableFallback("claude", configured); ok {
		t.Fatalf("fell back to %q without a startup image identity", found)
	}
	if found, err := ProviderExecutable("claude"); err == nil || !strings.Contains(err.Error(), "not runnable") {
		t.Fatalf("%q %v, want the configured-path error", found, err)
	}
}

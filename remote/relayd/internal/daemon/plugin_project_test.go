package daemon

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPluginProjectDetection(t *testing.T) {
	for _, tc := range []struct {
		names []string
		want  string
	}{
		{nil, "No supported project manifest"},
		{[]string{"package.json"}, "Inspect package.json scripts"},
		{[]string{"package.json", "pnpm-lock.yaml"}, "Detected pnpm lockfile"},
		{[]string{"package.json", "yarn.lock", "pnpm-lock.yaml"}, "Conflicting lockfiles"},
		{[]string{"package.json", "bun.lock", "bun.lockb"}, "Detected bun lockfile"},
		{[]string{"pyproject.toml"}, "environment and test runner"},
		{[]string{"CMakeLists.txt"}, "CMakePresets.json"},
		{[]string{"Makefile"}, "even make -n can execute"},
	} {
		t.Run(tc.want, func(t *testing.T) {
			root := t.TempDir()
			for _, name := range tc.names {
				if err := os.WriteFile(filepath.Join(root, name), []byte("untrusted $(touch should-not-exist)"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			result, err := InspectPlugin(PluginRequest{Operation: "projectActions", Root: root})
			if err != nil || !strings.Contains(strings.Join(result.Entries, "\n"), tc.want) {
				t.Fatalf("%+v %v", result, err)
			}
			if _, err := os.Stat(filepath.Join(root, "should-not-exist")); !os.IsNotExist(err) {
				t.Fatal("project content executed")
			}
		})
	}
}

func TestPluginProjectIgnoresEscapingManifest(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "go.mod"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "go.mod"), filepath.Join(root, "go.mod")); err != nil {
		t.Fatal(err)
	}
	got, err := InspectPlugin(PluginRequest{Operation: "projectActions", Root: root})
	if err != nil || !strings.Contains(got.Entries[0], "No supported") {
		t.Fatalf("%+v %v", got, err)
	}
}

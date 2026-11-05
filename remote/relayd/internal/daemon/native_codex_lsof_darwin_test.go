//go:build darwin

package daemon

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func withFakeNativeLsof(t *testing.T, script string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "lsof")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+script+"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	previous := nativeLsofPath
	nativeLsofPath = path
	t.Cleanup(func() { nativeLsofPath = previous })
}

func TestNativeLsofSilentNoMatchIsEmptyInventory(t *testing.T) {
	withFakeNativeLsof(t, "exit 1")
	output, err := nativeLsof(context.Background(), "-a", "-p", "1", "-iTCP", "-sTCP:LISTEN", "-Fn")
	if err != nil || output != "" {
		t.Fatalf("silent no-match = %q, %v; want empty inventory", output, err)
	}
}

func TestNativeLsofFailuresRemainUnavailable(t *testing.T) {
	for name, script := range map[string]string{
		"diagnostic":     "echo 'lsof: status error' >&2; exit 1",
		"partial output": "echo 'p1'; exit 1",
		"other status":   "exit 2",
	} {
		t.Run(name, func(t *testing.T) {
			withFakeNativeLsof(t, script)
			if _, err := nativeLsof(context.Background(), "-U"); err == nil || err.Error() != "native kernel socket inventory unavailable" {
				t.Fatalf("error = %v; want inventory unavailable", err)
			}
		})
	}
}

func TestNativeLsofCancelledRemainsUnavailable(t *testing.T) {
	withFakeNativeLsof(t, "exit 1")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := nativeLsof(ctx, "-U"); err == nil {
		t.Fatal("cancelled inventory was accepted")
	}
}

func TestNativeLsofOutputPassesThrough(t *testing.T) {
	withFakeNativeLsof(t, "echo 'n127.0.0.1:4100'")
	output, err := nativeLsof(context.Background(), "-Fn")
	if err != nil || output != "n127.0.0.1:4100\n" {
		t.Fatalf("output = %q, %v", output, err)
	}
}

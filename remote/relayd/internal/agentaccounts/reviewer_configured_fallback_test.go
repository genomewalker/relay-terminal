package agentaccounts

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestReviewerConfiguredFallbackSelfAliases(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"symlink", "hardlink"} {
		t.Run(kind, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			t.Setenv("PATH", "")
			bin := filepath.Join(home, ".local", "bin")
			if err := os.MkdirAll(bin, 0700); err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(bin, "claude")
			if kind == "symlink" {
				err = os.Symlink(self, target)
			} else {
				err = os.Link(self, target)
			}
			if err != nil {
				t.Fatal(err)
			}
			configured := filepath.Join(home, "deleted-version")
			t.Setenv("RELAY_CLAUDE_BIN", configured)
			if got, ok := ConfiguredExecutableFallback("claude", configured); ok {
				t.Fatalf("normal self alias accepted: %q", got)
			}
			if got, err := ProviderExecutable("claude"); err == nil {
				t.Fatalf("provider accepted self alias: %q", got)
			}
		})
	}
}

func TestReviewerConfiguredFallbackCanonicalShimDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PATH", "")
	realDir := filepath.Join(home, "relocated-shims")
	if err := os.MkdirAll(realDir, 0700); err != nil {
		t.Fatal(err)
	}
	shim := filepath.Join(realDir, "claude")
	if err := os.WriteFile(shim, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	canonical := filepath.Join(home, ".local", "share", "relay", "shims")
	if err := os.MkdirAll(filepath.Dir(canonical), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realDir, canonical); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(bin, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(canonical, "claude"), filepath.Join(bin, "claude")); err != nil {
		t.Fatal(err)
	}
	configured := filepath.Join(home, "deleted-version")
	t.Setenv("RELAY_CLAUDE_BIN", configured)
	if got, ok := ConfiguredExecutableFallback("claude", configured); ok {
		t.Fatalf("canonical shim accepted: %q", got)
	}
	if got, err := ProviderExecutable("claude"); err == nil {
		t.Fatalf("provider accepted canonical shim: %q", got)
	}
}

func TestReviewerConfiguredFallbackOnlyNotExist(t *testing.T) {
	for _, kind := range []string{"permission", "loop", "dangling-configured"} {
		t.Run(kind, func(t *testing.T) {
			home, current := fallbackHome(t)
			t.Setenv("PATH", "")
			configured := filepath.Join(home, "configured")
			switch kind {
			case "permission":
				dir := filepath.Join(home, "blocked")
				if err := os.Mkdir(dir, 0700); err != nil {
					t.Fatal(err)
				}
				configured = filepath.Join(dir, "claude")
				if err := os.WriteFile(configured, []byte("#!/bin/sh\n"), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.Chmod(dir, 0); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = os.Chmod(dir, 0700) })
				if _, err := os.Stat(configured); !errors.Is(err, fs.ErrPermission) {
					t.Fatalf("fixture permission precondition: %v", err)
				}
			case "loop":
				if err := os.Symlink(configured, configured); err != nil {
					t.Fatal(err)
				}
				if _, err := os.Stat(configured); !errors.Is(err, syscall.ELOOP) {
					t.Fatalf("fixture ELOOP precondition: %v", err)
				}
			case "dangling-configured":
				if err := os.Symlink(filepath.Join(home, "missing-target"), configured); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("RELAY_CLAUDE_BIN", configured)
			got, ok := ConfiguredExecutableFallback("claude", configured)
			if kind == "dangling-configured" {
				if !ok || got != current {
					t.Fatalf("missing configured target: got %q,%v want %q", got, ok, current)
				}
			} else {
				if ok {
					t.Fatalf("non-ENOENT %s selected %q", kind, got)
				}
				if got, err := ProviderExecutable("claude"); err == nil {
					t.Fatalf("provider replaced nonmissing error with %q", got)
				}
			}
		})
	}
}

func TestReviewerConfiguredSelfImageHelper(t *testing.T) {
	if os.Getenv("REVIEWER_UNLINK_SELF") != "1" {
		t.Skip("private copied-process probe")
	}
	home := os.Getenv("HOME")
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	rel, err := filepath.Rel(home, self)
	if err != nil || strings.HasPrefix(rel, "..") || filepath.Base(self) != "private-selfprobe" {
		t.Fatalf("fixture refuses to unlink unexpected image %q", self)
	}
	before, err := os.Stat(self)
	if err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(bin, 0700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(bin, "claude")
	if err := os.Link(self, alias); err != nil {
		t.Fatal(err)
	}
	linked, err := os.Stat(alias)
	if err != nil || !os.SameFile(before, linked) {
		t.Fatalf("fixture hardlink not same image: %v", err)
	}
	if os.Getenv("REVIEWER_SELF_PATH_MODE") == "replace" {
		replacement := filepath.Join(home, "replacement-image")
		if err := os.WriteFile(replacement, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(replacement, self); err != nil {
			t.Fatal(err)
		}
		now, err := os.Stat(self)
		if err != nil || os.SameFile(before, now) {
			t.Fatalf("fixture image was not replaced: %v", err)
		}
	} else {
		if err := os.Remove(self); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(self); !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("fixture image was not unlinked: %v", err)
		}
	}
	configured := filepath.Join(home, "deleted-version")
	t.Setenv("RELAY_CLAUDE_BIN", configured)
	t.Setenv("PATH", "")
	t.Logf("self-path mode=%s; fallback hardlink retains the running image inode", os.Getenv("REVIEWER_SELF_PATH_MODE"))
	if got, ok := ConfiguredExecutableFallback("claude", configured); ok {
		t.Errorf("SELF_REENTRY_ALLOWED: helper selected its own running image through %q", got)
	}
	if got, err := ProviderExecutable("claude"); err == nil {
		t.Errorf("SELF_REENTRY_ALLOWED: provider selected its own running image through %q", got)
	}
}

func TestReviewerConfiguredFallbackRejectsUnlinkedSelf(t *testing.T) {
	reviewerCopiedImageProbe(t, "unlink")
}
func TestReviewerConfiguredFallbackRejectsReplacedSelf(t *testing.T) {
	reviewerCopiedImageProbe(t, "replace")
}
func reviewerCopiedImageProbe(t *testing.T, mode string) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	copyPath := filepath.Join(home, "private-selfprobe")
	in, err := os.Open(self)
	if err != nil {
		t.Fatal(err)
	}
	out, err := os.OpenFile(copyPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0700)
	if err != nil {
		in.Close()
		t.Fatal(err)
	}
	_, copyErr := io.Copy(out, in)
	in.Close()
	closeErr := out.Close()
	if copyErr != nil || closeErr != nil {
		t.Fatalf("fixture copy: %v %v", copyErr, closeErr)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, copyPath, "-test.run=^TestReviewerConfiguredSelfImageHelper$", "-test.v", "-test.timeout=8s")
	cmd.Env = append(os.Environ(), "HOME="+home, "REVIEWER_UNLINK_SELF=1", "REVIEWER_SELF_PATH_MODE="+mode)
	cmd.WaitDelay = time.Second
	data, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("fixture copied process timed out: %s", data)
	}
	if err != nil {
		t.Fatalf("copied self-image probe failed: %v\n%s", err, data)
	}
	t.Logf("copied self-image probe:\n%s", data)
}

package daemon

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestPluginDirectoryNavigation(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "nested", "deep"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "nested", "hello.txt"), []byte("hello"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	for _, op := range []string{"artifacts", "transfers"} {
		got, err := InspectPlugin(PluginRequest{Operation: op, Root: root})
		if err != nil || got.Directory == nil || *got.Directory != "" || strings.Join(got.Entries, ",") != "nested/" {
			t.Fatalf("root: %+v %v", got, err)
		}
		got, err = InspectPlugin(PluginRequest{Operation: op, Root: root, Path: "nested/"})
		if err != nil || got.Directory == nil || *got.Directory != "nested" || strings.Join(got.Entries, ",") != "nested/deep/,nested/hello.txt" || got.Content != nil {
			t.Fatalf("nested: %+v %v", got, err)
		}
		got, err = InspectPlugin(PluginRequest{Operation: op, Root: root, Path: "nested/hello.txt"})
		if err != nil || got.Directory != nil || got.Content == nil {
			t.Fatalf("file: %+v %v", got, err)
		}
		for _, path := range []string{"escape/", "../"} {
			if _, err := InspectPlugin(PluginRequest{Operation: op, Root: root, Path: path}); err == nil {
				t.Fatalf("accepted %s", path)
			}
		}
	}
}

func TestPluginFilesAndScope(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a ' file.txt"), []byte("hello\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := InspectPlugin(PluginRequest{Operation: "transfers", Root: root, Path: "a ' file.txt"})
	if err != nil {
		t.Fatal(err)
	}
	data, err := base64.StdEncoding.DecodeString(*got.Content)
	if err != nil || string(data) != "hello\n" || len(got.SHA256) != 64 {
		t.Fatalf("bad result: %+v", got)
	}
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret"), []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"escape/secret", "../secret", filepath.Join(outside, "secret")} {
		if _, err := InspectPlugin(PluginRequest{Operation: "artifacts", Root: root, Path: path}); err == nil {
			t.Errorf("accepted %q", path)
		}
	}
	if _, err := InspectPlugin(PluginRequest{Operation: "execute", Root: root}); err == nil {
		t.Fatal("accepted arbitrary operation")
	}
	if _, err := InspectPlugin(PluginRequest{Operation: "artifacts", Root: "."}); err == nil {
		t.Fatal("accepted relative root")
	}
}

func TestPluginEmptyArtifactIncludesContent(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "empty"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	for _, operation := range []string{"artifacts", "transfers"} {
		got, err := InspectPlugin(PluginRequest{Operation: operation, Root: root, Path: "empty"})
		if err != nil {
			t.Fatal(err)
		}
		encoded, err := json.Marshal(got)
		if err != nil || !strings.Contains(string(encoded), `"content":""`) || len(got.SHA256) != 64 {
			t.Fatalf("empty file lost: %s, %v", encoded, err)
		}
	}
}

func TestPluginRejectsFIFOWithoutBlocking(t *testing.T) {
	root := t.TempDir()
	if err := syscall.Mkfifo(filepath.Join(root, "pipe"), 0600); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	if _, err := InspectPlugin(PluginRequest{Operation: "transfers", Root: root, Path: "pipe"}); err == nil {
		t.Fatal("accepted FIFO")
	}
	if time.Since(start) > time.Second {
		t.Fatal("blocked on special file")
	}
}

func TestPluginGitReviewScopesToSubdirectory(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git unavailable")
	}
	root := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		if out, err := exec.Command("git", append([]string{"-C", root}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git: %s: %v", out, err)
		}
	}
	git("init", "--quiet")
	if err := os.Mkdir(filepath.Join(root, "inside"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "inside", "file"), []byte("inside-data"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "outside"), []byte("outside-secret"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", ".")
	// Ambient environment must not redirect the scoped Git operation.
	t.Setenv("GIT_DIR", filepath.Join(t.TempDir(), "wrong-repository"))
	t.Setenv("GIT_WORK_TREE", t.TempDir())
	t.Setenv("GIT_CONFIG_COUNT", "1")
	t.Setenv("GIT_CONFIG_KEY_0", "core.fsmonitor")
	t.Setenv("GIT_CONFIG_VALUE_0", "/definitely/not/a/helper")
	got, err := InspectPlugin(PluginRequest{Operation: "gitReview", Root: filepath.Join(root, "inside"), Path: "file"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got.Text, "inside-data") || strings.Contains(got.Text, "outside-secret") {
		t.Fatalf("unexpected diff: %s", got.Text)
	}
	if !strings.Contains(got.Text, "Worktree and Git directory:") {
		t.Fatal("missing worktree attribution")
	}
}

func TestPluginGitReviewNavigation(t *testing.T) {
	root := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		if out, err := exec.Command("git", append([]string{"-C", root}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("%s: %v", out, err)
		}
	}
	git("init", "--quiet")
	for _, name := range []string{"normal", "line\nbreak", ":(glob)*", "deleted"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("initial\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	git("add", ".")
	git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")
	for _, name := range []string{"normal", "line\nbreak", ":(glob)*"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(name+"-changed\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Remove(filepath.Join(root, "deleted")); err != nil {
		t.Fatal(err)
	}
	got, err := InspectPlugin(PluginRequest{Operation: "gitReview", Root: root})
	if err != nil || len(got.Entries) != 4 || strings.Contains(got.Text, "-changed") {
		t.Fatalf("list: %+v %v", got, err)
	}
	got, err = InspectPlugin(PluginRequest{Operation: "gitReview", Root: root, Path: ":(glob)*"})
	if err != nil || !strings.Contains(got.Text, ":(glob)*-changed") || strings.Contains(got.Text, "normal-changed") {
		t.Fatalf("literal path: %+v %v", got, err)
	}
	got, err = InspectPlugin(PluginRequest{Operation: "gitReview", Root: root, Path: "deleted"})
	if err != nil || !strings.Contains(got.Text, "deleted file") {
		t.Fatalf("deleted: %+v %v", got, err)
	}
	for _, path := range []string{"../outside", root, "missing", "normal/../normal"} {
		if _, err := InspectPlugin(PluginRequest{Operation: "gitReview", Root: root, Path: path}); err == nil {
			t.Fatalf("accepted %q", path)
		}
	}
}

func TestPluginLimitsAndProjectActions(t *testing.T) {
	root := t.TempDir()
	file, err := os.Create(filepath.Join(root, "large"))
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(pluginFileLimit + 1); err != nil {
		t.Fatal(err)
	}
	file.Close()
	if _, err := InspectPlugin(PluginRequest{Operation: "transfers", Root: root, Path: "large"}); err == nil {
		t.Fatal("accepted oversized file")
	}
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("malicious text does not execute"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := InspectPlugin(PluginRequest{Operation: "projectActions", Root: root})
	if err != nil || len(got.Entries) != 1 {
		t.Fatalf("%+v %v", got, err)
	}
	var buffer pluginBuffer
	if _, err := buffer.Write(make([]byte, 1<<20+1)); err == nil {
		t.Fatal("output limit missing")
	}
}

package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestPromptEditorLaunchPreservesConfiguredEditor(t *testing.T) {
	home := filepath.Join(t.TempDir(), "home with spaces")
	if err := os.MkdirAll(filepath.Join(home, ".relay"), 0o700); err != nil {
		t.Fatal(err)
	}
	env := []string{"PATH=/usr/bin", "EDITOR=vim -f", "VISUAL=code --wait", "KEEP=literal"}
	helper := "/owned/helper with spaces/relayd"
	prepared, err := PreparePromptEditorEnvironment(home, helper, "owned-pane", env)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(OriginalPromptEditorEnvironment(prepared), []string{"PATH=/usr/bin", "KEEP=literal", "EDITOR=vim -f", "VISUAL=code --wait"}) {
		t.Fatal("configured editor environment changed")
	}
	entries, _ := os.ReadDir(filepath.Join(home, ".relay", "prompt-editor"))
	launchers := 0
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), "editor-") {
			continue
		}
		launchers++
		path := filepath.Join(home, ".relay", "prompt-editor", entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(data), "unset RELAY_INVOKED_AS") || !strings.Contains(string(data), shellQuote(helper)) {
			t.Fatal("launcher command changed")
		}
		if output, err := exec.Command("/bin/sh", "-n", path).CombinedOutput(); err != nil {
			t.Fatalf("launcher syntax: %v %s", err, output)
		}
	}
	if launchers != 1 {
		t.Fatal("launcher missing")
	}
	if _, err := PreparePromptEditorEnvironment(home, helper, "owned-pane", env); err != nil {
		t.Fatal("identical launch not idempotent")
	}
}

func TestPromptEditorLaunchKeepsAbsentAndEmptyEditorDistinct(t *testing.T) {
	for _, env := range [][]string{{"KEEP=literal"}, {"KEEP=literal", "EDITOR="}} {
		home := t.TempDir()
		if err := os.Mkdir(filepath.Join(home, ".relay"), 0o700); err != nil {
			t.Fatal(err)
		}
		prepared, err := PreparePromptEditorEnvironment(home, "/owned/relayd", "owned-pane", env)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(OriginalPromptEditorEnvironment(prepared), env) {
			t.Fatal("absent/empty editor changed")
		}
	}
}

func TestPromptEditorCapabilityRejectsChangedLaunch(t *testing.T) {
	home := t.TempDir()
	if err := os.Mkdir(filepath.Join(home, ".relay"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := PreparePromptEditorEnvironment(home, "/owned/relayd", "owned-pane", nil); err != nil {
		t.Fatal(err)
	}
	owner := promptEditorTestOwner()
	owner.ProcessID = os.Getpid()
	var err error
	owner.ProcessStart, err = processStartTime(owner.ProcessID)
	if err != nil {
		t.Fatal(err)
	}
	if err := validatePromptEditorCapabilityAtHome(home, owner); err != nil {
		t.Fatal(err)
	}
	other := owner
	other.PaneID = "another-pane"
	if validatePromptEditorCapabilityAtHome(home, other) == nil {
		t.Fatal("different pane accepted launch record")
	}
	other = owner
	other.ProcessStart++
	if validatePromptEditorCapabilityAtHome(home, other) == nil {
		t.Fatal("different incarnation accepted launch record")
	}
	directory := filepath.Join(home, ".relay", "prompt-editor")
	entries, _ := os.ReadDir(directory)
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "editor-") {
			if err := os.WriteFile(filepath.Join(directory, entry.Name()), []byte("changed"), 0o700); err != nil {
				t.Fatal(err)
			}
		}
	}
	if validatePromptEditorCapabilityAtHome(home, owner) == nil {
		t.Fatal("changed launcher accepted")
	}
}

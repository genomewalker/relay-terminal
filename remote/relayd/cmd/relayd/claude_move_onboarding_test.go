package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
)

func TestClaudeMoveOnboardingReadsTheAgentFolderAndRefusesWhatItCannotCheck(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if _, err := agentaccounts.Save(home, agentaccounts.DefaultRegistry()); err != nil {
		t.Fatal(err)
	}
	main := `{"hasCompletedOnboarding": true, "lastOnboardingVersion": "2.1.302", "userID": "main",
	  "projects": {"/work/project": {"hasTrustDialogAccepted": true}}}`
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte(main), 0o600); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(home, ".claude-personal", ".claude.json")
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		t.Fatal(err)
	}
	saved := processDirectory
	t.Cleanup(func() { processDirectory = saved })
	asked := 0
	processDirectory = func(pid int) (string, error) {
		asked = pid
		if pid == 4242 {
			return "/work/project", nil
		}
		return "", errors.New("no such process")
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"-", "~/.claude-personal"}, "usage"},
		{[]string{"-", "~/.claude-personal", "1"}, "process is invalid"},
		{[]string{"-", "~/.claude-personal", "x"}, "process is invalid"},
		{[]string{"-", "~/.claude-personal", "77"}, "folder could not be read"},
	} {
		if _, err := claudeMoveOnboarding(c.args); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%v: %v", c.args, err)
		}
	}
	if _, err := os.Lstat(target); !os.IsNotExist(err) {
		t.Fatal("a refused check wrote the target")
	}
	result, err := claudeMoveOnboarding([]string{"-", "~/.claude-personal", "4242"})
	if err != nil || asked != 4242 || result.Status != agentaccounts.MoveOnboardingUpdated {
		t.Fatalf("result %+v, %v (asked pid %d)", result, err, asked)
	}
	data, _ := os.ReadFile(target)
	if strings.Contains(string(data), "userID") || !strings.Contains(string(data), `"/work/project"`) {
		t.Fatalf("target %s", data)
	}
	if again, err := claudeMoveOnboarding([]string{"-", "~/.claude-personal", "4242"}); err != nil || again.Status != agentaccounts.MoveOnboardingReady {
		t.Fatalf("second check %+v, %v", again, err)
	}
}

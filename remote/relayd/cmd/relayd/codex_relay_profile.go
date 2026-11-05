package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

// relayCodexProfileName is the Codex profile Relay launches with
// (`--profile relay-terminal`). Codex reads it from
// $CODEX_HOME/relay-terminal.config.toml, so an account move that keeps the
// profile needs one in the target account too.
const relayCodexProfileName = "relay-terminal"

const relayCodexProfileHeader = "# Managed by Relay Terminal."

var codexAccountDirectory = regexp.MustCompile(`^(~/|/)[A-Za-z0-9._/-]{1,240}$`)

// runCodexRelayProfile writes Relay's hooks-only Codex profile into one
// account: `relayd codex-relay-profile <CODEX_HOME>`. It has no model line,
// so the account's own default model applies, and its hook trust keys name
// this account's profile path. It only ever creates the file; an existing
// one is never replaced, whoever wrote it.
func runCodexRelayProfile(arguments []string) {
	if len(arguments) != 1 {
		fatal("usage: relayd codex-relay-profile <CODEX_HOME>")
	}
	home, _ := os.UserHomeDir()
	status, path, err := ensureCodexRelayProfile(arguments[0], home)
	if err != nil {
		fatal(err.Error())
	}
	raw, _ := json.Marshal(map[string]string{"status": status, "path": path})
	fmt.Println(string(raw))
}

// existingCodexRelayProfile judges a profile already at path: "current" when
// it is exactly Relay's, an error otherwise. It never changes the file: a
// stale Relay-managed profile is reported, not replaced, so no concurrent
// writer can lose its bytes. ("", nil) means nothing is there.
func existingCodexRelayProfile(path string, want []byte) (string, error) {
	existing, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if !existing.Mode().IsRegular() {
		return "", errors.New(path + " is not a regular file; it was not changed")
	}
	current, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if bytes.Equal(current, want) {
		return "current", nil
	}
	if bytes.HasPrefix(current, []byte(relayCodexProfileHeader)) {
		return "", errors.New(path + " is a stale Relay profile from another version; it was not changed. " +
			"Remove it to let Relay write the current one")
	}
	return "", errors.New(path + " is not managed by Relay; it was not changed")
}

func ensureCodexRelayProfile(account, home string) (string, string, error) {
	if !codexAccountDirectory.MatchString(account) || strings.Contains(account, "//") ||
		strings.HasSuffix(account, "/") {
		return "", "", errors.New("the Codex account directory is invalid")
	}
	for _, part := range strings.Split(account, "/") {
		if part == ".." {
			return "", "", errors.New("the Codex account directory is invalid")
		}
	}
	directory := account
	if strings.HasPrefix(account, "~/") {
		if !filepath.IsAbs(home) {
			return "", "", errors.New("the home directory is unavailable")
		}
		directory = filepath.Join(home, account[2:])
	}
	if filepath.Clean(directory) != directory {
		return "", "", errors.New("the Codex account directory is invalid")
	}
	info, err := os.Stat(directory)
	if err != nil || !info.IsDir() {
		return "", "", errors.New("the Codex account directory does not exist")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Getuid() {
		return "", "", errors.New("the Codex account directory is not owned by this user")
	}
	path := filepath.Join(directory, relayCodexProfileName+".config.toml")
	want := []byte(codexHookProfile(path))
	if status, err := existingCodexRelayProfile(path, want); status != "" || err != nil {
		return status, path, err
	}
	// Create only, never replace: the complete file is written aside, then
	// hard-linked into place, which fails if anything exists there by then.
	temporary, err := os.CreateTemp(directory, ".relay-terminal-*.toml")
	if err != nil {
		return "", path, err
	}
	defer os.Remove(temporary.Name())
	err = temporary.Chmod(0o600)
	if err == nil {
		_, err = temporary.Write(want)
	}
	if err == nil {
		err = temporary.Sync()
	}
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return "", path, err
	}
	if err := os.Link(temporary.Name(), path); err != nil {
		if errors.Is(err, os.ErrExist) {
			// Created meanwhile, by the user or another Relay: judge that file.
			status, err := existingCodexRelayProfile(path, want)
			if status == "" && err == nil {
				err = errors.New(path + " changed while it was prepared; it was not changed")
			}
			return status, path, err
		}
		return "", path, err
	}
	return "written", path, nil
}

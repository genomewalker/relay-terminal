package terminfo

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

const (
	Name         = "xterm-relay"
	FallbackName = "xterm-256color"
)

// ncurses databases use either the first character (x/) or its hexadecimal
// byte value (78/) as the entry directory, depending on how the host library
// was configured. Relay's Linux payload must work on both HPC layouts without
// requiring tic, so the same architecture-independent entry is installed in
// both locations.
var entryDirectories = []string{"x", "78"}

// entry is a standalone ncurses entry compiled from Relay's bundled Ghostty
// capabilities. It is data, not executable code, and is installed in the
// remote user's own terminfo database without requiring tic on the host.
//
//go:embed assets/78/xterm-relay
var entry []byte

type Status struct {
	Name       string `json:"name"`
	Fallback   string `json:"fallback"`
	Root       string `json:"root,omitempty"`
	Path       string `json:"path,omitempty"`
	Hash       string `json:"hash"`
	Installed  bool   `json:"installed"`
	Updated    bool   `json:"updated"`
	Resolvable bool   `json:"resolvable"`
	Reason     string `json:"reason,omitempty"`
}

var (
	currentOnce   sync.Once
	currentStatus Status
	currentError  error
)

func ContentHash() string {
	sum := sha256.Sum256(entry)
	return hex.EncodeToString(sum[:])
}

func EnsureCurrentUser() (Status, error) {
	currentOnce.Do(func() {
		home, err := os.UserHomeDir()
		if err != nil {
			currentError = err
			return
		}
		currentStatus, currentError = EnsureUser(home)
	})
	return currentStatus, currentError
}

// EnsureUser installs or updates Relay's entry atomically in ~/.terminfo.
// Existing content with the same hash is left untouched so every relayd
// invocation is a cheap idempotent check.
func EnsureUser(home string) (Status, error) {
	status := Status{Name: Name, Fallback: FallbackName, Hash: ContentHash()}
	if home == "" || !filepath.IsAbs(home) {
		status.Reason = "home directory is unavailable"
		return status, errors.New(status.Reason)
	}
	status.Root = filepath.Join(home, ".terminfo")
	status.Path = filepath.Join(status.Root, entryDirectories[0], Name)

	changed := false
	for _, directory := range entryDirectories {
		entryPath := filepath.Join(status.Root, directory, Name)
		entryChanged, err := installFile(entryPath, entry)
		if err != nil {
			status.Reason = err.Error()
			return status, err
		}
		changed = changed || entryChanged
	}
	status.Installed = true
	status.Updated = changed
	if err := writeHashStamp(home, status.Hash); err != nil {
		status.Reason = err.Error()
		return status, err
	}
	status.Resolvable, status.Reason = resolves(status.Root)
	return status, nil
}

func PreferredEnvironment() map[string]string {
	status, err := EnsureCurrentUser()
	if err != nil || !status.Resolvable {
		return map[string]string{"TERM": FallbackName}
	}
	return map[string]string{
		"TERM":     Name,
		"TERMINFO": status.Root,
	}
}

func installFile(path string, data []byte) (bool, error) {
	if existing, err := os.ReadFile(path); err == nil && bytes.Equal(existing, data) {
		return false, nil
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	parent := filepath.Dir(path)
	if err := os.MkdirAll(parent, 0o700); err != nil {
		return false, err
	}
	temporary, err := os.CreateTemp(parent, ".xterm-relay.*")
	if err != nil {
		return false, err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o644); err != nil {
		temporary.Close()
		return false, err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return false, err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return false, err
	}
	if err := temporary.Close(); err != nil {
		return false, err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return false, err
	}
	return true, nil
}

func writeHashStamp(home, hash string) error {
	directory := filepath.Join(home, ".local", "share", "relay", "terminfo")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	_, err := installFile(filepath.Join(directory, Name+".sha256"), []byte(hash+"\n"))
	return err
}

func resolves(root string) (bool, string) {
	infocmp, err := exec.LookPath("infocmp")
	if err != nil {
		return false, "infocmp is unavailable; using xterm-256color"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, infocmp, "-A", root, Name)
	command.Env = append(os.Environ(), "TERMINFO="+root)
	if output, err := command.CombinedOutput(); err != nil {
		if ctx.Err() != nil {
			return false, "terminfo resolution timed out; using xterm-256color"
		}
		return false, fmt.Sprintf("terminfo resolution failed: %s", bytes.TrimSpace(output))
	}
	return true, ""
}

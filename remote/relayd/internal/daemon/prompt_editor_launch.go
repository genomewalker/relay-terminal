package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

type promptEditorCapability struct {
	Version        int    `json:"version"`
	Pane           string `json:"pane"`
	PID            int    `json:"pid"`
	Start          uint64 `json:"start"`
	Launcher       string `json:"launcher"`
	LauncherSHA256 string `json:"launcher_sha256"`
}

func privatePromptEditorBytes(path string, limit int64) ([]byte, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || info.Size() > limit {
		return nil, errors.New("prompt editor launch record is not private")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, errors.New("prompt editor launch record unavailable")
	}
	return data, nil
}

func createPromptEditorPrivateFile(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if errors.Is(err, os.ErrExist) {
		current, err := privatePromptEditorBytes(path, int64(len(data)))
		if err == nil && string(current) == string(data) {
			return nil
		}
		return errors.New("prompt editor launch file changed")
	}
	if err != nil {
		return err
	}
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(path)
	}
	return err
}

// Explicitly enabled launches receive a stable private launcher. Existing
// providers are never restarted or rebound to install this environment.
func PreparePromptEditorEnvironment(home, helper, pane string, environment []string) ([]string, error) {
	if !filepath.IsAbs(helper) || !validSessionID.MatchString(pane) {
		return nil, errors.New("invalid prompt editor launch")
	}
	directory := filepath.Join(home, ".relay", "prompt-editor")
	if err := EnsurePrivateRuntimeDir(directory); err != nil {
		return nil, err
	}
	script := []byte("#!/bin/sh\nunset RELAY_INVOKED_AS\nexec " + shellQuote(helper) + " prompt-editor \"$@\"\n")
	digest := sha256.Sum256(script)
	launcher := filepath.Join(directory, "editor-"+hex.EncodeToString(digest[:])+".sh")
	if err := createPromptEditorPrivateFile(launcher, script, 0o700); err != nil {
		return nil, err
	}
	start, err := processStartTime(os.Getpid())
	if err != nil {
		return nil, err
	}
	capability := promptEditorCapability{Version: 1, Pane: pane, PID: os.Getpid(), Start: start, Launcher: launcher, LauncherSHA256: hex.EncodeToString(digest[:])}
	encoded, err := json.Marshal(capability)
	if err != nil {
		return nil, err
	}
	path := filepath.Join(directory, promptEditorCapabilityFilename(capability.PID, start))
	if err := createPromptEditorPrivateFile(path, encoded, 0o600); err != nil {
		return nil, err
	}
	result := make([]string, 0, len(environment)+5)
	for _, entry := range environment {
		name, value, found := strings.Cut(entry, "=")
		if found && (name == "EDITOR" || name == "VISUAL") {
			result = append(result, "RELAY_PROMPT_ORIGINAL_"+name+"="+value)
			continue
		}
		if strings.HasPrefix(name, "RELAY_PROMPT_ORIGINAL_") || name == "RELAY_PROMPT_EDITOR_BRIDGE" {
			continue
		}
		result = append(result, entry)
	}
	command := launcher
	if strings.ContainsAny(command, " \t") {
		command = shellQuote(command)
	}
	return append(result, "EDITOR="+command, "VISUAL="+command, "RELAY_PROMPT_EDITOR_BRIDGE=1"), nil
}

var errPromptEditorUnsupported = errors.New("provider has no prompt editor bridge")

func validatePromptEditorCapability(owner PromptOwnerBinding) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	return validatePromptEditorCapabilityAtHome(home, owner)
}

func validatePromptEditorCapabilityAtHome(home string, owner PromptOwnerBinding) error {
	directory := filepath.Join(home, ".relay", "prompt-editor")
	directoryInfo, err := os.Lstat(directory)
	if os.IsNotExist(err) {
		return errPromptEditorUnsupported
	}
	if err != nil || !directoryInfo.IsDir() || directoryInfo.Mode()&os.ModeSymlink != 0 || directoryInfo.Mode().Perm() != 0o700 {
		return errors.New("provider prompt editor directory changed")
	}
	stat, ok := directoryInfo.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() {
		return errors.New("provider prompt editor directory owner changed")
	}
	path := filepath.Join(directory, promptEditorCapabilityFilename(owner.ProcessID, owner.ProcessStart))
	data, err := privatePromptEditorBytes(path, 8192)
	if os.IsNotExist(err) {
		return errPromptEditorUnsupported
	}
	if err != nil {
		return errors.New("provider has no prompt editor bridge")
	}
	var capability promptEditorCapability
	if json.Unmarshal(data, &capability) != nil || capability.Version != 1 || capability.Pane != owner.PaneID || capability.PID != owner.ProcessID || capability.Start != owner.ProcessStart || filepath.Dir(capability.Launcher) != directory {
		return errors.New("provider prompt editor bridge changed")
	}
	script, err := privatePromptEditorBytes(capability.Launcher, 8192)
	if err != nil {
		return err
	}
	info, err := os.Lstat(capability.Launcher)
	if err != nil || info.Mode().Perm()&0o100 == 0 {
		return errors.New("provider prompt editor launcher is not executable")
	}
	digest := sha256.Sum256(script)
	if hex.EncodeToString(digest[:]) != capability.LauncherSHA256 {
		return errors.New("provider prompt editor launcher changed")
	}
	return nil
}

func OriginalPromptEditorEnvironment(environment []string) []string {
	original := map[string]string{}
	for _, entry := range environment {
		name, value, found := strings.Cut(entry, "=")
		if found && strings.HasPrefix(name, "RELAY_PROMPT_ORIGINAL_") {
			original[strings.TrimPrefix(name, "RELAY_PROMPT_ORIGINAL_")] = value
		}
	}
	result := make([]string, 0, len(environment))
	for _, entry := range environment {
		name, _, _ := strings.Cut(entry, "=")
		if name == "EDITOR" || name == "VISUAL" || strings.HasPrefix(name, "RELAY_PROMPT_ORIGINAL_") || name == "RELAY_PROMPT_EDITOR_BRIDGE" {
			continue
		}
		result = append(result, entry)
	}
	for _, name := range []string{"EDITOR", "VISUAL"} {
		if value, ok := original[name]; ok {
			result = append(result, name+"="+value)
		}
	}
	return result
}

// Kept private to bridge launch records; never use a pane ID alone as proof.
func promptEditorCapabilityFilename(pid int, start uint64) string {
	return "capability-" + strconv.Itoa(pid) + "-" + strconv.FormatUint(start, 10) + ".json"
}

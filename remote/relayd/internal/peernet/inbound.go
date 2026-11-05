package peernet

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// RecipientInboundClass predicts the permission class a live Claude recipient's
// cross-session inbound policy compares a sender's mode against: "bypass" or
// "prompting", or "" with a reason when it cannot be predicted. A
// crossSessionInbound setting in any layer Relay can see, or a layer it cannot
// read, overrides the parity rule, so the prediction is then unknown.
func RecipientInboundClass(home string, pid int, session string) (string, string) {
	class := SenderPermissionClass(home, pid, session)
	if class == "" {
		return "", "class_unknown"
	}
	layers, err := claudeSettingsLayers(home, pid)
	if err != nil {
		return "", "settings_unknown"
	}
	for _, layer := range layers {
		set, err := setsCrossSessionInbound(layer)
		if err != nil {
			return "", "settings_unreadable"
		}
		if set {
			return "", "inbound_setting"
		}
	}
	return class, ""
}

// settingsLayer is a settings file path or an inline --settings JSON value.
type settingsLayer struct {
	path   string
	inline []byte
}

// claudeSettingsLayers lists the settings Claude reads for this process: the
// account's user settings, managed settings, the project's shared and local
// settings, and any --settings argument. In a git repository Claude keeps the
// local file at the repository root (for a linked worktree, the main
// checkout's root) and still honours the starting directory's file, so every
// directory from the working directory up to that root is included. Extra
// layers can only make the prediction unknown, never definite.
func claudeSettingsLayers(home string, pid int) ([]settingsLayer, error) {
	config := claudeConfig(home, pid)
	cwd, err := processWorkingDirectory(pid)
	if err != nil {
		return nil, err
	}
	paths := []string{filepath.Join(config, "settings.json"), filepath.Join(config, "settings.local.json")}
	projects, err := claudeProjectDirectories(cwd)
	if err != nil {
		return nil, err
	}
	for _, dir := range projects {
		paths = append(paths, filepath.Join(dir, ".claude", "settings.json"), filepath.Join(dir, ".claude", "settings.local.json"))
	}
	managed := "/etc/claude-code"
	if runtime.GOOS == "darwin" {
		managed = "/Library/Application Support/ClaudeCode"
	}
	paths = append(paths, filepath.Join(managed, "managed-settings.json"))
	dropIns, _ := filepath.Glob(filepath.Join(managed, "managed-settings.d", "*.json"))
	paths = append(paths, dropIns...)
	layers := []settingsLayer{}
	for _, path := range paths {
		layers = append(layers, settingsLayer{path: path})
	}
	args, err := processArguments(pid)
	if err != nil {
		return nil, err
	}
	extra, err := settingsArgumentLayers(args, cwd)
	if err != nil {
		return nil, err
	}
	return append(layers, extra...), nil
}

// settingsArgumentLayers reads each --settings argument: a file path, relative
// to the process's working directory, or inline JSON.
func settingsArgumentLayers(args []string, cwd string) ([]settingsLayer, error) {
	layers := []settingsLayer{}
	for i := 1; i < len(args); i++ {
		name, value, inline := strings.Cut(args[i], "=")
		if name != "--settings" {
			continue
		}
		if !inline {
			if i+1 >= len(args) {
				return nil, errors.New("incomplete --settings argument")
			}
			i++
			value = args[i]
		}
		if strings.HasPrefix(strings.TrimSpace(value), "{") {
			layers = append(layers, settingsLayer{inline: []byte(value)})
		} else {
			if !filepath.IsAbs(value) {
				value = filepath.Join(cwd, value)
			}
			layers = append(layers, settingsLayer{path: value})
		}
	}
	return layers, nil
}

// setsCrossSessionInbound reports whether a settings layer names the
// crossSessionInbound key; only that top-level key is decoded. A missing file
// sets nothing; an unreadable or malformed one is an error.
func setsCrossSessionInbound(layer settingsLayer) (bool, error) {
	data := layer.inline
	if layer.path != "" {
		file, err := os.Open(layer.path)
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		defer file.Close()
		info, err := file.Stat()
		if err != nil || !info.Mode().IsRegular() || info.Size() > 4<<20 {
			return false, errors.New("settings file is not a bounded regular file")
		}
		if data, err = io.ReadAll(io.LimitReader(file, 4<<20)); err != nil {
			return false, err
		}
	}
	var settings map[string]json.RawMessage
	if err := json.Unmarshal(data, &settings); err != nil {
		return false, err
	}
	_, set := settings["crossSessionInbound"]
	return set, nil
}

// claudeProjectDirectories returns the working directory, each ancestor up to
// its git repository root, and a linked worktree's main checkout root. Git
// metadata is read from the filesystem only; anything it cannot resolve is an
// error, so the caller's prediction becomes unknown.
func claudeProjectDirectories(cwd string) ([]string, error) {
	if !filepath.IsAbs(cwd) {
		return nil, errors.New("working directory is not absolute")
	}
	dirs := []string{}
	for dir, depth := filepath.Clean(cwd), 0; depth < 128; dir, depth = filepath.Dir(dir), depth+1 {
		dirs = append(dirs, dir)
		marker := filepath.Join(dir, ".git")
		info, err := os.Lstat(marker)
		switch {
		case errors.Is(err, os.ErrNotExist):
			if parent := filepath.Dir(dir); parent != dir {
				continue
			}
			// Not in a repository: the working directory is the project.
			return []string{filepath.Clean(cwd)}, nil
		case err != nil:
			return nil, err
		case info.IsDir():
			return dirs, nil
		case info.Mode().IsRegular():
			main, err := gitWorktreeMainRoot(dir, marker)
			if err != nil {
				return nil, err
			}
			return append(dirs, main), nil
		default:
			return nil, errors.New("unrecognised git metadata")
		}
	}
	return nil, errors.New("working directory is too deep")
}

// gitWorktreeMainRoot follows a linked worktree's .git file to its common git
// directory and returns the main checkout that owns it.
func gitWorktreeMainRoot(worktree, marker string) (string, error) {
	gitdir, err := readGitPointer(marker, "gitdir: ")
	if err != nil {
		return "", err
	}
	if !filepath.IsAbs(gitdir) {
		gitdir = filepath.Join(worktree, gitdir)
	}
	common, err := readGitPointer(filepath.Join(gitdir, "commondir"), "")
	if err != nil {
		return "", err
	}
	if !filepath.IsAbs(common) {
		common = filepath.Join(gitdir, common)
	}
	common = filepath.Clean(common)
	if filepath.Base(common) != ".git" {
		return "", errors.New("worktree's main repository has no checkout")
	}
	return filepath.Dir(common), nil
}

func readGitPointer(path, prefix string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 4097))
	if err != nil || len(data) > 4096 {
		return "", errors.New("git pointer unreadable")
	}
	value := strings.TrimSpace(string(data))
	if !strings.HasPrefix(value, prefix) || strings.ContainsAny(value, "\n\x00") {
		return "", errors.New("git pointer malformed")
	}
	value = strings.TrimPrefix(value, prefix)
	if value == "" {
		return "", errors.New("git pointer empty")
	}
	return value, nil
}

func processWorkingDirectory(pid int) (string, error) {
	if runtime.GOOS == "linux" {
		return os.Readlink(filepath.Join("/proc", strconv.Itoa(pid), "cwd"))
	}
	out, err := exec.Command("/usr/sbin/lsof", "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn").Output()
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "n/") {
			return line[1:], nil
		}
	}
	return "", errors.New("working directory unavailable")
}

func processArguments(pid int) ([]string, error) {
	if runtime.GOOS == "linux" {
		data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
		if err != nil {
			return nil, err
		}
		return strings.Split(strings.TrimRight(string(data), "\x00"), "\x00"), nil
	}
	out, err := exec.Command("/bin/ps", "-p", strconv.Itoa(pid), "-o", "args=").Output()
	if err != nil {
		return nil, err
	}
	return strings.Fields(string(out)), nil
}

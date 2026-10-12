//go:build linux

package agentlaunch

import (
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

type CodexSocket struct {
	Path             string `json:"path"`
	Device           uint64 `json:"device"`
	Inode            uint64 `json:"inode"`
	Executable       string `json:"executable"`
	WorkingDirectory string `json:"working_directory"`
	SourcePID        int    `json:"source_pid"`
	SourceStart      string `json:"source_start"`
}

// DiscoverCodexSocket derives the app-server endpoint from the exact running
// Codex process. It never reads a guessed user's home or prints environment
// values. The caller must still make an authenticated app-server probe before
// using the socket, and compare device/inode again after connecting.
func DiscoverCodexSocket(snapshot Snapshot) (CodexSocket, error) {
	if snapshot.Client != "codex" {
		return CodexSocket{}, errors.New("source is not Codex")
	}
	if err := VerifyProcess(snapshot); err != nil {
		return CodexSocket{}, err
	}
	environment, err := boundedRead(filepath.Join("/proc", strconv.Itoa(snapshot.PID), "environ"))
	if err != nil {
		return CodexSocket{}, errors.New("source environment unavailable")
	}
	path, err := codexSocketCandidate(snapshot.EffectiveArgs, environment)
	if err != nil {
		return CodexSocket{}, err
	}
	dev, ino, err := privateCodexSocket(path)
	if err != nil {
		return CodexSocket{}, err
	}
	if err := VerifyProcess(snapshot); err != nil {
		return CodexSocket{}, err
	}
	return CodexSocket{Path: path, Device: dev, Inode: ino,
		Executable: snapshot.Executable, WorkingDirectory: snapshot.CWD,
		SourcePID: snapshot.PID, SourceStart: snapshot.ProcessStart}, nil
}

func codexSocketCandidate(args []string, environment []byte) (string, error) {
	var remote string
	for i, arg := range args {
		if arg == "--remote" {
			if i+1 >= len(args) || remote != "" {
				return "", errors.New("ambiguous Codex remote endpoint")
			}
			remote = args[i+1]
		} else if strings.HasPrefix(arg, "--remote=") {
			if remote != "" {
				return "", errors.New("ambiguous Codex remote endpoint")
			}
			remote = strings.TrimPrefix(arg, "--remote=")
		}
	}
	var path string
	if remote != "" {
		parsed, err := url.Parse(remote)
		if err != nil || parsed.Scheme != "unix" || parsed.Host != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
			return "", errors.New("Codex remote endpoint is not a local Unix socket")
		}
		path = parsed.Path
	} else {
		vars := map[string]string{}
		for _, field := range strings.Split(string(environment), "\x00") {
			key, value, found := strings.Cut(field, "=")
			if found && (key == "CODEX_HOME" || key == "HOME") {
				if _, duplicate := vars[key]; duplicate {
					return "", errors.New("source home is ambiguous")
				}
				vars[key] = value
			}
		}
		home := vars["CODEX_HOME"]
		if home == "" {
			if vars["HOME"] == "" {
				return "", errors.New("source home is unavailable")
			}
			home = filepath.Join(vars["HOME"], ".codex")
		}
		path = filepath.Join(home, "app-server-control", "app-server-control.sock")
	}
	if !filepath.IsAbs(path) || filepath.Clean(path) != path || strings.ContainsRune(path, 0) {
		return "", errors.New("Codex socket path is invalid")
	}
	return path, nil
}

func privateCodexSocket(path string) (uint64, uint64, error) {
	parent, err := os.Lstat(filepath.Dir(path))
	if err != nil || !parent.IsDir() || parent.Mode().Perm()&0077 != 0 {
		return 0, 0, errors.New("Codex socket directory is not private")
	}
	parentStat, ok := parent.Sys().(*syscall.Stat_t)
	if !ok || parentStat.Uid != uint32(os.Getuid()) {
		return 0, 0, errors.New("Codex socket directory owner changed")
	}
	socket, err := os.Lstat(path)
	if err != nil || socket.Mode()&os.ModeSocket == 0 || socket.Mode().Perm()&0077 != 0 {
		return 0, 0, errors.New("Codex control socket is unavailable or public")
	}
	stat, ok := socket.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return 0, 0, errors.New("Codex control socket owner changed")
	}
	return uint64(stat.Dev), stat.Ino, nil
}

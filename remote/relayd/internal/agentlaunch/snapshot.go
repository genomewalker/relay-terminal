package agentlaunch

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type Snapshot struct {
	RequestedArgsCaptured bool      `json:"requested_args_captured"`
	Schema                int       `json:"schema"`
	LaunchID              string    `json:"launch_id"`
	Client                string    `json:"client"`
	Executable            string    `json:"executable"`
	CWD                   string    `json:"cwd"`
	PID                   int       `json:"pid"`
	ProcessStart          string    `json:"process_start,omitempty"`
	RelayPaneID           string    `json:"relay_pane_id,omitempty"`
	CapturedAt            time.Time `json:"captured_at"`
	RequestedArgs         []string  `json:"requested_args"`
	EffectiveArgs         []string  `json:"effective_args"`
	Arguments             Arguments `json:"arguments"`
	// The provider account directory variable (CLAUDE_CONFIG_DIR or
	// CODEX_HOME) the process started with; "" means the provider default.
	// Recorded only by snapshots that set ConfigDirRecorded.
	ConfigDir         string `json:"config_dir,omitempty"`
	ConfigDirRecorded bool   `json:"config_dir_recorded,omitempty"`
}

// Save records the calling process, which is about to exec the agent with its
// own environment, so the account directory is read from that environment.
func Save(directory, client, executable, cwd, paneID, start string, requested, effective []string) (string, error) {
	name, err := ConfigDirVariable(client)
	if err != nil {
		return "", errors.New("invalid launch binding")
	}
	return save(directory, client, executable, cwd, paneID, start, os.Getpid(), os.Getenv(name), append([]string{}, requested...), effective)
}

func save(directory, client, executable, cwd, paneID, start string, pid int, configDir string, requested, effective []string) (string, error) {
	if !filepath.IsAbs(directory) || !filepath.IsAbs(executable) || !filepath.IsAbs(cwd) || (client != "claude" && client != "codex") {
		return "", errors.New("invalid launch binding")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return "", err
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return "", errors.New("launch directory must be private")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != uint32(os.Getuid()) {
		return "", errors.New("launch directory has a different owner")
	}
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	id := hex.EncodeToString(nonce)
	args := FreshArguments(client, effective)
	if start == "" {
		args.Reusable = false
		args.Reason = "process_incarnation_unverified"
	}
	snapshot := Snapshot{RequestedArgsCaptured: requested != nil, Schema: 1, LaunchID: id, Client: client, Executable: executable, CWD: cwd, PID: pid, ProcessStart: start, RelayPaneID: paneID, CapturedAt: time.Now().UTC(), RequestedArgs: append([]string{}, requested...), EffectiveArgs: append([]string{}, effective...), Arguments: args,
		ConfigDir: configDir, ConfigDirRecorded: true}
	data, err := json.Marshal(snapshot)
	if err != nil || len(data) > 65536 {
		return "", errors.New("launch snapshot exceeds bound")
	}
	path := filepath.Join(directory, id+".json")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return "", err
	}
	if err := file.Sync(); err != nil {
		return "", err
	}
	parent, err := os.Open(directory)
	if err != nil {
		return "", err
	}
	defer parent.Close()
	if err := parent.Sync(); err != nil {
		return "", err
	}
	return path, nil
}

// Linux exec preserves PID/start ticks. Other platforms capture the arguments
// but abstain from reuse until a platform-specific incarnation is available.
func ProcessStart() string {
	data, err := os.ReadFile("/proc/self/stat")
	if err != nil {
		return ""
	}
	close := strings.LastIndexByte(string(data), ')')
	if close < 0 {
		return ""
	}
	fields := strings.Fields(string(data[close+1:]))
	if len(fields) <= 19 {
		return ""
	}
	return fields[19]
}

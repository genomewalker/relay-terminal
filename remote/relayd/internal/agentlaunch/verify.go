package agentlaunch

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

// ReadVerified loads only a private retained launch from this user's Relay
// directory. Its arguments are never returned to a command-line caller.
func ReadVerified(path, digest string) (Snapshot, error) {
	return ReadVerifiedClient(path, digest, "claude")
}

func ReadVerifiedClient(path, digest, client string) (Snapshot, error) {
	var snapshot Snapshot
	if client != "claude" && client != "codex" {
		return snapshot, errors.New("unsupported launch client")
	}
	home, err := os.UserHomeDir()
	if err != nil || len(digest) != 64 || filepath.Dir(path) != filepath.Join(home, ".local", "share", "relay", "agent-launches") {
		return snapshot, errors.New("launch snapshot location is unverified")
	}
	dir, err := os.Lstat(filepath.Dir(path))
	if err != nil || !dir.IsDir() || dir.Mode().Perm()&0077 != 0 || dir.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return snapshot, errors.New("launch snapshot directory is not private")
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) || info.Size() > 65536 {
		return snapshot, errors.New("launch snapshot is not private")
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) > 65536 {
		return snapshot, errors.New("launch snapshot cannot be read")
	}
	actual := sha256.Sum256(data)
	if hex.EncodeToString(actual[:]) != digest {
		return snapshot, errors.New("launch snapshot digest changed")
	}
	if err := json.Unmarshal(data, &snapshot); err != nil || snapshot.Schema != 1 || snapshot.Client != client ||
		!filepath.IsAbs(snapshot.CWD) || !filepath.IsAbs(snapshot.Executable) || snapshot.PID <= 0 || snapshot.ProcessStart == "" ||
		snapshot.RelayPaneID == "" || !snapshot.Arguments.Reusable ||
		!slices.Equal(FreshArguments(client, snapshot.EffectiveArgs).Fresh, snapshot.Arguments.Fresh) ||
		len(snapshot.Arguments.Fresh) > 128 {
		return Snapshot{}, errors.New("launch snapshot does not contain reusable settings")
	}
	for _, arg := range snapshot.Arguments.Fresh {
		if strings.ContainsRune(arg, 0) || len(arg) > 8192 {
			return Snapshot{}, errors.New("launch argument is invalid")
		}
	}
	return snapshot, nil
}

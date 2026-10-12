package daemon

import (
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
	"github.com/relay-terminal/relayd/internal/protocol"
)

var codexThreadID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

type codexRotationClaim struct {
	IntentID       string   `json:"intent_id"`
	PaneID         string   `json:"pane_id"`
	SessionID      string   `json:"session_id"`
	SnapshotSHA256 string   `json:"snapshot_sha256"`
	SocketPath     string   `json:"socket_path"`
	SocketDevice   uint64   `json:"socket_device"`
	SocketInode    uint64   `json:"socket_inode"`
	Arguments      []string `json:"arguments"`
}

func validateCodexRotationArgs(fresh, planned []string, threadID string, socket agentlaunch.CodexSocket) error {
	if !codexThreadID.MatchString(threadID) || len(fresh)+4 != len(planned) {
		return errors.New("invalid Codex rotation thread or argument count")
	}
	for i, value := range fresh {
		if planned[i] != value {
			return errors.New("Codex launch changed captured configuration")
		}
	}
	suffix := planned[len(fresh):]
	if suffix[0] != "resume" || suffix[1] != "--remote" || suffix[2] != (&url.URL{Scheme: "unix", Path: socket.Path}).String() || suffix[3] != threadID {
		return errors.New("Codex launch selector or derived socket changed")
	}
	return nil
}

// LaunchCodexRotationPane reserves exactly one fresh Relay worker for an
// already-created app-server root. The caller must authenticate that root and
// socket before requesting this operation; the worker rechecks the source.
func (server *Server) LaunchCodexRotationPane(snapshotPath, snapshotSHA, intentID, threadID string, plannedArgs []string) (string, error) {
	if intentID == "" || len(intentID) > 110 || strings.ContainsRune(intentID, 0) || !codexThreadID.MatchString(threadID) {
		return "", errors.New("invalid Codex rotation identity")
	}
	snapshot, err := agentlaunch.ReadVerifiedClient(snapshotPath, snapshotSHA, "codex")
	if err != nil {
		return "", err
	}
	socket, err := agentlaunch.DiscoverCodexSocket(snapshot)
	if err != nil {
		return "", err
	}
	if err := validateCodexRotationArgs(snapshot.Arguments.Fresh, plannedArgs, threadID, socket); err != nil {
		return "", err
	}
	paneID := ClaudeRotationID(intentID + ":pane")
	claimPath := filepath.Join(server.stateDir, "rotation-launches", paneID+".json")
	command := "exec " + shellQuote(server.executable) + " rotation-codex-exec --snapshot " + shellQuote(snapshotPath) +
		" --sha " + shellQuote(snapshotSHA) + " --intent " + shellQuote(intentID) +
		" --thread " + shellQuote(threadID) + " --pane " + shellQuote(paneID) + " --claim " + shellQuote(claimPath)
	workerLock := server.workerLock(paneID)
	workerLock.Lock()
	defer workerLock.Unlock()
	for _, candidate := range []string{server.manifestPath(paneID), server.recoveredManifestPath(paneID)} {
		if _, err := os.Lstat(candidate); err == nil {
			return "", errors.New("rotation pane already exists")
		} else if !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
	}
	claims := filepath.Join(server.stateDir, "rotation-launches")
	if err := os.MkdirAll(claims, 0o700); err != nil {
		return "", err
	}
	info, err := os.Lstat(claims)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return "", errors.New("rotation claim directory is not private")
	}
	file, err := os.OpenFile(claimPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", errors.New("rotation launch already claimed or unavailable")
	}
	claim, _ := json.Marshal(codexRotationClaim{IntentID: intentID, PaneID: paneID, SessionID: threadID,
		SnapshotSHA256: snapshotSHA, SocketPath: socket.Path, SocketDevice: socket.Device, SocketInode: socket.Inode, Arguments: plannedArgs})
	if _, err := file.Write(claim); err != nil {
		_ = file.Close()
		return "", err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return "", err
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	dir, err := os.Open(claims)
	if err != nil {
		return "", err
	}
	if err := dir.Sync(); err != nil {
		_ = dir.Close()
		return "", err
	}
	_ = dir.Close()
	if _, err := server.startWorker(protocol.HelloPayload{SessionID: paneID, Command: command,
		WorkingDirectory: snapshot.CWD, RotationControlled: true, Cols: 120, Rows: 36}, server.manifestPath(paneID)); err != nil {
		return "", err
	}
	return paneID, nil
}

func ReadCodexRotationClaim(path, intentID, paneID, threadID, snapshotSHA string, snapshot agentlaunch.Snapshot) ([]string, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return nil, errors.New("private Codex rotation claim unavailable")
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) > 65536 {
		return nil, errors.New("Codex rotation claim unavailable")
	}
	var claim codexRotationClaim
	if err := json.Unmarshal(data, &claim); err != nil {
		return nil, err
	}
	socket, err := agentlaunch.DiscoverCodexSocket(snapshot)
	if err != nil {
		return nil, err
	}
	if claim.IntentID != intentID || claim.PaneID != paneID || claim.SessionID != threadID || claim.SnapshotSHA256 != snapshotSHA ||
		claim.SocketPath != socket.Path || claim.SocketDevice != socket.Device || claim.SocketInode != socket.Inode ||
		validateCodexRotationArgs(snapshot.Arguments.Fresh, claim.Arguments, threadID, socket) != nil {
		return nil, errors.New("Codex rotation claim does not match source")
	}
	return claim.Arguments, nil
}

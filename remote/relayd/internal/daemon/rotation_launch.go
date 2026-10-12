package daemon

import (
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
	"github.com/relay-terminal/relayd/internal/protocol"
)

type claudeRotationClaim struct {
	IntentID        string   `json:"intent_id"`
	PaneID          string   `json:"pane_id"`
	SessionID       string   `json:"session_id"`
	SourceSessionID string   `json:"source_session_id"`
	SnapshotSHA256  string   `json:"snapshot_sha256"`
	Arguments       []string `json:"arguments"`
}

func validateClaudeRotationArgs(fresh, planned []string, sessionID string) error {
	for _, arg := range fresh {
		if arg == "--allowedTools" || arg == "--allowed-tools" ||
			strings.HasPrefix(arg, "--allowedTools=") || strings.HasPrefix(arg, "--allowed-tools=") {
			return errors.New("captured receipt permissions require review")
		}
	}
	if len(planned) != len(fresh)+4 {
		return errors.New("rotation launch arguments differ from approved plan")
	}
	for i, value := range fresh {
		if planned[i] != value {
			return errors.New("rotation launch changed captured configuration")
		}
	}
	suffix := planned[len(fresh):]
	if suffix[0] != "--session-id" || suffix[1] != sessionID || suffix[2] != "--allowedTools" {
		return errors.New("rotation launch selector or receipt permission is invalid")
	}
	const prefix = "Bash(python3 "
	const tail = " receipt *)"
	rule := suffix[3]
	if !strings.HasPrefix(rule, prefix) || !strings.HasSuffix(rule, tail) {
		return errors.New("rotation receipt permission is invalid")
	}
	helper := strings.TrimSuffix(strings.TrimPrefix(rule, prefix), tail)
	if !filepath.IsAbs(helper) || filepath.Clean(helper) != helper ||
		filepath.Base(helper) != "claude_backend.py" || filepath.Base(filepath.Dir(helper)) != "rotation-decision" ||
		strings.ContainsAny(helper, " \t\r\n'\";|&$`(){}[]<>\\") {
		return errors.New("rotation receipt helper is invalid")
	}
	return nil
}

var claudeRotationNamespace = [16]byte{0x5f, 0x1b, 0x7c, 0x1e, 0x3a, 0x0e, 0x4d, 0x2b, 0x9a, 0x57, 0x2c, 0x4f, 0x1f, 0x0e, 0x9b, 0x11}

// ClaudeRotationID mirrors uuid5(namespace, name) in the Swift and Python
// adapters, allowing a lost start response to be reconciled by exact ID.
func ClaudeRotationID(name string) string {
	value := sha1.Sum(append(claudeRotationNamespace[:], []byte(name)...))
	value[6] = value[6]&0x0f | 0x50
	value[8] = value[8]&0x3f | 0x80
	return hex.EncodeToString(value[0:4]) + "-" + hex.EncodeToString(value[4:6]) + "-" +
		hex.EncodeToString(value[6:8]) + "-" + hex.EncodeToString(value[8:10]) + "-" + hex.EncodeToString(value[10:16])
}

// LaunchClaudeRotationPane starts only a brand-new, stable pane. A private
// reservation is durable before the worker starts and is never removed on an
// unknown outcome. It never calls ensureWorker, which can reuse/restart panes.
func (server *Server) LaunchClaudeRotationPane(snapshotPath, snapshotSHA, intentID, sourceSessionID string, plannedArgs []string) (string, string, error) {
	if intentID == "" || len(intentID) > 110 || strings.ContainsRune(intentID, 0) {
		return "", "", errors.New("invalid rotation intent")
	}
	snapshot, err := agentlaunch.ReadVerified(snapshotPath, snapshotSHA)
	if err != nil {
		return "", "", err
	}
	if err := agentlaunch.VerifyProcess(snapshot); err != nil {
		return "", "", err
	}
	effective, err := agentlaunch.DiscoverClaudeEffectiveSettings(snapshot, sourceSessionID)
	if err != nil {
		return "", "", err
	}
	sessionID := ClaudeRotationID(intentID)
	paneID := ClaudeRotationID(intentID + ":pane")
	if err := validateClaudeRotationArgs(effective.FreshArguments, plannedArgs, sessionID); err != nil {
		return "", "", err
	}
	claimPath := filepath.Join(server.stateDir, "rotation-launches", paneID+".json")
	command := "exec " + shellQuote(server.executable) + " rotation-exec --snapshot " + shellQuote(snapshotPath) +
		" --sha " + shellQuote(snapshotSHA) + " --intent " + shellQuote(intentID) +
		" --session " + shellQuote(sessionID) + " --source-session " + shellQuote(sourceSessionID) +
		" --pane " + shellQuote(paneID) + " --claim " + shellQuote(claimPath)
	workerLock := server.workerLock(paneID)
	workerLock.Lock()
	defer workerLock.Unlock()
	// A prior manifest, including an unreadable or recovered one, is not safe
	// evidence that a second launch is desired.
	for _, candidate := range []string{server.manifestPath(paneID), server.recoveredManifestPath(paneID)} {
		if _, err := os.Lstat(candidate); err == nil {
			return "", "", errors.New("rotation pane already exists")
		} else if !errors.Is(err, os.ErrNotExist) {
			return "", "", err
		}
	}
	claims := filepath.Join(server.stateDir, "rotation-launches")
	if err := os.MkdirAll(claims, 0o700); err != nil {
		return "", "", err
	}
	info, err := os.Lstat(claims)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return "", "", errors.New("rotation claim directory is not private")
	}
	file, err := os.OpenFile(claimPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", "", errors.New("rotation launch already claimed or unavailable")
	}
	claim, _ := json.Marshal(claudeRotationClaim{IntentID: intentID, PaneID: paneID,
		SessionID: sessionID, SourceSessionID: sourceSessionID, SnapshotSHA256: snapshotSHA, Arguments: plannedArgs})
	if _, err := file.Write(claim); err != nil {
		_ = file.Close()
		return "", "", err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return "", "", err
	}
	if err := file.Close(); err != nil {
		return "", "", err
	}
	dir, err := os.Open(claims)
	if err != nil {
		return "", "", err
	}
	if err := dir.Sync(); err != nil {
		_ = dir.Close()
		return "", "", err
	}
	_ = dir.Close()
	if _, err := server.startWorker(protocol.HelloPayload{SessionID: paneID, Command: command,
		WorkingDirectory: snapshot.CWD, RotationControlled: true, Cols: 120, Rows: 36}, server.manifestPath(paneID)); err != nil {
		// The claim intentionally remains. Caller must inspect the stable pane.
		return "", "", err
	}
	return sessionID, paneID, nil
}

// ReadClaudeRotationClaim returns only exact, private launch arguments bound to
// the stable pane. The worker refuses an absent or modified claim.
func ReadClaudeRotationClaim(path, intentID, paneID, sessionID, sourceSessionID, snapshotSHA string, fresh []string) ([]string, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 ||
		info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return nil, errors.New("private rotation claim unavailable")
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) > 65536 {
		return nil, errors.New("rotation claim unavailable")
	}
	var claim claudeRotationClaim
	if err := json.Unmarshal(data, &claim); err != nil || claim.IntentID != intentID ||
		claim.PaneID != paneID || claim.SessionID != sessionID || claim.SourceSessionID != sourceSessionID || claim.SnapshotSHA256 != snapshotSHA ||
		validateClaudeRotationArgs(fresh, claim.Arguments, sessionID) != nil {
		return nil, errors.New("rotation claim does not match source")
	}
	return claim.Arguments, nil
}

// SnapshotDigest is used by local tests and by the caller to bind the source
// file without ever exposing its argument contents in a response.
func SnapshotDigest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

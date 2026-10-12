package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"
)

// Discovery reads only the verified provider transcript. It neither enrolls a
// pane nor obtains terminal input ownership.
type hostRotationNativeCandidate struct {
	Version int                `json:"v"`
	State   string             `json:"state"`
	CWD     string             `json:"cwd"`
	Binding AgentBindingRecord `json:"binding"`
	path    string
	info    os.FileInfo
}

func sameHostRotationNativeBinding(a, b AgentBindingRecord) bool {
	return a.Version == b.Version && a.Producer == b.Producer && a.SessionID == b.SessionID &&
		a.TranscriptPath == b.TranscriptPath && a.Revision != "" && a.Revision == b.Revision
}

func readHostRotationNativeCandidate(ctx context.Context, pane string) (hostRotationNativeCandidate, error) {
	var empty hostRotationNativeCandidate
	before, err := ReadNativeAgentBinding(pane)
	if err != nil {
		return empty, err
	}
	if ctx.Err() != nil {
		return empty, ctx.Err()
	}
	candidate, err := readHostRotationNativeDirectory(ctx, before)
	if err != nil {
		return empty, err
	}
	after, err := ReadNativeAgentBinding(pane)
	if err != nil || !sameHostRotationNativeBinding(before, after) {
		return empty, errors.New("native session changed during directory discovery")
	}
	if ctx.Err() != nil {
		return empty, ctx.Err()
	}
	if err := candidate.verifyFile(); err != nil {
		return empty, err
	}
	return candidate, nil
}

func readHostRotationNativeDirectory(ctx context.Context, binding AgentBindingRecord) (hostRotationNativeCandidate, error) {
	var empty hostRotationNativeCandidate
	if binding.Version != 1 || binding.Revision == "" || !validSessionID.MatchString(binding.SessionID) {
		return empty, errors.New("native session directory unavailable")
	}
	path, err := rotationSourcePath(binding.TranscriptPath, binding.Producer.Provider)
	if err != nil {
		return empty, err
	}
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return empty, errors.New("native transcript unavailable")
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	before, err := file.Stat()
	current, statErr := os.Lstat(path)
	if err != nil || statErr != nil || !sameRotationSourceFile(before, current) ||
		before.Size() <= 0 || before.Size() > rotationSourceFileLimit {
		return empty, errors.New("native transcript changed or exceeds directory discovery limit")
	}
	cwd, err := parseHostRotationNativeDirectory(ctx, io.LimitReader(file, rotationSourceFileLimit+1),
		binding.Producer.Provider, binding.SessionID)
	if err != nil {
		return empty, err
	}
	after, err := file.Stat()
	if err != nil || !sameRotationSourceFile(before, after) {
		return empty, errors.New("native transcript changed")
	}
	candidate := hostRotationNativeCandidate{Version: 1, State: "ready", CWD: cwd,
		Binding: binding, path: path, info: before}
	if err := candidate.verifyFile(); err != nil {
		return empty, err
	}
	return candidate, nil
}

// Metadata is checked across the bounded stream so mixed session/directory
// records cannot select a directory. Public message bodies are never returned.
func parseHostRotationNativeDirectory(ctx context.Context, reader io.Reader, provider, session string) (string, error) {
	if provider != "codex" && provider != "claude" {
		return "", errors.New("unsupported native provider")
	}
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64<<10), rotationSourceLineLimit)
	cwd, identified, records := "", false, 0
	for scanner.Scan() {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		records++
		if records > 200000 {
			return "", errors.New("native directory record limit exceeded")
		}
		line := scanner.Bytes()
		if !utf8.Valid(line) || !rotationSourceJSONUnambiguous(line) {
			return "", errors.New("invalid native directory metadata")
		}
		var row rotationSourceRow
		if json.Unmarshal(line, &row) != nil {
			return "", errors.New("invalid native directory record")
		}
		observed := ""
		if provider == "codex" {
			if row.Type == "response_item" && !identified {
				return "", errors.New("native directory identity must precede messages")
			}
			if row.Type != "session_meta" {
				continue
			}
			var meta struct {
				ID           string          `json:"id"`
				CWD          string          `json:"cwd"`
				ThreadSource string          `json:"thread_source"`
				Source       json.RawMessage `json:"source"`
			}
			if identified || json.Unmarshal(row.Payload, &meta) != nil || meta.ID != session ||
				(meta.ThreadSource != "" && meta.ThreadSource != "user") ||
				(meta.ThreadSource == "" && string(meta.Source) != `"cli"`) {
				return "", errors.New("native directory session identity mismatch")
			}
			observed = meta.CWD
		} else {
			if (row.Type != "user" && row.Type != "assistant") || row.Sidechain {
				continue
			}
			if row.SessionID != session {
				return "", errors.New("native directory session identity mismatch")
			}
			observed = row.CWD
		}
		if !filepath.IsAbs(observed) || len(observed) > 4096 || strings.ContainsRune(observed, 0) ||
			(identified && cwd != observed) {
			return "", errors.New("native session directory is missing or inconsistent")
		}
		cwd, identified = observed, true
	}
	if scanner.Err() != nil {
		return "", errors.New("native directory line limit or read failure")
	}
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if !identified {
		return "", errors.New("native session directory metadata unavailable")
	}
	return cwd, nil
}

func (c hostRotationNativeCandidate) matches(req hostRotationRequest, pane string) bool {
	return c.Version == 1 && c.State == "ready" && c.Binding.Producer.PaneID == pane &&
		c.Binding.SessionID == req.SessionID && c.Binding.Producer.Provider == req.Client &&
		c.CWD == req.CWD && c.Binding.Producer.ProcessID == req.AgentPID &&
		c.Binding.Producer.ProcessStart == req.AgentStart
}

func (c hostRotationNativeCandidate) verifyFile() error {
	path, err := rotationSourcePath(c.Binding.TranscriptPath, c.Binding.Producer.Provider)
	if err != nil || path != c.path {
		return errors.New("native directory source path changed")
	}
	current, err := os.Lstat(path)
	if err != nil || !sameRotationSourceFile(c.info, current) {
		return errors.New("native directory source changed")
	}
	return nil
}

// Slow metadata/native reads happen before Session.inputMu. This final check
// uses only file/kernel identity while human input and enrollment are serialized.
// Later evaluation and rotation still re-observe the native runtime and ledger.
func (c hostRotationNativeCandidate) verifyEnrollment(e hostRotationEnrollment) error {
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(e.PaneID))
	if err != nil || manifest.SessionID != e.PaneID || manifest.WorkerPID != e.WorkerPID ||
		manifest.WorkerStartTime != e.WorkerStart || manifest.NodeBootID != e.NodeBootID ||
		validateWorkerIdentity(manifest) != nil {
		return errors.New("host rotation worker identity changed")
	}
	start, err := NativeAgentIncarnation(e.PaneID, e.AgentPID, e.Client)
	if err != nil || start != e.AgentStart {
		return errors.New("host rotation provider identity changed")
	}
	provider, pid := nativeBindingFrontend(manifest.ShellPID)
	if provider != e.Client || pid != e.AgentPID {
		return errors.New("host rotation frontend selection changed")
	}
	return c.verifyFile()
}

//go:build linux

package daemon

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func linuxOpenCodexTranscript(pid int) (string, string, string, error) {
	directory := fmt.Sprintf("/proc/%d/fd", pid)
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) > 4096 {
		return "", "", "", errors.New("native transcript descriptors unavailable")
	}
	candidates := map[string]nativeCodexTranscriptCandidate{}
	override := processAccountOverride(pid, "codex")
	for _, entry := range entries {
		descriptor := filepath.Join(directory, entry.Name())
		path, e := os.Readlink(descriptor)
		if e != nil || !strings.HasSuffix(path, ".jsonl") || validateAccountTranscript(path, "codex", override) != nil {
			continue
		}
		canonical, e := filepath.EvalSymlinks(path)
		if e != nil {
			continue
		}
		file, e := os.Open(descriptor)
		if e != nil {
			continue
		}
		opened, e := file.Stat()
		named, nameErr := os.Lstat(canonical)
		if e != nil || nameErr != nil || !os.SameFile(opened, named) {
			file.Close()
			continue
		}
		row, readErr := bufio.NewReader(io.LimitReader(file, 1048577)).ReadBytes('\n')
		file.Close()
		if (readErr != nil && readErr != io.EOF) || len(row) > 1048576 {
			continue
		}
		session, parent, kind, metadataErr := nativeCodexOpenTranscriptMetadata(row)
		if metadataErr != nil {
			continue
		}
		// Opening /proc/PID/fd/N preserves the exact descriptor object; the pathname
		// is accepted only when it still denotes that same object.
		after, e := os.Stat(descriptor)
		if e != nil || !os.SameFile(opened, after) {
			continue
		}
		stat, ok := opened.Sys().(*syscall.Stat_t)
		if !ok || int(stat.Uid) != os.Getuid() || !opened.Mode().IsRegular() {
			continue
		}
		identity := fmt.Sprintf("%d:%d", stat.Dev, stat.Ino)
		candidates[canonical] = nativeCodexTranscriptCandidate{canonical, session, identity, parent, kind}
	}
	return selectNativeCodexOpenTranscript(candidates)
}

func nativeCodexOpenTranscriptBinding(pane string, pid int, start uint64) (AgentBindingRecord, error) {
	var empty AgentBindingRecord
	path, session, identity, err := linuxOpenCodexTranscript(pid)
	if err != nil {
		return empty, err
	}
	afterPath, afterSession, afterIdentity, err := linuxOpenCodexTranscript(pid)
	if err != nil || path != afterPath || session != afterSession || identity != afterIdentity {
		return empty, errors.New("open native transcript changed")
	}
	current, err := NativeAgentIncarnation(pane, pid, "codex")
	if err != nil || current != start {
		return empty, errors.New("native transcript producer changed")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || validateWorkerIdentity(manifest) != nil {
		return empty, errors.New("native transcript worker changed")
	}
	provider, currentPID := nativeBindingFrontend(manifest.ShellPID)
	if provider != "codex" || currentPID != pid {
		return empty, errors.New("native transcript frontend changed")
	}
	data, _ := json.Marshal([]any{pane, pid, start, path, session, identity})
	sum := sha256.Sum256(data)
	return AgentBindingRecord{Version: 1, Producer: agentProducer{PaneID: pane, Provider: "codex", ProcessID: pid, ProcessStart: start},
		SessionID: session, TranscriptPath: path, ObservedAt: time.Now().UTC(), Lifecycle: "unknown", Revision: hex.EncodeToString(sum[:]), Source: "kernel_open_transcript"}, nil
}

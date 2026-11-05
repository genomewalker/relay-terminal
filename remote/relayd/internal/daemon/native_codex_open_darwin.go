//go:build darwin

package daemon

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type darwinNativeTranscriptDescriptor struct {
	descriptor int
	path       string
	device     uint64
	inode      uint64
}

// Read the machine-readable inventory for one exact process. Path text alone
// never establishes ownership: an eligible regular descriptor must also carry
// the kernel device and inode of the object opened below.
func darwinNativeTranscriptDescriptors(raw string, pid int) ([]darwinNativeTranscriptDescriptor, error) {
	if len(raw) > 1<<20 {
		return nil, errors.New("native descriptor inventory exceeds limit")
	}
	result := []darwinNativeTranscriptDescriptor{}
	currentPID := 0
	descriptor := -1
	values := map[byte]string{}
	flush := func() error {
		if descriptor < 0 || values['t'] != "REG" || !strings.HasSuffix(values['n'], ".jsonl") {
			return nil
		}
		device, e1 := strconv.ParseUint(values['D'], 0, 64)
		inode, e2 := strconv.ParseUint(values['i'], 10, 64)
		if currentPID != pid || e1 != nil || e2 != nil || inode == 0 || len(values['n']) > 4096 || !strings.HasPrefix(values['n'], "/") {
			return errors.New("native transcript descriptor identity unavailable")
		}
		result = append(result, darwinNativeTranscriptDescriptor{descriptor, values['n'], device, inode})
		return nil
	}
	files := 0
	for _, line := range strings.Split(raw, "\n") {
		if line == "" {
			continue
		}
		key, value := line[0], line[1:]
		switch key {
		case 'p':
			if err := flush(); err != nil {
				return nil, err
			}
			actual, err := strconv.Atoi(value)
			if err != nil || actual != pid || currentPID != 0 {
				return nil, errors.New("native descriptor process changed")
			}
			currentPID = actual
			descriptor = -1
			values = map[byte]string{}
		case 'f':
			if currentPID != pid {
				return nil, errors.New("native descriptor process missing")
			}
			if err := flush(); err != nil {
				return nil, err
			}
			files++
			if files > 4096 {
				return nil, errors.New("native descriptor inventory exceeds limit")
			}
			descriptor = -1
			values = map[byte]string{}
			number := strings.TrimSuffix(strings.TrimSuffix(strings.TrimSuffix(value, "u"), "w"), "r")
			if v, err := strconv.ParseUint(number, 10, 16); err == nil && v <= 4095 {
				descriptor = int(v)
			}
		case 't', 'D', 'i', 'n':
			if currentPID != pid || files == 0 {
				return nil, errors.New("native descriptor record missing")
			}
			if _, exists := values[key]; exists {
				return nil, errors.New("ambiguous native descriptor field")
			}
			values[key] = value
		default:
			return nil, errors.New("unsupported native descriptor field")
		}
	}
	if err := flush(); err != nil {
		return nil, err
	}
	if currentPID != pid {
		return nil, errors.New("native descriptor process missing")
	}
	return result, nil
}

func darwinOpenCodexTranscript(ctx context.Context, pid int) (string, string, string, error) {
	descriptors, err := darwinKernelTranscriptDescriptors(ctx, pid)
	if err != nil {
		return "", "", "", err
	}
	candidates := map[string]nativeCodexTranscriptCandidate{}
	for _, descriptor := range descriptors {
		path, err := processSourcePath(pid, descriptor.path, "codex")
		if err != nil {
			continue
		}
		fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
		if err != nil {
			continue
		}
		file := os.NewFile(uintptr(fd), path)
		opened, statErr := file.Stat()
		named, nameErr := os.Lstat(path)
		stat, ok := openedSyscallStat(opened)
		if statErr != nil || nameErr != nil || !ok || !os.SameFile(opened, named) ||
			uint64(stat.Dev) != descriptor.device || stat.Ino != descriptor.inode ||
			int(stat.Uid) != os.Getuid() || !opened.Mode().IsRegular() {
			file.Close()
			continue
		}
		row, readErr := bufio.NewReader(io.LimitReader(file, 1048577)).ReadBytes('\n')
		file.Close()
		if (readErr != nil && readErr != io.EOF) || len(row) > 1048576 || !rotationSourceJSONUnambiguous(row) {
			continue
		}
		session, parent, kind, metadataErr := nativeCodexOpenTranscriptMetadata(row)
		if metadataErr != nil {
			continue
		}
		current, currentErr := os.Lstat(path)
		if currentErr != nil || !os.SameFile(opened, current) {
			continue
		}
		identity := fmt.Sprintf("%d:%d", stat.Dev, stat.Ino)
		candidates[path] = nativeCodexTranscriptCandidate{path, session, identity, parent, kind}
	}
	return selectNativeCodexOpenTranscript(candidates)
}

func openedSyscallStat(info os.FileInfo) (*syscall.Stat_t, bool) {
	if info == nil {
		return nil, false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return stat, ok
}

func nativeCodexOpenTranscriptBinding(pane string, pid int, start uint64) (AgentBindingRecord, error) {
	var empty AgentBindingRecord
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	path, session, identity, err := darwinOpenCodexTranscript(ctx, pid)
	if err != nil {
		return empty, err
	}
	afterPath, afterSession, afterIdentity, err := darwinOpenCodexTranscript(ctx, pid)
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
	return AgentBindingRecord{Version: 1, Producer: agentProducer{PaneID: pane, Provider: "codex", ProcessID: pid, ProcessStart: start}, SessionID: session, TranscriptPath: path, ObservedAt: time.Now().UTC(), Lifecycle: "unknown", Revision: hex.EncodeToString(sum[:]), Source: "kernel_open_transcript"}, nil
}

package daemon

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"golang.org/x/sys/unix"
)

const hostRotationCapsuleLimit = 64 << 10
const hostRotationCapsuleDirectory = "rotation-capsules"

// A storage receipt is descriptive evidence, not a native reservation or claim.
// Only the foreground/core owners may authorize a close/restore transaction.
type hostRotationCapsuleReceipt struct {
	ArtifactID string `json:"artifact_id"`
	SHA256     string `json:"sha256"`
	Bytes      int    `json:"bytes"`
}

type hostRotationCapsuleBinding struct {
	Enrollment        hostRotationEnrollment `json:"enrollment"`
	TurnID            string                 `json:"turn_id"`
	TurnSeq           uint64                 `json:"turn_seq"`
	TranscriptMtimeMS int64                  `json:"transcript_mtime_ms"`
	TranscriptBytes   int64                  `json:"transcript_bytes"`
	SourceSHA256      string                 `json:"source_sha256"`
	EvidenceSHA256    string                 `json:"evidence_sha256"`
	BindingRevision   string                 `json:"binding_revision"`
	SourceChunks      int                    `json:"source_chunks"`
}

type hostRotationCapsuleRecord struct {
	Version int                        `json:"v"`
	Source  hostRotationCapsuleBinding `json:"source"`
	Body    string                     `json:"body"`
	SHA256  string                     `json:"sha256"`
	Bytes   int                        `json:"bytes"`
}

func hostRotationCapsuleHash(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func hostRotationCapsuleDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func hostRotationCapsuleSource(source hostRotationSource) (hostRotationCapsuleBinding, error) {
	e, b := source.Enrollment, source.Boundary
	validText := func(s string, max int) bool {
		return strings.TrimSpace(s) != "" && len(s) <= max && utf8.ValidString(s) && !strings.ContainsRune(s, '\x00')
	}
	if !validText(e.SessionID, 110) || (e.Client != "codex" && e.Client != "claude") ||
		!validText(e.CWD, 4096) || !filepath.IsAbs(e.CWD) || !validText(e.PaneID, 256) ||
		e.AgentPID <= 0 || e.AgentStart == 0 || e.WorkerPID <= 0 || e.WorkerStart == 0 ||
		!validText(e.NodeBootID, 256) || !validText(b.TurnID, 256) || b.TurnSeq == 0 ||
		b.TranscriptMtimeMS <= 0 || b.TranscriptBytes <= 0 || b.TranscriptBytes > rotationSourceFileLimit ||
		!validText(source.BindingRevision, 256) || !hostRotationCapsuleDigest(source.TranscriptSHA256) ||
		!hostRotationCapsuleDigest(source.EvidenceSHA256) || len(source.Chunks) == 0 || len(source.Chunks) > rotationSourceMaxChunks {
		return hostRotationCapsuleBinding{}, errors.New("invalid capsule source binding")
	}
	return hostRotationCapsuleBinding{Enrollment: e, TurnID: b.TurnID, TurnSeq: b.TurnSeq,
		TranscriptMtimeMS: b.TranscriptMtimeMS, TranscriptBytes: b.TranscriptBytes,
		SourceSHA256: source.TranscriptSHA256, EvidenceSHA256: source.EvidenceSHA256,
		BindingRevision: source.BindingRevision, SourceChunks: len(source.Chunks)}, nil
}

func encodeHostRotationCapsule(source hostRotationSource, draft hostRotationDraft) ([]byte, hostRotationCapsuleReceipt, error) {
	var empty hostRotationCapsuleReceipt
	binding, err := hostRotationCapsuleSource(source)
	if err != nil {
		return nil, empty, err
	}
	if err := validateHostRotationDraft(draft); err != nil {
		return nil, empty, err
	}
	// Only the bounded descriptive draft enters the restored context. Physical
	// ownership and source evidence remain in the separate private envelope.
	body, err := json.Marshal(draft)
	if err != nil {
		return nil, empty, err
	}
	record := hostRotationCapsuleRecord{Version: 1, Source: binding, Body: string(body),
		SHA256: hostRotationCapsuleHash(body), Bytes: len(body)}
	data, err := json.Marshal(record)
	if err != nil || len(data) > hostRotationCapsuleLimit {
		return nil, empty, errors.New("capsule envelope exceeds limit")
	}
	return data, hostRotationCapsuleReceipt{ArtifactID: hostRotationCapsuleHash(data), SHA256: record.SHA256, Bytes: len(body)}, nil
}

// Keep all child operations relative to owned directory descriptors. Symlink
// swaps cannot redirect a record read or write to a different parent.
func openHostRotationCapsuleRoot(workerDirectory string, create bool) (*os.File, error) {
	return openHostRotationPrivateRoot(workerDirectory, hostRotationCapsuleDirectory, create)
}

func openHostRotationPrivateRoot(workerDirectory, directory string, create bool) (*os.File, error) {
	if !filepath.IsAbs(workerDirectory) || filepath.Clean(workerDirectory) != workerDirectory ||
		directory == "" || directory == "." || directory == ".." || filepath.Base(directory) != directory {
		return nil, errors.New("invalid capsule state directory")
	}
	openDir := func(parent int, name string) (*os.File, error) {
		fd, err := unix.Openat(parent, name, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
		if err != nil {
			return nil, err
		}
		file := os.NewFile(uintptr(fd), name)
		var st unix.Stat_t
		if err := unix.Fstat(fd, &st); err != nil || st.Uid != uint32(os.Getuid()) || st.Mode&0o077 != 0 {
			file.Close()
			return nil, errors.New("capsule directory is not private")
		}
		return file, nil
	}
	worker, err := openDir(unix.AT_FDCWD, workerDirectory)
	if err != nil {
		return nil, err
	}
	defer worker.Close()
	if create {
		if err := unix.Mkdirat(int(worker.Fd()), directory, 0o700); err != nil && !errors.Is(err, unix.EEXIST) {
			return nil, err
		}
	}
	root, err := openDir(int(worker.Fd()), directory)
	if err != nil {
		return nil, err
	}
	if create {
		if err := worker.Sync(); err != nil {
			root.Close()
			return nil, err
		}
	}
	return root, nil
}

func readHostRotationCapsuleAt(ctx context.Context, root *os.File, receipt hostRotationCapsuleReceipt, source hostRotationSource) (string, error) {
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if !hostRotationCapsuleDigest(receipt.ArtifactID) || !hostRotationCapsuleDigest(receipt.SHA256) ||
		receipt.Bytes <= 0 || receipt.Bytes > 16384 {
		return "", errors.New("invalid capsule storage receipt")
	}
	binding, err := hostRotationCapsuleSource(source)
	if err != nil {
		return "", err
	}
	fd, err := unix.Openat(int(root.Fd()), receipt.ArtifactID+".json",
		unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return "", err
	}
	file := os.NewFile(uintptr(fd), receipt.ArtifactID)
	defer file.Close()
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil || st.Uid != uint32(os.Getuid()) || st.Mode&unix.S_IFMT != unix.S_IFREG ||
		st.Mode&0o077 != 0 || st.Nlink != 1 || st.Size <= 0 || st.Size > hostRotationCapsuleLimit {
		return "", errors.New("capsule record is not a bounded private file")
	}
	before, err := file.Stat()
	if err != nil {
		return "", err
	}
	data, err := io.ReadAll(io.LimitReader(file, hostRotationCapsuleLimit+1))
	if err != nil {
		return "", err
	}
	after, err := file.Stat()
	if err != nil || !sameRotationSourceFile(before, after) || len(data) > hostRotationCapsuleLimit ||
		hostRotationCapsuleHash(data) != receipt.ArtifactID || !rotationSourceJSONUnambiguous(data) {
		return "", errors.New("capsule record changed or is incomplete")
	}
	var record hostRotationCapsuleRecord
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&record) != nil || record.Version != 1 || record.Source != binding ||
		record.SHA256 != receipt.SHA256 || record.Bytes != receipt.Bytes ||
		len(record.Body) != receipt.Bytes || hostRotationCapsuleHash([]byte(record.Body)) != receipt.SHA256 {
		return "", errors.New("capsule record binding mismatch")
	}
	var draft hostRotationDraft
	decoder = json.NewDecoder(strings.NewReader(record.Body))
	decoder.DisallowUnknownFields()
	if !rotationSourceJSONUnambiguous([]byte(record.Body)) || decoder.Decode(&draft) != nil ||
		validateHostRotationDraft(draft) != nil {
		return "", errors.New("invalid stored capsule body")
	}
	// A complete record left by a lost response is safe to reuse for staging.
	// Sync it again before acknowledging durability; staging grants no claim.
	if err := file.Sync(); err != nil {
		return "", err
	}
	if err := root.Sync(); err != nil {
		return "", err
	}
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	return record.Body, nil
}

func readHostRotationCapsule(ctx context.Context, workerDirectory string, receipt hostRotationCapsuleReceipt, source hostRotationSource) (string, error) {
	root, err := openHostRotationCapsuleRoot(workerDirectory, false)
	if err != nil {
		return "", err
	}
	defer root.Close()
	return readHostRotationCapsuleAt(ctx, root, receipt, source)
}

func stageHostRotationCapsule(ctx context.Context, workerDirectory string, source hostRotationSource, draft hostRotationDraft) (*hostRotationCapsuleReceipt, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	data, receipt, err := encodeHostRotationCapsule(source, draft)
	if err != nil {
		return nil, err
	}
	root, err := openHostRotationCapsuleRoot(workerDirectory, true)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	fd, err := unix.Openat(int(root.Fd()), receipt.ArtifactID+".json",
		unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0o600)
	if err == nil {
		file := os.NewFile(uintptr(fd), receipt.ArtifactID)
		_, writeErr := file.Write(data)
		if writeErr == nil {
			writeErr = file.Sync()
		}
		closeErr := file.Close()
		// Never delete or overwrite an uncertain or partial artifact.
		if writeErr != nil {
			return nil, writeErr
		}
		if closeErr != nil {
			return nil, closeErr
		}
		if err := root.Sync(); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, unix.EEXIST) {
		return nil, err
	}
	if _, err := readHostRotationCapsuleAt(ctx, root, receipt, source); err != nil {
		return nil, err
	}
	return &receipt, nil
}

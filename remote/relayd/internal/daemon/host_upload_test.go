package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
)

func uploadTestBegin(t *testing.T, server *Server, directory string, data []byte) hostRequest {
	t.Helper()
	sum := sha256.Sum256(data)
	r := hostRequest{Operation: "file_upload_begin", JobID: "upload-proof", UploadPane: "pane-proof", Path: directory, UploadName: "proof.txt", UploadSize: int64(len(data)), UploadSHA256: hex.EncodeToString(sum[:])}
	if _, err := server.hostUploadRPC(r); err != nil {
		t.Fatal(err)
	}
	return r
}

func TestHostUploadRestartChunksAndCollision(t *testing.T) {
	root, destination := t.TempDir(), t.TempDir()
	s := &Server{stateDir: root}
	data := []byte("durable chunk upload")
	r := uploadTestBegin(t, s, destination, data)
	r.Operation, r.Data = "file_upload_chunk", data[:8]
	if _, err := s.hostUploadRPC(r); err != nil {
		t.Fatal(err)
	}
	// Separate executable reads the checkpoint and writes the remaining bytes.
	cmd := exec.Command(os.Args[0], "-test.run=^TestHostUploadChildProcess$")
	cmd.Env = append(os.Environ(), "RELAY_UPLOAD_TEST_ROOT="+root)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("child %v: %s", err, output)
	}
	r.Operation = "file_upload_status"
	result, err := (&Server{stateDir: root}).hostUploadRPC(r)
	if err != nil || result.(uploadRecord).Offset != int64(len(data)) {
		t.Fatalf("status %v %v", result, err)
	}
	if err := os.WriteFile(filepath.Join(destination, "proof.txt"), []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	r.Operation = "file_upload_commit"
	result, err = s.hostUploadRPC(r)
	if err != nil {
		t.Fatal(err)
	}
	receipt := result.(uploadRecord)
	if receipt.State != "committed" || receipt.Destination != filepath.Join(receipt.Directory, "proof (1).txt") {
		t.Fatalf("receipt %+v", receipt)
	}
	for i := 0; i < 2; i++ {
		if _, err := (&Server{stateDir: root}).hostUploadRPC(r); err != nil {
			t.Fatal(err)
		}
	}
	actual, err := os.ReadFile(receipt.Destination)
	if err != nil || string(actual) != string(data) {
		t.Fatalf("bytes %q %v", actual, err)
	}
	old, _ := os.ReadFile(filepath.Join(destination, "proof.txt"))
	if string(old) != "original" {
		t.Fatal("collision overwrote original")
	}
	entries, _ := os.ReadDir(destination)
	if len(entries) != 2 {
		t.Fatalf("duplicate publication: %v", entries)
	}
}

func TestHostUploadChildProcess(t *testing.T) {
	root := os.Getenv("RELAY_UPLOAD_TEST_ROOT")
	if root == "" {
		t.Skip("subprocess only")
	}
	s := &Server{stateDir: root}
	r := hostRequest{JobID: "upload-proof", Operation: "file_upload_chunk", Offset: 8, Data: []byte("durable chunk upload")[8:]}
	if _, err := s.hostUploadRPC(r); err != nil {
		t.Fatal(err)
	}
}

func TestHostUploadReplayCorruptionAndCancel(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	r := uploadTestBegin(t, s, t.TempDir(), []byte("abcdef"))
	r.Operation, r.Data = "file_upload_chunk", []byte("abc")
	result, err := s.hostUploadRPC(r)
	if err != nil {
		t.Fatal(err)
	}
	record := result.(uploadRecord)
	if _, err := s.hostUploadRPC(r); err != nil {
		t.Fatal(err)
	}
	r.Data = []byte("xyz")
	if _, err := s.hostUploadRPC(r); err == nil {
		t.Fatal("mismatched replay accepted")
	}
	f, err := os.OpenFile(record.Stage, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("uncommitted tail")
	f.Close()
	r.Operation = "file_upload_status"
	if _, err := s.hostUploadRPC(r); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(record.Stage)
	if info.Size() != 3 {
		t.Fatal("uncommitted tail retained")
	}
	r.Operation = "file_upload_cancel"
	if _, err := s.hostUploadRPC(r); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(record.Stage); !os.IsNotExist(err) {
		t.Fatal("cancel stage remains")
	}
	if _, err := s.hostUploadRPC(r); err != nil {
		t.Fatal(err)
	}
}

func TestHostUploadRecoverCommitExactInode(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	r := uploadTestBegin(t, s, t.TempDir(), []byte("complete"))
	r.Operation, r.Data = "file_upload_chunk", []byte("complete")
	result, err := s.hostUploadRPC(r)
	if err != nil {
		t.Fatal(err)
	}
	record := result.(uploadRecord)
	record.State, record.Destination = "committing", filepath.Join(record.Directory, record.Name)
	if err := saveUpload(filepath.Join(s.stateDir, "host-uploads"), record); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(record.Stage, record.Destination); err != nil {
		t.Fatal(err)
	}
	r.Operation = "file_upload_status"
	result, err = (&Server{stateDir: s.stateDir}).hostUploadRPC(r)
	if err != nil || result.(uploadRecord).State != "committed" {
		t.Fatalf("recovery %v %v", result, err)
	}
}

func TestHostUploadUnknownCommitCannotSelectAnotherName(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	r := uploadTestBegin(t, s, t.TempDir(), []byte("complete"))
	r.Operation, r.Data = "file_upload_chunk", []byte("complete")
	result, err := s.hostUploadRPC(r)
	if err != nil {
		t.Fatal(err)
	}
	record := result.(uploadRecord)
	record.State, record.Destination = "committing", filepath.Join(record.Directory, record.Name)
	if err := saveUpload(filepath.Join(s.stateDir, "host-uploads"), record); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(record.Destination, []byte("foreign"), 0600); err != nil {
		t.Fatal(err)
	}
	r.Operation = "file_upload_commit"
	if _, err := s.hostUploadRPC(r); err == nil {
		t.Fatal("unknown commit replayed")
	}
	entries, _ := os.ReadDir(record.Directory)
	if len(entries) != 2 {
		t.Fatal("unknown commit generated another destination")
	}
}

func TestHostUploadLockBindingAndCorruption(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	r := uploadTestBegin(t, s, t.TempDir(), []byte("abcdef"))
	changed := r
	changed.UploadName = "other.txt"
	if _, err := s.hostUploadRPC(changed); err == nil {
		t.Fatal("changed binding accepted")
	}
	root := filepath.Join(s.stateDir, "host-uploads")
	lock, err := OpenPrivateFile(filepath.Join(root, r.JobID+".lock"), os.O_RDWR)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	r.Operation = "file_upload_status"
	if _, err := s.hostUploadRPC(r); err == nil {
		t.Fatal("concurrent owner accepted")
	}
	lock.Close()
	r.Operation, r.Data = "file_upload_chunk", []byte("abc")
	result, err := s.hostUploadRPC(r)
	if err != nil {
		t.Fatal(err)
	}
	record := result.(uploadRecord)
	if err := os.WriteFile(record.Stage, []byte("xyz"), 0600); err != nil {
		t.Fatal(err)
	}
	r.Operation = "file_upload_status"
	if _, err := s.hostUploadRPC(r); err == nil {
		t.Fatal("corrupt durable bytes accepted")
	}
}

func TestHostUploadRejectSymlinkAndMissingParent(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	sum := sha256.Sum256(nil)
	r := hostRequest{Operation: "file_upload_begin", JobID: "upload-proof", UploadPane: "absent-pane", UploadName: "proof.txt", UploadSHA256: hex.EncodeToString(sum[:])}
	if _, err := s.hostUploadRPC(r); err == nil {
		t.Fatal("missing parent fell back to home")
	}
	root := filepath.Join(s.stateDir, "host-uploads")
	if err := os.Symlink(filepath.Join(t.TempDir(), "missing"), filepath.Join(root, r.JobID+".json")); err != nil {
		t.Fatal(err)
	}
	r.Path = t.TempDir()
	if _, err := s.hostUploadRPC(r); err == nil {
		t.Fatal("symlink checkpoint accepted")
	}
}

func TestHostUploadCancelUnseenIDPreventsDelayedBegin(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	r := hostRequest{Operation: "file_upload_cancel", JobID: "upload-proof"}
	result, err := s.hostUploadRPC(r)
	if err != nil || result.(uploadRecord).State != "cancelled" {
		t.Fatalf("cancel %v %v", result, err)
	}
	empty := sha256.Sum256(nil)
	r.Operation, r.UploadPane, r.UploadName, r.Path, r.UploadSHA256 = "file_upload_begin", "pane-proof", "late.txt", t.TempDir(), hex.EncodeToString(empty[:])
	if _, err := (&Server{stateDir: s.stateDir}).hostUploadRPC(r); err == nil {
		t.Fatal("delayed begin recreated cancelled upload")
	}
}

func TestHostUploadFirstBootstrapWithoutPTY(t *testing.T) {
	s := &Server{stateDir: filepath.Join(t.TempDir(), "fresh-state", "relay", "workers")}
	r := uploadTestBegin(t, s, t.TempDir(), nil)
	r.Operation = "file_upload_cancel"
	if _, err := s.hostUploadRPC(r); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{s.stateDir, filepath.Join(s.stateDir, "host-uploads")} {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != 0700 {
			t.Fatalf("private bootstrap %s %v", path, err)
		}
	}

	state := filepath.Join(t.TempDir(), "workers")
	target := t.TempDir()
	if err := os.Symlink(target, state); err != nil {
		t.Fatal(err)
	}
	if _, err := (&Server{stateDir: state}).hostUploadRPC(r); err == nil {
		t.Fatal("symlink catalog accepted")
	}
	entries, err := os.ReadDir(target)
	if err != nil || len(entries) != 0 {
		t.Fatal("symlink target mutated")
	}
}

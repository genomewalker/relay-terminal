package daemon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestHostFolderRPCSeparateProcessResumeAndCommit(t *testing.T) {
	base := t.TempDir()
	state, parent := filepath.Join(base, "state"), filepath.Join(base, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	canonicalParent, err := filepath.EvalSymlinks(parent)
	if err != nil {
		t.Fatal(err)
	}
	data := []byte("host folder durable restart bytes")
	sum := sha256.Sum256(data)
	s := &Server{stateDir: state}
	r := hostRequest{RequestID: "request-proof", Operation: "file_folder_begin", JobID: "rpc-folder-proof", UploadPane: "pane-proof", Path: parent, UploadName: "original-tree", FolderSourceVersion: strings.Repeat("a", 64), FolderManifest: []folderEntry{{Path: "nested", Kind: "directory"}, {Path: "empty", Kind: "directory"}, {Path: "nested/exact.txt", Kind: "file", Size: int64(len(data)), SHA256: hex.EncodeToString(sum[:])}}}
	result, err := s.hostRPC(r)
	if err != nil {
		t.Fatal(err)
	}
	status := result.(folderGroupStatus)
	if status.Path != filepath.Join(canonicalParent, "original-tree") || status.State != "receiving" || status.Fingerprint == "" {
		t.Fatal("begin binding missing")
	}
	r.Operation, r.FolderChild, r.Data = "file_folder_chunk", "nested/exact.txt", data[:8]
	result, err = s.hostRPC(r)
	if err != nil || result.(folderGroupStatus).Child.Offset != 8 {
		t.Fatal("durable child acknowledgement missing", err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestHostFolderRPCChildProcess$")
	cmd.Env = append(os.Environ(), "RELAY_FOLDER_RPC_TEST_STATE="+state)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("separate process resume %v: %s", err, output)
	}
	s = &Server{stateDir: state}
	r.Operation, r.Data = "file_folder_status", nil
	result, err = s.hostRPC(r)
	if err != nil {
		t.Fatal(err)
	}
	status = result.(folderGroupStatus)
	if status.Child.State != "committed" || status.Child.Offset != int64(len(data)) || status.Child.PrefixSHA256 != hex.EncodeToString(sum[:]) {
		t.Fatal("resumed child receipt differs")
	}
	wire, err := json.Marshal(status)
	if err != nil || strings.Contains(string(wire), "nonce") || strings.Contains(string(wire), "stage") || strings.Contains(string(wire), "identity") {
		t.Fatal("private journal metadata in RPC status")
	}
	r.Operation, r.FolderChild = "file_folder_commit", ""
	for i := 0; i < 2; i++ {
		if _, err := s.hostRPC(r); err != nil {
			t.Fatal("group commit repeat failed", err)
		}
	}
	r.Operation = "file_folder_cancel"
	result, err = s.hostRPC(r)
	if err != nil || result.(folderGroupStatus).State != "committed" {
		t.Fatal("cancel changed committed group", err)
	}
	r.Operation, r.FolderChild = "file_folder_file_commit", "nested/exact.txt"
	if _, err := s.hostRPC(r); err != nil {
		t.Fatal("committed child repeat failed", err)
	}
	actual, err := os.ReadFile(filepath.Join(parent, "original-tree", "nested", "exact.txt"))
	if err != nil || !bytes.Equal(actual, data) {
		t.Fatal("RPC published bytes differ")
	}
	if info, err := os.Stat(filepath.Join(parent, "original-tree", "empty")); err != nil || !info.IsDir() {
		t.Fatal("empty directory missing")
	}
	r.Operation, r.FolderChild = "file_folder_cleanup", ""
	if _, err := s.hostRPC(r); err != nil {
		t.Fatal("terminal staging cleanup failed", err)
	}
	stagePath := filepath.Join(parent, folderStagingName(r.JobID))
	if _, err := os.Lstat(stagePath); !os.IsNotExist(err) {
		t.Fatal("terminal staging retained")
	}
	actual, err = os.ReadFile(filepath.Join(parent, "original-tree", "nested", "exact.txt"))
	if err != nil || !bytes.Equal(actual, data) {
		t.Fatal("cleanup deleted published bytes")
	}
	if err := os.WriteFile(stagePath, []byte("unrelated replacement"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.hostRPC(r); err != nil {
		t.Fatal("repeat cleanup failed", err)
	}
	actual, err = os.ReadFile(stagePath)
	if err != nil || string(actual) != "unrelated replacement" {
		t.Fatal("repeat cleanup touched replacement")
	}
}

func TestHostFolderRPCFramedWire(t *testing.T) {
	s := &Server{stateDir: filepath.Join(t.TempDir(), "state")}
	r := hostRequest{RequestID: "frame-proof", Operation: "file_folder_begin", JobID: "frame-folder-proof", UploadPane: "pane-proof", Path: t.TempDir(), UploadName: "wire-tree", FolderSourceVersion: strings.Repeat("a", 64)}
	frame, err := protocol.JSONFrame(protocol.HostRequest, r)
	if err != nil {
		t.Fatal(err)
	}
	var wire bytes.Buffer
	s.serveHostRPC(protocol.NewWriter(&wire), frame)
	answer, err := protocol.ReadFrame(&wire)
	if err != nil || answer.Type != protocol.HostResponse {
		t.Fatal("host response frame missing", err)
	}
	var response struct {
		RequestID string            `json:"request_id"`
		Result    folderGroupStatus `json:"result"`
		Error     string            `json:"error"`
	}
	if err := json.Unmarshal(answer.Payload, &response); err != nil {
		t.Fatal(err)
	}
	if response.Error != "" || response.RequestID != r.RequestID || response.Result.State != "receiving" || response.Result.SourceVersion != r.FolderSourceVersion {
		t.Fatal("framed folder response differs", response.Error)
	}
	if bytes.Contains(answer.Payload, []byte("nonce")) || bytes.Contains(answer.Payload, []byte("stage")) {
		t.Fatal("private metadata serialized on transport")
	}
}

func TestHostFolderRPCChildProcess(t *testing.T) {
	state := os.Getenv("RELAY_FOLDER_RPC_TEST_STATE")
	if state == "" {
		t.Skip("private child process fixture")
	}
	s := &Server{stateDir: state}
	r := hostRequest{RequestID: "child-proof", JobID: "rpc-folder-proof", Operation: "file_folder_status", FolderChild: "nested/exact.txt"}
	result, err := s.hostRPC(r)
	if err != nil || result.(folderGroupStatus).Child.Offset != 8 {
		t.Fatal("child process checkpoint missing", err)
	}
	data := []byte("host folder durable restart bytes")
	r.Operation, r.Offset, r.Data = "file_folder_chunk", 8, data[8:]
	if _, err := s.hostRPC(r); err != nil {
		t.Fatal(err)
	}
	r.Operation, r.Data = "file_folder_file_commit", nil
	if _, err := s.hostRPC(r); err != nil {
		t.Fatal(err)
	}
}

func TestHostFolderRPCStatusAndCancellationValidation(t *testing.T) {
	s := &Server{stateDir: filepath.Join(t.TempDir(), "state")}
	r := hostRequest{RequestID: "request-proof", JobID: "unseen-proof", Operation: "file_folder_status"}
	if _, err := s.hostRPC(r); err == nil {
		t.Fatal("missing group status accepted")
	}
	r.Operation, r.FolderChild = "file_folder_cancel", "invalid-child"
	if _, err := s.hostRPC(r); err == nil {
		t.Fatal("invalid child field accepted for cancel")
	}
	r.FolderChild = ""
	if _, err := s.hostRPC(r); err != nil {
		t.Fatal(err)
	}
	r.Operation, r.Path, r.UploadPane, r.UploadName, r.FolderSourceVersion = "file_folder_begin", t.TempDir(), "pane-proof", "must-not-create", strings.Repeat("a", 64)
	if _, err := s.hostRPC(r); err == nil {
		t.Fatal("delayed begin resurrected cancelled group")
	}
	if _, err := os.Stat(filepath.Join(r.Path, r.UploadName)); !os.IsNotExist(err) {
		t.Fatal("cancelled group created directory")
	}
}

func TestHostFolderRPCCancelCleanupPreservesReservedTree(t *testing.T) {
	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	s := &Server{stateDir: filepath.Join(base, "state")}
	data := []byte("unfinished file")
	sum := sha256.Sum256(data)
	r := hostRequest{RequestID: "request-proof", JobID: "cancel-staging-proof", Operation: "file_folder_begin", UploadPane: "pane-proof", Path: parent, UploadName: "tree", FolderSourceVersion: strings.Repeat("a", 64), FolderManifest: []folderEntry{{Path: "file", Kind: "file", Size: int64(len(data)), SHA256: hex.EncodeToString(sum[:])}}}
	if _, err := s.hostRPC(r); err != nil {
		t.Fatal(err)
	}
	r.Operation, r.FolderChild, r.Data = "file_folder_chunk", "file", data[:4]
	if _, err := s.hostRPC(r); err != nil {
		t.Fatal(err)
	}
	r.Operation, r.FolderChild, r.Data = "file_folder_cancel", "", nil
	if _, err := s.hostRPC(r); err != nil {
		t.Fatal(err)
	}
	r.Operation = "file_folder_cleanup"
	if _, err := s.hostRPC(r); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(parent, "tree")); err != nil {
		t.Fatal("cancel cleanup removed reserved tree")
	}
	if _, err := os.Stat(filepath.Join(parent, "tree", "file")); !os.IsNotExist(err) {
		t.Fatal("cancel published incomplete file")
	}
	if _, err := os.Stat(filepath.Join(parent, folderStagingName(r.JobID))); !os.IsNotExist(err) {
		t.Fatal("cancel staging retained")
	}
}

func TestFolderGroupCleanupStopsAtUnknownMarker(t *testing.T) {
	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	g, err := lockFolderGroup(filepath.Join(base, "state"), "unknown-cleanup-proof")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	if err := g.begin("pane-proof", strings.Repeat("a", 64), parent, "tree", nil); err != nil {
		t.Fatal(err)
	}
	stage, err := g.openStagingDirectory()
	if err != nil {
		t.Fatal(err)
	}
	stage.Close()
	if err := g.cancel(); err != nil {
		t.Fatal(err)
	}
	if err := saveFolderCleanup(g.root, folderCleanupRecord{Format: 1, ID: g.record.ID, Fingerprint: g.record.Fingerprint, StageIdentity: g.record.Staging.Identity, State: "removing"}); err != nil {
		t.Fatal(err)
	}
	stagePath := filepath.Join(parent, g.record.Staging.Name)
	if err := os.Remove(filepath.Join(stagePath, folderOwnerMarker)); err != nil {
		t.Fatal(err)
	}
	if err := g.cleanupStaging(); err == nil {
		t.Fatal("unknown markerless directory removed")
	}
	if _, err := os.Stat(stagePath); err != nil {
		t.Fatal("unknown directory not preserved")
	}
}

func TestHostFolderRPCDestinationUsesLiveDirectory(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	start, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	boot, err := nodeBootID()
	if err != nil {
		t.Fatal(err)
	}
	manifest := workerManifest{Version: workerProtocolVersion, SessionID: "live-cwd-proof", WorkerPID: os.Getpid(), WorkerStartTime: start, NodeBootID: boot, ShellPID: os.Getpid(), WorkingDirectory: "/must-not-use-stale-metadata"}
	path := s.manifestPath(manifest.SessionID)
	if err := storeManifest(path, manifest); err != nil {
		t.Fatal(err)
	}
	request := hostRequest{RequestID: "live-cwd-request", Operation: "file_folder_destination", UploadPane: manifest.SessionID}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	result, err := s.hostRPC(request)
	if err != nil {
		t.Fatal(err)
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	cwd, err = filepath.EvalSymlinks(cwd)
	if err != nil {
		t.Fatal(err)
	}
	destination, ok := result.(map[string]any)
	if !ok || destination["path"] != cwd || destination["pane"] != manifest.SessionID {
		t.Fatalf("wrong live destination: %+v", result)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("read-only lookup changed manifest")
	}
	manifest.WorkerStartTime++
	if err := storeManifest(path, manifest); err != nil {
		t.Fatal(err)
	}
	if _, err := s.hostRPC(request); err == nil {
		t.Fatal("accepted wrong worker incarnation")
	}
	manifest.WorkerStartTime = start
	manifest.SessionID = "different-pane"
	if err := storeManifest(path, manifest); err != nil {
		t.Fatal(err)
	}
	if _, err := s.hostRPC(request); err == nil {
		t.Fatal("accepted different pane manifest")
	}
}

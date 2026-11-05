package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

// Relay's remote install checks the folder relayd resolves when an upload
// begins and the committed path, and installs from that path. This pins the
// receipts it relies on: a pane-free upload names its resolved folder at
// begin, and a colliding name commits beside the old file under another name.
func TestRemoteInstallPaneFreeUploadAndCollisionReceipt(t *testing.T) {
	for _, collision := range []bool{false, true} {
		label := "fresh"
		if collision {
			label = "collision"
		}
		t.Run(label, func(t *testing.T) {
			s := &Server{stateDir: t.TempDir()}
			destination := t.TempDir()
			canonical, err := filepath.EvalSymlinks(destination)
			if err != nil {
				t.Fatal(err)
			}
			const name = ".relayd-install-install-reviewer"
			requested := filepath.Join(canonical, name)
			if collision {
				if err := os.WriteFile(requested, []byte("previous staging bytes"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			data := []byte("new staged bytes")
			sum := sha256.Sum256(data)
			r := hostRequest{Operation: "file_upload_begin", JobID: "remote-install-pane-free-" + label,
				UploadPane: "host", Path: destination, UploadName: name, UploadSize: int64(len(data)),
				UploadSHA256: hex.EncodeToString(sum[:])}
			begun, err := s.hostUploadRPC(r)
			if err != nil {
				t.Fatalf("pane-free begin: %v", err)
			}
			if record := begun.(uploadRecord); record.State != "receiving" || record.Directory != canonical {
				t.Fatalf("begin receipt %+v does not name %s", record, canonical)
			}
			r.Operation, r.Offset, r.Data = "file_upload_chunk", 0, data
			if _, err := s.hostUploadRPC(r); err != nil {
				t.Fatal(err)
			}
			r.Operation = "file_upload_commit"
			got, err := s.hostUploadRPC(r)
			if err != nil {
				t.Fatal(err)
			}
			receipt := got.(uploadRecord)
			if receipt.State != "committed" || receipt.SHA256 != r.UploadSHA256 || receipt.Directory != canonical ||
				filepath.Dir(receipt.Destination) != canonical {
				t.Fatalf("receipt %+v", receipt)
			}
			if collision {
				if filepath.Base(receipt.Destination) != " (1)"+name {
					t.Fatalf("collision committed %q, not the stem (N)ext name Relay expects", receipt.Destination)
				}
				old, err := os.ReadFile(requested)
				if err != nil || string(old) != "previous staging bytes" {
					t.Fatalf("collision overwrote existing stage: %q %v", old, err)
				}
			} else if receipt.Destination != requested {
				t.Fatalf("unexpected committed destination %q", receipt.Destination)
			}
			uploaded, err := os.ReadFile(receipt.Destination)
			if err != nil || string(uploaded) != string(data) {
				t.Fatalf("bytes %q %v", uploaded, err)
			}
		})
	}
}

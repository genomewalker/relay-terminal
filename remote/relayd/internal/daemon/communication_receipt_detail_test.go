package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPaneReceiptExplainsPersistedDeliveryEvidence(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	root := communicationRoot()
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	id := "5e0b6a12-3c4d-4e8f-9a1b-2c3d4e5f6071"
	for _, status := range []string{"written_to_socket", "accepted_by_provider", "turn_completed"} {
		stored := communicationReceipt{Result: map[string]any{"message_id": id, "status": status, "replay_permitted": false}}
		if err := communicationAtomic(filepath.Join(root, "message-"+id+".json"), stored); err != nil {
			t.Fatal(err)
		}
		got, err := ExecuteCommunication(CommunicationRequest{Operation: "receipt", MessageID: id})
		if err != nil || got["status"] != status || got["replay_permitted"] != false {
			t.Fatalf("receipt for %s: %v, %v", status, got, err)
		}
		note, _ := got["receipt_detail"].(string)
		if (note != "") != (status != "turn_completed") {
			t.Fatalf("unexpected detail for %s: %q", status, note)
		}
	}
}

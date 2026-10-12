package daemon

import (
	"bytes"
	"crypto/sha256"
	"strings"
	"testing"
)

func promptEditorTestOwner() PromptOwnerBinding {
	return PromptOwnerBinding{Version: 1, PaneID: "owned-pane", NodeBootID: "boot", WorkerPID: 10,
		WorkerStart: 100, ShellPID: 11, ShellStart: 101, Provider: "claude", ProcessID: 12,
		ProcessStart: 102, SessionID: "session", TranscriptIdentity: "1:2"}
}

func TestPromptEditorTransactionExactDraftAndSingleDelivery(t *testing.T) {
	owner := promptEditorTestOwner()
	transaction, err := newPromptEditorTransaction(owner, func() (PromptOwnerBinding, error) { return owner, nil })
	if err != nil {
		t.Fatal(err)
	}
	original := []byte("Long  double   triple 🧬\nHard  line\n" + strings.Repeat("word  gap   ", 200))
	expected := bytes.Clone(original)
	if err := transaction.capture(owner, original); err != nil {
		t.Fatal(err)
	}
	original[0] = 'X'
	snapshot, digest, err := transaction.snapshot()
	if err != nil || !bytes.Equal(snapshot, expected) || digest != sha256.Sum256(expected) {
		t.Fatalf("exact capture lost: %v", err)
	}
	snapshot[0] = 'Y'
	replacement := []byte("漢字  exact 🧬\nNext   line")
	if err := transaction.commit(digest, replacement); err != nil {
		t.Fatal(err)
	}
	replacement[0] = 'Z'
	select {
	case <-transaction.completion():
	default:
		t.Fatal("completion not signalled")
	}
	result, err := transaction.completedResult()
	if err != nil || !result.Apply || string(result.Text) != "漢字  exact 🧬\nNext   line" {
		t.Fatalf("replacement changed: %v", err)
	}
	if _, err := transaction.completedResult(); err == nil {
		t.Fatal("duplicate delivery accepted")
	}
}

func TestPromptEditorTransactionRefusesChangedOwner(t *testing.T) {
	for _, phase := range []string{"capture", "snapshot", "commit", "delivery"} {
		t.Run(phase, func(t *testing.T) {
			owner := promptEditorTestOwner()
			current := owner
			transaction, err := newPromptEditorTransaction(owner, func() (PromptOwnerBinding, error) { return current, nil })
			if err != nil {
				t.Fatal(err)
			}
			if phase == "capture" {
				current.ProcessStart++
				if transaction.capture(owner, []byte("original")) == nil {
					t.Fatal("changed owner captured")
				}
			} else {
				if err := transaction.capture(owner, []byte("original")); err != nil {
					t.Fatal(err)
				}
				_, digest, err := transaction.snapshot()
				if err != nil {
					t.Fatal(err)
				}
				if phase == "delivery" {
					if err := transaction.commit(digest, []byte("replacement")); err != nil {
						t.Fatal(err)
					}
					current.WorkerStart++
					result, err := transaction.completedResult()
					if err == nil || result.Apply {
						t.Fatal("changed owner received replacement")
					}
					return
				}
				current.TranscriptIdentity = "1:3"
				if phase == "snapshot" {
					if _, _, err := transaction.snapshot(); err == nil {
						t.Fatal("changed owner read draft")
					}
				} else if transaction.commit(digest, []byte("replacement")) == nil {
					t.Fatal("changed owner edited")
				}
			}
			result, err := transaction.completedResult()
			if err != nil || result.Apply || len(result.Text) != 0 {
				t.Fatal("cancelled transaction requests file write")
			}
		})
	}
}

func TestPromptEditorTransactionValidationAndCancellation(t *testing.T) {
	owner := promptEditorTestOwner()
	transaction, err := newPromptEditorTransaction(owner, func() (PromptOwnerBinding, error) { return owner, nil })
	if err != nil {
		t.Fatal(err)
	}
	other := owner
	other.ProcessID++
	if transaction.capture(other, []byte("foreign")) == nil {
		t.Fatal("foreign capture accepted")
	}
	for _, invalid := range [][]byte{{0xff}, {'a', 0}, bytes.Repeat([]byte{'x'}, promptEditorDraftLimit+1)} {
		if transaction.capture(owner, invalid) == nil {
			t.Fatal("invalid draft accepted")
		}
	}
	if err := transaction.capture(owner, []byte("original")); err != nil {
		t.Fatal(err)
	}
	if transaction.capture(owner, []byte("again")) == nil {
		t.Fatal("duplicate capture accepted")
	}
	if transaction.commit(sha256.Sum256([]byte("different")), []byte("replacement")) == nil {
		t.Fatal("wrong draft digest accepted")
	}
	transaction.cancel()
	transaction.cancel()
	result, err := transaction.completedResult()
	if err != nil || result.Apply || result.Text != nil {
		t.Fatal("cancel requests file write")
	}
}

func TestPromptEditorApplicationReceiptRequiresExactDeliveredEdit(t *testing.T) {
	owner := promptEditorTestOwner()
	transaction, err := newPromptEditorTransaction(owner, func() (PromptOwnerBinding, error) { return owner, nil })
	if err != nil {
		t.Fatal(err)
	}
	if err := transaction.capture(owner, []byte("original")); err != nil {
		t.Fatal(err)
	}
	_, digest, _ := transaction.snapshot()
	replacement := []byte("漢字  exact 🧬\nNext line")
	if err := transaction.commit(digest, replacement); err != nil {
		t.Fatal(err)
	}
	if transaction.recordApplication(owner, sha256.Sum256(replacement), true) == nil {
		t.Fatal("undelivered edit acknowledged")
	}
	if _, err := transaction.completedResult(); err != nil {
		t.Fatal(err)
	}
	if transaction.recordApplication(owner, sha256.Sum256([]byte("wrong")), true) == nil {
		t.Fatal("wrong applied bytes acknowledged")
	}
	select {
	case <-transaction.appliedDone:
		t.Fatal("wrong digest completed receipt")
	default:
	}
	if err := transaction.recordApplication(owner, sha256.Sum256(replacement), true); err != nil {
		t.Fatal(err)
	}
	select {
	case <-transaction.appliedDone:
	default:
		t.Fatal("receipt event missing")
	}
	state, observed := transaction.applicationReceipt()
	if state != "applied" || observed != sha256.Sum256(replacement) {
		t.Fatal("receipt lost exact digest")
	}
	if transaction.recordApplication(owner, sha256.Sum256(replacement), true) == nil {
		t.Fatal("duplicate receipt accepted")
	}
}

func TestPromptEditorApplicationFailureAndCancellation(t *testing.T) {
	for _, phase := range []string{"cancel", "failed", "owner_changed"} {
		t.Run(phase, func(t *testing.T) {
			owner := promptEditorTestOwner()
			current := owner
			transaction, err := newPromptEditorTransaction(owner, func() (PromptOwnerBinding, error) { return current, nil })
			if err != nil {
				t.Fatal(err)
			}
			if phase == "cancel" {
				transaction.cancel()
			} else {
				_ = transaction.capture(owner, []byte("original"))
				_, digest, _ := transaction.snapshot()
				_ = transaction.commit(digest, []byte("replacement"))
				_, _ = transaction.completedResult()
				if phase == "owner_changed" {
					current.ProcessStart++
				}
				err = transaction.recordApplication(owner, sha256.Sum256([]byte("replacement")), phase == "owner_changed")
				if phase == "owner_changed" && err == nil {
					t.Fatal("changed owner reported application")
				}
			}
			select {
			case <-transaction.appliedDone:
			default:
				t.Fatal("failure/cancel receipt not signalled")
			}
			state, _ := transaction.applicationReceipt()
			if state == "applied" {
				t.Fatal("failed edit reported applied")
			}
		})
	}
}

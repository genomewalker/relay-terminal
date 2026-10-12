package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type nativeCompletionHarness struct {
	host    *nativeClaimHarness
	claim   *hostNativeRotationClaim
	receipt nativeRotationCompletion
}

func nativeCompletionFixture(t *testing.T) *nativeCompletionHarness {
	t.Helper()
	h, c, _ := nativeCommitFixture(t)
	if _, err := c.requestCommitIntent(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := c.handoffNativeCommit(context.Background(), func(context.Context, *hostNativeRotationLease, hostNativeCommitEnvelope) error { return nil }); err != nil {
		t.Fatal(err)
	}
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	receipt := nativeRotationCompletion{OperationID: c.request.Epoch, HostClaimID: c.request.HostClaimID,
		Source: nativeWireSource(c.lease.native), TargetThreadID: "00000000-0000-0000-0000-000000000803",
		TargetRuntimeID: "00000000-0000-0000-0000-000000000804", TargetRolloutPath: filepath.Join(home, "target.jsonl"),
		CapsuleSHA256: c.request.Capsule.SHA256, SettingsSHA256: strings.Repeat("b", 64),
		ProcessID: uint32(h.source.Enrollment.AgentPID), JournalDirectory: filepath.Join(home, "relay-context-rotation", c.request.Epoch)}
	if err := os.MkdirAll(receipt.JournalDirectory, 0700); err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"intent", "sealed", "closed", "restored"} {
		writeNativeCompletionJSON(t, filepath.Join(receipt.JournalDirectory, state+".json"), expectedHostNativeJournalRecord(receipt, state))
	}
	return &nativeCompletionHarness{h, c, receipt}
}
func writeNativeCompletionJSON(t *testing.T, path string, value any) {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(raw, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
}
func (h *nativeCompletionHarness) verify(e hostRotationEnrollment, r nativeRotationCompletion) error {
	if e != h.host.source.Enrollment || r.ProcessID != uint32(e.AgentPID) {
		return errors.New("fixture owner changed")
	}
	return nil
}
func (h *nativeCompletionHarness) record(ctx context.Context, owner func(hostRotationEnrollment, nativeRotationCompletion) error) (*hostNativeCompletionProof, error) {
	return verifyAndRecordHostNativeCompletion(ctx, h.host.dir, h.claim.request.SessionID, h.receipt, owner)
}
func (h *nativeCompletionHarness) proofPath() string {
	return filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.Epoch+".native_restored_verified.json")
}
func (h *nativeCompletionHarness) unchangedFence(t *testing.T) {
	t.Helper()
	nativeCommitFence(t, h.host, h.claim)
}

func TestHostNativeCompletionVerifiesAndPersistsWithoutFinishingTransaction(t *testing.T) {
	h := nativeCompletionFixture(t)
	for i := 0; i < 2; i++ {
		proof, err := h.record(context.Background(), h.verify)
		if err != nil || proof == nil {
			t.Fatal(err)
		}
		if proof.State != "native_restored_verified" || proof.Receipt != h.receipt || len(proof.NativeRecords) != 4 ||
			!nativeWireHash(proof.JournalSHA256) || !nativeWireHash(proof.HostSnapshotSHA256) {
			t.Fatal("incomplete proof")
		}
		raw, err := os.ReadFile(h.proofPath())
		var saved hostNativeCompletionProof
		if err != nil || decodeHostNativeRecord(raw, &saved) != nil || saved.Receipt != proof.Receipt || saved.JournalSHA256 != proof.JournalSHA256 {
			t.Fatal("durable proof changed")
		}
	}
	h.unchangedFence(t)
}
func TestHostNativeCompletionRecoveryAfterHistoricalLeaseExpiry(t *testing.T) {
	h := nativeCompletionFixture(t)
	expired := time.Now().Add(-time.Hour).UnixMilli()
	for _, state := range []string{"claim_received", "commit_requested"} {
		path := filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.Epoch+"."+state+".json")
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var phase hostNativeClaimPhase
		if decodeHostNativeRecord(raw, &phase) != nil {
			t.Fatal("phase")
		}
		phase.Claim.ExpiresAtMS = expired
		writeNativeCompletionJSON(t, path, phase)
	}
	if _, err := h.record(context.Background(), h.verify); err != nil {
		t.Fatal("historical completion required a recreated live lease", err)
	}
	h.unchangedFence(t)
}
func TestHostNativeCompletionRejectsInvalidNativeJournals(t *testing.T) {
	cases := []string{"missing_intent", "missing_sealed", "missing_closed", "missing_restored", "wrong_claim", "wrong_source", "wrong_target",
		"wrong_settings", "wrong_capsule", "wrong_process", "unknown_field", "missing_field", "partial", "oversized", "conflicting_phase",
		"symlink_file", "hardlink_file", "public_file", "public_root", "symlink_operation", "symlink_root", "wrong_operation_path"}
	for _, name := range cases {
		t.Run(name, func(t *testing.T) {
			h := nativeCompletionFixture(t)
			path := filepath.Join(h.receipt.JournalDirectory, "restored.json")
			record := expectedHostNativeJournalRecord(h.receipt, "restored")
			switch name {
			case "missing_intent", "missing_sealed", "missing_closed", "missing_restored":
				if err := os.Remove(filepath.Join(h.receipt.JournalDirectory, strings.TrimPrefix(name, "missing_")+".json")); err != nil {
					t.Fatal(err)
				}
			case "wrong_claim":
				record.ClaimID = record.OperationID
				writeNativeCompletionJSON(t, path, record)
			case "wrong_source":
				record.Source.AdmissionGeneration++
				writeNativeCompletionJSON(t, path, record)
			case "wrong_target":
				record.Restored.ThreadID = record.Source.ThreadID
				writeNativeCompletionJSON(t, path, record)
			case "wrong_settings":
				record.Restored.SettingsSHA256 = strings.Repeat("c", 64)
				writeNativeCompletionJSON(t, path, record)
			case "wrong_capsule":
				record.CapsuleSHA256 = strings.Repeat("c", 64)
				writeNativeCompletionJSON(t, path, record)
			case "wrong_process":
				record.Restored.ProcessID++
				writeNativeCompletionJSON(t, path, record)
			case "unknown_field", "missing_field":
				raw, _ := json.Marshal(record)
				var value map[string]any
				_ = json.Unmarshal(raw, &value)
				if name == "unknown_field" {
					value["future"] = true
				} else {
					delete(value, "source")
				}
				writeNativeCompletionJSON(t, path, value)
			case "partial":
				if err := os.WriteFile(path, []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "oversized":
				if err := os.WriteFile(path, []byte(strings.Repeat(" ", hostNativeClaimRecordLimit+1)), 0600); err != nil {
					t.Fatal(err)
				}
			case "conflicting_phase":
				writeNativeCompletionJSON(t, filepath.Join(h.receipt.JournalDirectory, "aborted.json"), expectedHostNativeJournalRecord(h.receipt, "aborted"))
			case "symlink_file", "hardlink_file":
				target := filepath.Join(t.TempDir(), "copied.json")
				raw, _ := os.ReadFile(path)
				if err := os.WriteFile(target, raw, 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				var err error
				if name == "symlink_file" {
					err = os.Symlink(target, path)
				} else {
					err = os.Link(target, path)
				}
				if err != nil {
					t.Fatal(err)
				}
			case "public_file":
				if err := os.Chmod(path, 0644); err != nil {
					t.Fatal(err)
				}
			case "public_root":
				if err := os.Chmod(filepath.Dir(path), 0755); err != nil {
					t.Fatal(err)
				}
			case "symlink_operation", "symlink_root":
				directory := h.receipt.JournalDirectory
				if name == "symlink_root" {
					directory = filepath.Dir(directory)
				}
				if err := os.Rename(directory, directory+".moved"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(directory+".moved", directory); err != nil {
					t.Fatal(err)
				}
			case "wrong_operation_path":
				h.receipt.JournalDirectory = filepath.Dir(h.receipt.JournalDirectory)
			}
			if _, err := h.record(context.Background(), h.verify); err == nil {
				t.Fatal("invalid native evidence accepted")
			}
			if _, err := os.Stat(h.proofPath()); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("invalid evidence wrote proof")
			}
			h.unchangedFence(t)
		})
	}
}
func TestHostNativeCompletionRequiresExactDurableHostHandoff(t *testing.T) {
	for _, name := range []string{"missing_handoff", "changed_handoff", "changed_intent", "missing_capsule", "partial_commit", "released", "partial_proof"} {
		t.Run(name, func(t *testing.T) {
			h := nativeCompletionFixture(t)
			directory := filepath.Join(h.host.dir, hostNativeClaimDirectory)
			op := h.claim.request.Epoch
			switch name {
			case "missing_handoff":
				if err := os.Remove(filepath.Join(directory, op+".native_handoff_requested.json")); err != nil {
					t.Fatal(err)
				}
			case "changed_handoff":
				path := filepath.Join(directory, op+".native_handoff_requested.json")
				raw, _ := os.ReadFile(path)
				var phase hostNativeHandoffPhase
				if decodeHostNativeRecord(raw, &phase) != nil {
					t.Fatal("handoff")
				}
				phase.EnvelopeSHA256 = strings.Repeat("c", 64)
				writeNativeCompletionJSON(t, path, phase)
			case "changed_intent":
				path := filepath.Join(directory, op+".intent_received.json")
				raw, _ := os.ReadFile(path)
				var phase hostNativeIntentPhase
				if decodeHostNativeRecord(raw, &phase) != nil {
					t.Fatal("intent")
				}
				phase.Intent.Seq++
				writeNativeCompletionJSON(t, path, phase)
			case "missing_capsule":
				if err := os.Remove(filepath.Join(h.host.dir, hostRotationCapsuleDirectory, h.claim.request.Capsule.ArtifactID+".json")); err != nil {
					t.Fatal(err)
				}
			case "partial_commit":
				if err := os.WriteFile(filepath.Join(directory, op+".commit_requested.json"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "released":
				writeNativeCompletionJSON(t, filepath.Join(directory, op+".released.json"), map[string]any{})
			case "partial_proof":
				if err := os.WriteFile(h.proofPath(), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := h.record(context.Background(), h.verify); err == nil {
				t.Fatal("invalid host handoff accepted")
			}
			if name != "partial_proof" {
				if _, err := os.Stat(h.proofPath()); !errors.Is(err, os.ErrNotExist) {
					t.Fatal("invalid handoff wrote proof")
				}
			}
			if _, err := os.Stat(filepath.Join(directory, h.claim.request.SessionID+".active.json")); err != nil {
				t.Fatal("fence removed")
			}
		})
	}
}
func TestHostNativeCompletionRevalidatesProcessJournalsAndCancellation(t *testing.T) {
	for _, name := range []string{"owner_before", "owner_after", "host_changed", "journal_changed", "directory_replaced", "cancelled", "nil_verifier", "wrong_process"} {
		t.Run(name, func(t *testing.T) {
			h := nativeCompletionFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := 0
			owner := func(e hostRotationEnrollment, r nativeRotationCompletion) error {
				calls++
				if name == "owner_before" || name == "owner_after" && calls == 2 {
					return errors.New("owner changed")
				}
				if calls == 2 {
					switch name {
					case "host_changed":
						writeNativeCompletionJSON(t, filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.Epoch+".intent_received.json"), map[string]any{})
					case "journal_changed":
						writeNativeCompletionJSON(t, filepath.Join(h.receipt.JournalDirectory, "closed.json"), map[string]any{})
					case "directory_replaced":
						old := h.receipt.JournalDirectory + ".old"
						if err := os.Rename(h.receipt.JournalDirectory, old); err != nil {
							t.Fatal(err)
						}
						if err := os.Mkdir(h.receipt.JournalDirectory, 0700); err != nil {
							t.Fatal(err)
						}
						for _, state := range []string{"intent", "sealed", "closed", "restored"} {
							raw, err := os.ReadFile(filepath.Join(old, state+".json"))
							if err != nil {
								t.Fatal(err)
							}
							if err := os.WriteFile(filepath.Join(h.receipt.JournalDirectory, state+".json"), raw, 0600); err != nil {
								t.Fatal(err)
							}
						}
					case "cancelled":
						cancel()
					}
				}
				return h.verify(e, r)
			}
			if name == "nil_verifier" {
				owner = nil
			}
			if name == "wrong_process" {
				h.receipt.ProcessID++
			}
			if _, err := h.record(ctx, owner); err == nil {
				t.Fatal("changed verification accepted")
			}
			if _, err := os.Stat(h.proofPath()); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("changed verification wrote proof")
			}
			if _, err := os.Stat(filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.SessionID+".active.json")); err != nil {
				t.Fatal("fence removed")
			}
		})
	}
}
func TestHostNativeCompletionLiveEntryRejectsNonterminalObservation(t *testing.T) {
	h := nativeCompletionFixture(t)
	if _, err := h.claim.recordNativeCompletion(context.Background(), nativeRotationReply{State: "pending"}); err == nil {
		t.Fatal("pending observation accepted")
	}
	changed := h.receipt
	changed.ProcessID++
	if verifyHostNativeCompletionOwner(h.host.source.Enrollment, changed) == nil {
		t.Fatal("changed process accepted")
	}
}

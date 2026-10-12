package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type nativeRefusalHarness struct {
	host    *nativeClaimHarness
	claim   *hostNativeRotationClaim
	path    string
	receipt hostNativeRefusalRecord
}

func nativeRefusalFixture(t *testing.T) *nativeRefusalHarness {
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
	path := filepath.Join(home, "relay-context-rotation", c.request.Epoch)
	if err := os.MkdirAll(path, 0700); err != nil {
		t.Fatal(err)
	}
	receipt := hostNativeRefusalRecord{1, "refused", c.request.Epoch, c.request.HostClaimID,
		c.request.Reservation.Native.ReservationID, c.request.Capsule.SHA256,
		nativeWireSource(c.request.Reservation.Native), uint32(h.source.Enrollment.AgentPID)}
	writeNativeCompletionJSON(t, filepath.Join(path, "refused.json"), receipt)
	return &nativeRefusalHarness{h, c, path, receipt}
}
func (h *nativeRefusalHarness) owner(e hostRotationEnrollment, r hostNativeRefusalRecord) error {
	if e != h.host.source.Enrollment || r != h.receipt {
		return errors.New("fixture source owner changed")
	}
	return nil
}
func (h *nativeRefusalHarness) record(ctx context.Context, owner func(hostRotationEnrollment, hostNativeRefusalRecord) error) (*hostNativeRefusalProof, error) {
	return verifyAndRecordHostNativeRefusal(ctx, h.host.dir, h.claim.request.SessionID, h.path, owner)
}
func (h *nativeRefusalHarness) proofPath() string {
	return filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.Epoch+".native_refused_verified.json")
}
func (h *nativeRefusalHarness) unchanged(t *testing.T) {
	t.Helper()
	nativeCommitFence(t, h.host, h.claim)
}
func (h *nativeRefusalHarness) noProof(t *testing.T) {
	t.Helper()
	if _, err := os.Stat(h.proofPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unexpected refusal proof", err)
	}
	h.unchanged(t)
}
func (h *nativeRefusalHarness) intent(state string) hostNativeJournalRecord {
	return hostNativeJournalRecord{Version: 1, State: state, OperationID: h.receipt.OperationID, ClaimID: h.receipt.ClaimID,
		CapsuleSHA256: h.receipt.CapsuleSHA256, Source: h.receipt.Source}
}

func TestHostNativeRefusalVerifiesDurablyWithoutAbortingOrClearingFence(t *testing.T) {
	h := nativeRefusalFixture(t)
	proof, err := h.record(context.Background(), h.owner)
	if err != nil || proof == nil {
		t.Fatal(err)
	}
	if proof.State != "native_refused_verified" || proof.Receipt != h.receipt || proof.JournalDirectory != h.path ||
		len(proof.NativeRecords) != 1 || !nativeWireHash(proof.JournalSHA256) || !nativeWireHash(proof.HostSnapshotSHA256) {
		t.Fatal("incomplete refusal proof")
	}
	before, err := os.Stat(h.proofPath())
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(h.proofPath())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.record(context.Background(), h.owner); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(h.proofPath())
	if err != nil || !os.SameFile(before, after) {
		t.Fatal("retry replaced proof", err)
	}
	current, _ := os.ReadFile(h.proofPath())
	if !bytes.Equal(raw, current) {
		t.Fatal("retry changed proof")
	}
	h.unchanged(t)
}
func TestHostNativeRefusalAcceptsMatchingPresealEvidenceAndExpiredLease(t *testing.T) {
	for _, mode := range []string{"intent", "aborted", "target_intent", "expired"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeRefusalFixture(t)
			if mode != "expired" {
				intent := h.intent("intent")
				if mode == "target_intent" {
					target, settings := "00000000-0000-0000-0000-000000000903", strings.Repeat("b", 64)
					intent.DestinationThreadID, intent.SettingsSHA256 = &target, &settings
				}
				writeNativeCompletionJSON(t, filepath.Join(h.path, "intent.json"), intent)
				if mode == "aborted" {
					intent.State = "aborted"
					writeNativeCompletionJSON(t, filepath.Join(h.path, "aborted.json"), intent)
				}
			} else {
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
			}
			if _, err := h.record(context.Background(), h.owner); err != nil {
				t.Fatal(err)
			}
			h.unchanged(t)
		})
	}
}
func TestHostNativeRefusalRejectsConflictingNativePhases(t *testing.T) {
	for _, name := range []string{"sealed.json", "closed.json", "restored.json", "failed.json", "restore_failed.json", "unknown.json", "aborted.json"} {
		t.Run(name, func(t *testing.T) {
			h := nativeRefusalFixture(t)
			writeNativeCompletionJSON(t, filepath.Join(h.path, name), map[string]any{"v": 1})
			if _, err := h.record(context.Background(), h.owner); err == nil {
				t.Fatal("conflicting native phase accepted")
			}
			h.noProof(t)
		})
	}
}
func TestHostNativeRefusalRejectsForeignPartialAndAmbiguousRecords(t *testing.T) {
	for _, mode := range []string{"operation", "claim", "reservation", "capsule", "source", "generation_string", "generation_float", "process", "unknown", "missing", "duplicate", "partial", "empty", "v_float", "oversized"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeRefusalFixture(t)
			raw, _ := json.Marshal(h.receipt)
			var value map[string]any
			_ = json.Unmarshal(raw, &value)
			switch mode {
			case "operation":
				value["operation_id"] = "00000000-0000-0000-0000-000000000909"
			case "claim":
				value["claim_id"] = "00000000-0000-0000-0000-000000000909"
			case "reservation":
				value["reservation_id"] = "00000000-0000-0000-0000-000000000909"
			case "capsule":
				value["capsule_sha256"] = strings.Repeat("b", 64)
			case "source":
				value["source"].(map[string]any)["thread_id"] = "00000000-0000-0000-0000-000000000909"
			case "generation_string":
				value["source"].(map[string]any)["admission_generation"] = "1"
			case "process":
				value["process_id"] = h.receipt.ProcessID + 1
			case "unknown":
				value["unexpected"] = true
			case "missing":
				delete(value, "reservation_id")
			}
			raw, _ = json.Marshal(value)
			switch mode {
			case "generation_float":
				raw = []byte(strings.Replace(string(raw), "\"admission_generation\":"+strconv.FormatUint(h.receipt.Source.AdmissionGeneration, 10), "\"admission_generation\":"+strconv.FormatUint(h.receipt.Source.AdmissionGeneration, 10)+".0", 1))
			case "duplicate":
				raw = []byte(strings.Replace(string(raw), "\"v\":1", "\"v\":1,\"v\":1", 1))
			case "v_float":
				raw = []byte(strings.Replace(string(raw), "\"v\":1", "\"v\":1.0", 1))
			case "partial":
				raw = []byte("{")
			case "empty":
				raw = nil
			case "oversized":
				raw = bytes.Repeat([]byte("x"), hostNativeClaimRecordLimit+1)
			}
			if err := os.WriteFile(filepath.Join(h.path, "refused.json"), raw, 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := h.record(context.Background(), h.owner); err == nil {
				t.Fatal("invalid refusal accepted")
			}
			h.noProof(t)
		})
	}
}
func TestHostNativeRefusalRejectsChangedPresealRecords(t *testing.T) {
	for _, mode := range []string{"foreign", "missing_nullable", "unknown_source", "source_target", "one_setting", "restored", "different_abort"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeRefusalFixture(t)
			intent := h.intent("intent")
			raw, _ := json.Marshal(intent)
			var value map[string]any
			_ = json.Unmarshal(raw, &value)
			switch mode {
			case "foreign":
				value["claim_id"] = "00000000-0000-0000-0000-000000000909"
			case "missing_nullable":
				delete(value, "restored")
			case "unknown_source":
				value["source"].(map[string]any)["extra"] = true
			case "source_target":
				value["destination_thread_id"] = h.receipt.Source.ThreadID
				value["settings_sha256"] = strings.Repeat("b", 64)
			case "one_setting":
				value["settings_sha256"] = strings.Repeat("b", 64)
			case "restored":
				value["restored"] = map[string]any{"thread_id": h.receipt.Source.ThreadID}
			}
			writeNativeCompletionJSON(t, filepath.Join(h.path, "intent.json"), value)
			if mode == "different_abort" {
				aborted := intent
				aborted.State = "aborted"
				target, settings := "00000000-0000-0000-0000-000000000903", strings.Repeat("b", 64)
				aborted.DestinationThreadID, aborted.SettingsSHA256 = &target, &settings
				writeNativeCompletionJSON(t, filepath.Join(h.path, "aborted.json"), aborted)
			}
			if _, err := h.record(context.Background(), h.owner); err == nil {
				t.Fatal("invalid preseal evidence accepted")
			}
			h.noProof(t)
		})
	}
}
func TestHostNativeRefusalRejectsUnsafeFilesAndDirectories(t *testing.T) {
	for _, mode := range []string{"public_file", "hardlink", "file_symlink", "public_root", "public_operation", "root_symlink", "operation_symlink", "wrong_path"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeRefusalFixture(t)
			record := filepath.Join(h.path, "refused.json")
			switch mode {
			case "public_file":
				if err := os.Chmod(record, 0644); err != nil {
					t.Fatal(err)
				}
			case "hardlink":
				if err := os.Link(record, filepath.Join(t.TempDir(), "alias")); err != nil {
					t.Fatal(err)
				}
			case "file_symlink":
				other := filepath.Join(t.TempDir(), "refused.json")
				raw, _ := os.ReadFile(record)
				_ = os.WriteFile(other, raw, 0600)
				_ = os.Remove(record)
				if err := os.Symlink(other, record); err != nil {
					t.Fatal(err)
				}
			case "public_root":
				if err := os.Chmod(filepath.Dir(h.path), 0755); err != nil {
					t.Fatal(err)
				}
			case "public_operation":
				if err := os.Chmod(h.path, 0755); err != nil {
					t.Fatal(err)
				}
			case "root_symlink":
				root := filepath.Dir(h.path)
				if err := os.Rename(root, root+".saved"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(root+".saved", root); err != nil {
					t.Fatal(err)
				}
			case "operation_symlink":
				if err := os.Rename(h.path, h.path+".saved"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(h.path+".saved", h.path); err != nil {
					t.Fatal(err)
				}
			case "wrong_path":
				h.path = filepath.Join(filepath.Dir(h.path), "00000000-0000-0000-0000-000000000909")
			}
			if _, err := h.record(context.Background(), h.owner); err == nil {
				t.Fatal("unsafe native refusal accepted")
			}
			h.noProof(t)
		})
	}
}
func TestHostNativeRefusalRechecksOwnerJournalAndHostIntent(t *testing.T) {
	for _, mode := range []string{"nil_owner", "owner_changed", "journal_changed", "directory_replaced", "host_handoff_removed", "cancelled"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeRefusalFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := 0
			owner := func(e hostRotationEnrollment, r hostNativeRefusalRecord) error {
				calls++
				if err := h.owner(e, r); err != nil {
					return err
				}
				if calls == 2 {
					switch mode {
					case "owner_changed":
						return errors.New("physical owner changed")
					case "journal_changed":
						changed := h.receipt
						changed.ProcessID++
						writeNativeCompletionJSON(t, filepath.Join(h.path, "refused.json"), changed)
					case "directory_replaced":
						raw, _ := os.ReadFile(filepath.Join(h.path, "refused.json"))
						if err := os.Rename(h.path, h.path+".old"); err != nil {
							t.Fatal(err)
						}
						if err := os.Mkdir(h.path, 0700); err != nil {
							t.Fatal(err)
						}
						if err := os.WriteFile(filepath.Join(h.path, "refused.json"), raw, 0600); err != nil {
							t.Fatal(err)
						}
					case "host_handoff_removed":
						if err := os.Remove(filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.Epoch+".native_handoff_requested.json")); err != nil {
							t.Fatal(err)
						}
					case "cancelled":
						cancel()
					}
				}
				return nil
			}
			if mode == "nil_owner" {
				owner = nil
			}
			if _, err := h.record(ctx, owner); err == nil {
				t.Fatal("changed authority accepted")
			}
			h.noProof(t)
		})
	}
}
func TestHostNativeRefusalRejectsRestorationProgressAndConflictingProof(t *testing.T) {
	for _, phase := range []string{"native_restored_verified", "registration_requested", "registration_received", "ledger_ack_requested", "ledger_ack_received", "native_ack_requested", "native_retired", "host_finalization_requested", "host_finalized", "native_refused_verified"} {
		t.Run(phase, func(t *testing.T) {
			h := nativeRefusalFixture(t)
			writeNativeCompletionJSON(t, filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.Epoch+"."+phase+".json"), map[string]any{"v": 1})
			if _, err := h.record(context.Background(), h.owner); err == nil {
				t.Fatal("conflicting host phase accepted")
			}
			h.unchanged(t)
		})
	}
}
func TestHostNativeRefusalPreservesMaximumGenerationExactly(t *testing.T) {
	h := nativeRefusalFixture(t)
	request := h.claim.request
	request.Reservation.Native.AdmissionGeneration = "18446744073709551615"
	record := h.receipt
	record.Source.AdmissionGeneration = ^uint64(0)
	writeNativeCompletionJSON(t, filepath.Join(h.path, "refused.json"), record)
	journal, err := readHostNativeRefusalJournal(h.path, request)
	if err != nil || journal.receipt.Source.AdmissionGeneration != ^uint64(0) {
		t.Fatal("maximum generation lost", err)
	}
	// Matching a copied receipt does not alter the durable handoff's admission.
	if _, err := h.record(context.Background(), h.owner); err == nil {
		t.Fatal("copied generation adopted into durable handoff")
	}
	h.noProof(t)
}

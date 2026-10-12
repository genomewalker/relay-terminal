package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

type nativeRegistrationHarness struct {
	*nativeCompletionHarness
	deps       hostNativeRegistrationDependencies
	calls      int
	registered *hostNativeRegistrationReceipt
	lost       bool
	mutation   string
	thread     *string
}

func nativeRegistrationFixture(t *testing.T) *nativeRegistrationHarness {
	t.Helper()
	h := &nativeRegistrationHarness{nativeCompletionHarness: nativeCompletionFixture(t)}
	task := "logical-task"
	h.thread = &task
	h.deps.binding = func(e hostRotationEnrollment, r nativeRotationCompletion) (string, error) {
		if err := h.verify(e, r); err != nil {
			return "", err
		}
		return "target-revision", nil
	}
	h.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		switch op {
		case "rotation_native_register":
			h.calls++
			q := args.(hostNativeRegistrationRequest)
			marker := filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.Epoch+".registration_requested.json")
			if _, err := os.Stat(marker); err != nil {
				t.Fatal("RPC preceded durable intent", err)
			}
			r := &hostNativeRegistrationReceipt{Version: 1, Mode: "native_v1", SessionID: q.SessionID, Epoch: q.Epoch, OperationID: q.Epoch,
				HostClaimID: q.HostClaimID, ClaimID: q.ClaimID, Token: q.Token, RequestSHA256: q.RequestSHA256,
				Seq: h.claim.intent.Seq + 1, NewSessionID: q.Target.Enrollment.SessionID, NativeReceipt: q.Receipt, Target: q.Target}
			if h.mutation != "missing_registration" {
				h.registered = r
			}
			if h.lost {
				return nil, errors.New("lost reply")
			}
			if h.mutation == "bad_reply" {
				copy := *r
				copy.Seq++
				return json.Marshal(copy)
			}
			return json.Marshal(r)
		case "rotation_status":
			q := args.(map[string]any)
			if q["session_id"] != h.claim.request.SessionID || q["epoch"] != h.claim.request.Epoch {
				t.Fatal("status omitted exact epoch")
			}
			sid := h.claim.request.SessionID
			if h.mutation == "wrong_status" {
				sid = h.receipt.TargetThreadID
			}
			return json.Marshal(map[string]any{"v": 1, "session_id": sid, "epoch": h.claim.request.Epoch,
				"client": "codex", "owner": "relay", "cwd": h.host.source.Enrollment.CWD, "registration": h.registered})
		case "session_get":
			id := args.(map[string]any)["session_id"].(string)
			target := id == h.receipt.TargetThreadID
			transcript := h.receipt.Source.RolloutPath
			metadata := map[string]any{"owner": "relay"}
			thread := h.thread
			if target {
				transcript = h.receipt.TargetRolloutPath
				if h.mutation == "missing_target" {
					return json.RawMessage("null"), nil
				}
				if h.registered != nil {
					metadata["native_registration"] = h.registered
				}
				switch h.mutation {
				case "generic_target":
					delete(metadata, "native_registration")
				case "wrong_provenance":
					copy := *h.registered
					copy.Seq++
					metadata["native_registration"] = copy
				case "wrong_thread":
					changed := "other-task"
					thread = &changed
				case "wrong_owner":
					metadata["owner"] = "desktop"
				case "wrong_rollout":
					transcript += ".other"
				}
			}
			if !target && h.calls > 0 && h.mutation == "changed_source_task" {
				changed := "reassigned"
				thread = &changed
			}
			encoded, _ := json.Marshal(metadata)
			row := map[string]any{"session_id": id, "thread_id": thread, "client": "codex", "project_dir": h.host.source.Enrollment.CWD,
				"transcript_path": transcript, "status": "active", "ended_at": nil, "metadata_json": string(encoded)}
			if target && h.mutation == "missing_thread" {
				delete(row, "thread_id")
			}
			if target && h.mutation == "ended_target" {
				row["ended_at"] = 1
			}
			return json.Marshal(row)
		default:
			t.Fatal("unexpected mutation", op)
			return nil, errors.New("unexpected operation")
		}
	}
	return h
}
func (h *nativeRegistrationHarness) run() (*hostNativeRegistrationReceipt, error) {
	return registerHostNativeCompletion(context.Background(), h.host.dir, h.claim.request.SessionID, h.receipt, h.deps)
}
func (h *nativeRegistrationHarness) phasePath(state string) string {
	return filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.Epoch+"."+state+".json")
}
func TestHostNativeRegistrationDurableAndIdempotent(t *testing.T) {
	for _, lost := range []bool{false, true} {
		for _, logical := range []bool{false, true} {
			t.Run(map[bool]string{false: "reply", true: "lost"}[lost]+map[bool]string{false: "_null", true: "_task"}[logical], func(t *testing.T) {
				h := nativeRegistrationFixture(t)
				h.lost = lost
				if !logical {
					h.thread = nil
				}
				first, err := h.run()
				if err != nil {
					t.Fatal(err)
				}
				second, err := h.run()
				if err != nil || !reflect.DeepEqual(first, second) || h.calls != 1 {
					t.Fatal("registration replayed or changed", err, h.calls)
				}
				raw, err := os.ReadFile(h.phasePath("registration_received"))
				var phase hostNativeRegistrationPhase
				if err != nil || decodeHostNativeRecord(raw, &phase) != nil || !reflect.DeepEqual(phase.Registration, first) {
					t.Fatal("missing durable registration")
				}
				if phase.Request.Receipt.ClaimID != h.claim.request.HostClaimID {
					t.Fatal("ledger claim substituted for host UUID")
				}
				h.unchangedFence(t)
			})
		}
	}
}
func TestHostNativeRegistrationRejectsConflictingObservations(t *testing.T) {
	for _, name := range []string{"missing_registration", "missing_target", "generic_target", "wrong_provenance", "wrong_thread",
		"missing_thread", "wrong_owner", "wrong_rollout", "wrong_status", "ended_target", "bad_reply", "changed_source_task"} {
		t.Run(name, func(t *testing.T) {
			h := nativeRegistrationFixture(t)
			h.mutation = name
			if _, err := h.run(); err == nil {
				t.Fatal("conflicting evidence accepted")
			}
			if _, err := os.Stat(h.phasePath("registration_received")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("invalid registration persisted")
			}
			if _, err := h.run(); err == nil && name != "bad_reply" {
				t.Fatal("conflict accepted in recovery")
			}
			if h.calls != 1 {
				t.Fatal("uncertain registration replayed")
			}
			h.unchangedFence(t)
		})
	}
}
func TestHostNativeRegistrationRecoveryNeverResubmits(t *testing.T) {
	h := nativeRegistrationFixture(t)
	h.lost = true
	h.mutation = "missing_target"
	if _, err := h.run(); err == nil {
		t.Fatal("missing target accepted")
	}
	h.mutation = ""
	if _, err := h.run(); err != nil {
		t.Fatal("durable registration not recovered", err)
	}
	if h.calls != 1 {
		t.Fatal("registration resubmitted")
	}
	h.unchangedFence(t)
}
func TestHostNativeRegistrationRechecksNativeEvidence(t *testing.T) {
	for _, name := range []string{"owner", "revision", "native_journal", "host_journal", "cancelled", "partial_marker", "changed_marker", "partial_receipt"} {
		t.Run(name, func(t *testing.T) {
			h := nativeRegistrationFixture(t)
			switch name {
			case "owner":
				h.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) {
					return "", errors.New("owner changed")
				}
			case "revision":
				n := 0
				h.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) {
					n++
					if n > 2 {
						return "different", nil
					}
					return "target-revision", nil
				}
			case "native_journal", "host_journal":
				original := h.deps.ledger
				h.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
					raw, err := original(ctx, op, args)
					if op == "rotation_native_register" {
						path := filepath.Join(h.receipt.JournalDirectory, "closed.json")
						if name == "host_journal" {
							path = filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.Epoch+".intent_received.json")
						}
						if err := os.WriteFile(path, []byte("{}"), 0600); err != nil {
							t.Fatal(err)
						}
					}
					return raw, err
				}
			case "cancelled":
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				if _, err := registerHostNativeCompletion(ctx, h.host.dir, h.claim.request.SessionID, h.receipt, h.deps); err == nil {
					t.Fatal("cancelled")
				}
				if h.calls != 0 {
					t.Fatal("cancelled RPC")
				}
				return
			case "partial_marker":
				if err := os.WriteFile(h.phasePath("registration_requested"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "changed_marker":
				if _, err := h.run(); err != nil {
					t.Fatal(err)
				}
				raw, _ := os.ReadFile(h.phasePath("registration_requested"))
				var p hostNativeRegistrationPhase
				if json.Unmarshal(raw, &p) != nil {
					t.Fatal("phase")
				}
				p.Request.Target.BindingRevision = "different"
				writeNativeCompletionJSON(t, h.phasePath("registration_requested"), p)
			case "partial_receipt":
				if err := os.WriteFile(h.phasePath("registration_received"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := h.run(); err == nil {
				t.Fatal("changed evidence accepted")
			}
			if name != "host_journal" {
				h.unchangedFence(t)
			}
		})
	}
}
func TestHostNativeRegistrationDecoderStrictIdentity(t *testing.T) {
	h := nativeRegistrationFixture(t)
	r, err := h.run()
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(h.phasePath("registration_requested"))
	var p hostNativeRegistrationPhase
	if json.Unmarshal(raw, &p) != nil {
		t.Fatal("phase")
	}
	data, _ := json.Marshal(r)
	for _, field := range []string{"v", "mode", "session_id", "epoch", "operation_id", "host_claim_id", "claim_id", "token", "request_sha256", "seq", "new_session_id", "native_receipt", "target"} {
		t.Run(field, func(t *testing.T) {
			var fields map[string]json.RawMessage
			_ = json.Unmarshal(data, &fields)
			delete(fields, field)
			bad, _ := json.Marshal(fields)
			if _, err := decodeHostNativeRegistration(bad, p.Request, h.claim.intent.Seq); err == nil {
				t.Fatal("missing field accepted")
			}
		})
	}
	for _, bad := range [][]byte{append([]byte("{\"unknown\":true,"), data[1:]...), append([]byte("{\"seq\":1,"), data[1:]...), []byte("null")} {
		if _, err := decodeHostNativeRegistration(bad, p.Request, h.claim.intent.Seq); err == nil {
			t.Fatal("ambiguous/unknown accepted")
		}
	}
}

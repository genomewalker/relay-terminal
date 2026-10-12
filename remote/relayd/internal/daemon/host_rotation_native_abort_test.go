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

type nativeAbortHarness struct {
	*nativeRefusalHarness
	t        *testing.T
	deps     hostNativeAbortDependencies
	aborted  *hostNativeAbortReceipt
	calls    int
	lost     bool
	unsent   bool
	mutation string
}

func nativeAbortFixture(t *testing.T) *nativeAbortHarness {
	t.Helper()
	h := &nativeAbortHarness{nativeRefusalHarness: nativeRefusalFixture(t), t: t}
	if _, err := h.record(context.Background(), h.owner); err != nil {
		t.Fatal(err)
	}
	h.deps = hostNativeAbortDependencies{owner: h.owner}
	h.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		switch op {
		case "rotation_native_abort":
			h.calls++
			raw, err := os.ReadFile(h.phase("ledger_abort_requested"))
			var p hostNativeAbortPhase
			if err != nil || decodeHostNativeRecord(raw, &p) != nil || !reflect.DeepEqual(p.Request, args) {
				t.Fatal("abort preceded exact durable request", err)
			}
			q := args.(hostNativeAbortRequest)
			a := &hostNativeAbortReceipt{Version: 1, Mode: "native_v1", SessionID: q.SessionID, Epoch: q.Epoch, OperationID: q.Epoch,
				HostClaimID: q.HostClaimID, ClaimID: q.ClaimID, Token: q.Token, RequestSHA256: q.RequestSHA256,
				Seq: h.claim.intent.Seq + 1, NativeReceipt: q.Receipt}
			if !h.unsent {
				h.aborted = a
			}
			switch h.mutation {
			case "native_changed":
				writeNativeCompletionJSON(t, filepath.Join(h.path, "refused.json"), map[string]any{})
			case "host_changed":
				writeNativeCompletionJSON(t, h.proofPath(), map[string]any{})
			case "wrong_reply":
				copy := *a
				copy.Seq++
				return json.Marshal(copy)
			}
			if h.lost || h.unsent {
				return nil, errors.New("transport lost")
			}
			return json.Marshal(a)
		case "rotation_status":
			want := map[string]any{"session_id": h.claim.request.SessionID, "epoch": h.claim.request.Epoch}
			if !reflect.DeepEqual(args, want) {
				t.Fatal("status did not request exact historical epoch")
			}
			if h.mutation == "lost_status" && h.aborted != nil {
				return nil, errors.New("status lost")
			}
			c := h.rawMap(h.claim.receipt)
			i := h.rawMap(h.claim.intent)
			s := map[string]any{"v": 1, "session_id": h.claim.request.SessionID, "epoch": h.claim.request.Epoch,
				"client": "codex", "cwd": h.host.source.Enrollment.CWD, "owner": "relay", "live": false,
				"lifecycle_performed": false, "new_session_id": nil, "claim": c, "intent": i, "ack": nil}
			if h.aborted != nil {
				c["closed"] = json.RawMessage("true")
				c["abort_seq"] = h.raw(h.aborted.Seq)
				i["state"] = h.raw("aborted")
				i["abort_seq"] = h.raw(h.aborted.Seq)
				a := h.rawMap(h.aborted)
				s["abort"] = a
				switch h.mutation {
				case "claim_open":
					c["closed"] = json.RawMessage("false")
				case "claim_sequence":
					c["abort_seq"] = h.raw(h.aborted.Seq + 1)
				case "intent_pending":
					i["state"] = h.raw("commit_requested")
				case "intent_sequence":
					i["abort_seq"] = h.raw(h.aborted.Seq + 1)
				case "still_live":
					s["live"] = true
				case "registration":
					s["registration"] = map[string]any{}
				case "ack":
					s["ack"] = map[string]any{}
				case "receipt_identity":
					a["host_claim_id"] = h.raw(h.claim.request.Epoch)
				case "receipt_sequence":
					a["seq"] = h.raw(h.claim.intent.Seq)
				case "receipt_extra":
					a["foreign"] = h.raw(1)
				case "receipt_missing":
					delete(a, "lifecycle_performed")
				case "receipt_lifecycle":
					a["lifecycle_performed"] = h.raw(true)
				}
			}
			switch h.mutation {
			case "owner":
				s["owner"] = "desktop"
			case "cwd":
				s["cwd"] = "/foreign"
			case "missing_live":
				delete(s, "live")
			case "missing_lifecycle":
				delete(s, "lifecycle_performed")
			case "lifecycle":
				s["lifecycle_performed"] = true
			case "destination":
				s["new_session_id"] = h.claim.request.SessionID
			case "missing_ack":
				delete(s, "ack")
			case "foreign_epoch":
				s["epoch"] = h.claim.request.HostClaimID
			case "duplicate":
				return json.RawMessage(`{"v":1,"v":1}`), nil
			}
			return json.Marshal(s)
		default:
			t.Fatal("unexpected abort ledger operation", op)
		}
		return nil, errors.New("unexpected operation")
	}
	return h
}
func (h *nativeAbortHarness) raw(v any) json.RawMessage {
	h.t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		h.t.Fatal(err)
	}
	return raw
}
func (h *nativeAbortHarness) rawMap(v any) map[string]json.RawMessage {
	h.t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal(h.raw(v), &m); err != nil {
		h.t.Fatal(err)
	}
	return m
}
func (h *nativeAbortHarness) phase(state string) string {
	return filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.Epoch+"."+state+".json")
}
func (h *nativeAbortHarness) run() (*hostNativeAbortReceipt, error) {
	return abortHostNativeRefusal(context.Background(), h.host.dir, h.claim.request.SessionID, h.deps)
}
func (h *nativeAbortHarness) noReceived() {
	h.t.Helper()
	if _, err := os.Stat(h.phase("ledger_abort_received")); !errors.Is(err, os.ErrNotExist) {
		h.t.Fatal("unexpected durable abort", err)
	}
	h.unchanged(h.t)
}

func TestHostNativeAbortDurableLostReplyAndIdempotent(t *testing.T) {
	for _, lost := range []bool{false, true} {
		t.Run(map[bool]string{false: "reply", true: "lost"}[lost], func(t *testing.T) {
			h := nativeAbortFixture(t)
			h.lost = lost
			first, err := h.run()
			if err != nil || first == nil {
				t.Fatal(err)
			}
			info, err := os.Stat(h.phase("ledger_abort_received"))
			if err != nil {
				t.Fatal(err)
			}
			again, err := h.run()
			if err != nil || !reflect.DeepEqual(first, again) || h.calls != 1 {
				t.Fatal("abort repeated or changed", err)
			}
			after, err := os.Stat(h.phase("ledger_abort_received"))
			if err != nil || !os.SameFile(info, after) {
				t.Fatal("abort receipt replaced", err)
			}
			if first.LifecyclePerformed || first.NativeReceipt != h.receipt {
				t.Fatal("abort performed lifecycle work")
			}
			h.unchanged(t)
		})
	}
}
func TestHostNativeAbortRetriesOnlyExactPendingRequest(t *testing.T) {
	h := nativeAbortFixture(t)
	h.unsent = true
	if r, err := h.run(); err == nil || r != nil || h.calls != 1 {
		t.Fatal("unsent abort completed")
	}
	h.noReceived()
	h.unsent = false
	if _, err := h.run(); err != nil || h.calls != 2 {
		t.Fatal("exact unsent retry failed", err)
	}
	h.unchanged(t)
}
func TestHostNativeAbortLostStatusRecoversWithoutResubmission(t *testing.T) {
	h := nativeAbortFixture(t)
	h.mutation = "lost_status"
	if _, err := h.run(); err == nil || h.calls != 1 {
		t.Fatal("unobserved abort completed")
	}
	h.noReceived()
	h.mutation = ""
	if _, err := h.run(); err != nil || h.calls != 1 {
		t.Fatal("recovery resubmitted abort", err)
	}
	h.unchanged(t)
}
func TestHostNativeAbortRejectsConflictingLedgerHistory(t *testing.T) {
	for _, name := range []string{"claim_open", "claim_sequence", "intent_pending", "intent_sequence", "still_live", "registration", "ack",
		"receipt_identity", "receipt_sequence", "receipt_extra", "receipt_missing", "receipt_lifecycle", "owner", "cwd", "missing_live",
		"missing_lifecycle", "lifecycle", "destination", "missing_ack", "foreign_epoch", "duplicate", "wrong_reply"} {
		t.Run(name, func(t *testing.T) {
			h := nativeAbortFixture(t)
			h.mutation = name
			if r, err := h.run(); err == nil || r != nil || h.calls > 1 {
				t.Fatal("accepted conflicting abort", err)
			}
			h.noReceived()
		})
	}
}
func TestHostNativeAbortRequiresImmutableRefusalAndRequest(t *testing.T) {
	for _, name := range []string{"missing_proof", "partial_proof", "partial_request", "orphan_receipt", "restoration", "unsafe_native", "owner", "cancelled"} {
		t.Run(name, func(t *testing.T) {
			h := nativeAbortFixture(t)
			ctx := context.Background()
			switch name {
			case "missing_proof":
				if err := os.Remove(h.proofPath()); err != nil {
					t.Fatal(err)
				}
			case "partial_proof":
				if err := os.WriteFile(h.proofPath(), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "partial_request":
				if err := os.WriteFile(h.phase("ledger_abort_requested"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "orphan_receipt":
				if err := os.WriteFile(h.phase("ledger_abort_received"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "restoration":
				if err := os.WriteFile(h.phase("native_restored_verified"), []byte("{}"), 0600); err != nil {
					t.Fatal(err)
				}
			case "unsafe_native":
				if err := os.Chmod(filepath.Join(h.path, "refused.json"), 0644); err != nil {
					t.Fatal(err)
				}
			case "owner":
				h.deps.owner = func(hostRotationEnrollment, hostNativeRefusalRecord) error { return errors.New("owner changed") }
			case "cancelled":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			if r, err := abortHostNativeRefusal(ctx, h.host.dir, h.claim.request.SessionID, h.deps); err == nil || r != nil || h.calls != 0 {
				t.Fatal("unproven abort submitted", err)
			}
			if name != "orphan_receipt" {
				h.noReceived()
			} else {
				h.unchanged(t)
			}
		})
	}
}
func TestHostNativeAbortRechecksEvidenceAfterLedger(t *testing.T) {
	for _, name := range []string{"native_changed", "host_changed", "owner_changed", "cancelled"} {
		t.Run(name, func(t *testing.T) {
			h := nativeAbortFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if name == "owner_changed" {
				h.deps.owner = func(e hostRotationEnrollment, r hostNativeRefusalRecord) error {
					if h.aborted != nil {
						return errors.New("owner changed")
					}
					return h.owner(e, r)
				}
			} else if name == "cancelled" {
				base := h.deps.ledger
				h.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
					raw, err := base(ctx, op, args)
					if op == "rotation_native_abort" {
						cancel()
					}
					return raw, err
				}
			} else {
				h.mutation = name
			}
			if r, err := abortHostNativeRefusal(ctx, h.host.dir, h.claim.request.SessionID, h.deps); err == nil || r != nil || h.calls != 1 {
				t.Fatal("changed abort evidence accepted", err)
			}
			h.noReceived()
		})
	}
}
func TestHostNativeAbortNeverRecreatesMissingRetryMarker(t *testing.T) {
	h := nativeAbortFixture(t)
	h.unsent = true
	if _, err := h.run(); err == nil {
		t.Fatal("fixture did not remain pending")
	}
	// Once the original marker disappears, no retry path may manufacture it.
	input, err := readHostNativeAbortInput(h.host.dir, h.claim.request.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	p := hostNativeAbortPhase{1, "ledger_abort_requested", input.fingerprint, input.refusal, hostNativeAbortRequestFor(input), nil}
	if err := os.Remove(h.phase("ledger_abort_requested")); err != nil {
		t.Fatal(err)
	}
	if err := authorizeHostNativeLedgerRetry(h.host.dir, h.claim.request.Epoch, "ledger_abort_requested", "ledger_abort_received", p, func(*os.File) error { return nil }); err == nil {
		t.Fatal("missing marker authorized retry")
	}
	h.noReceived()
}
func TestHostNativeAbortRecoveryUsesDurableRefusal(t *testing.T) {
	h := nativeAbortFixture(t)
	input, err := readHostNativeCompletionInput(h.host.dir, h.claim.request.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	p, err := readHostNativeDriverRefusal(h.host.dir, input)
	if err != nil || p == nil || p.Receipt != h.receipt {
		t.Fatal("durable refusal unavailable", err)
	}
	if _, err := h.run(); err != nil {
		t.Fatal(err)
	}
	p, err = readHostNativeDriverRefusal(h.host.dir, input)
	if err != nil || p == nil {
		t.Fatal("abort lost durable refusal", err)
	}
	h.unchanged(t)
}

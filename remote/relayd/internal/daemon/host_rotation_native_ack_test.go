package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

type nativeAckHarness struct {
	*nativeRegistrationHarness
	deps     hostNativeRegistrationDependencies
	ack      *hostNativeAckReceipt
	calls    int
	lost     bool
	mutation string
}

func nativeAckFixture(t *testing.T) *nativeAckHarness {
	t.Helper()
	h := &nativeAckHarness{nativeRegistrationHarness: nativeRegistrationFixture(t)}
	if _, err := h.nativeRegistrationHarness.run(); err != nil {
		t.Fatal(err)
	}
	h.deps = h.nativeRegistrationHarness.deps
	base := h.deps.ledger
	h.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if op == "rotation_native_ack" {
			h.calls++
			if _, err := os.Stat(h.phasePath("ledger_ack_requested")); err != nil {
				t.Fatal("ACK preceded durable intent")
			}
			q := args.(hostNativeAckRequest)
			ack := &hostNativeAckReceipt{Version: 1, Mode: "native_v1", SessionID: q.SessionID, Epoch: q.Epoch, OperationID: q.Epoch,
				HostClaimID: q.HostClaimID, ClaimID: q.ClaimID, Token: q.Token, IntentID: q.Epoch, RequestSHA256: q.RequestSHA256,
				Seq: h.registered.Seq + 1, LifecyclePerformed: true, NewSessionID: h.receipt.TargetThreadID, NativeReceipt: q.Receipt}
			if h.mutation != "missing_ack" {
				h.ack = ack
			}
			if h.mutation == "native_changed" {
				writeNativeCompletionJSON(t, filepath.Join(h.receipt.JournalDirectory, "restored.json"), map[string]any{})
			}
			if h.mutation == "host_changed" {
				writeNativeCompletionJSON(t, h.phasePath("registration_received"), map[string]any{})
			}
			if h.mutation == "target_changed" {
				h.nativeRegistrationHarness.mutation = "wrong_provenance"
			}
			if h.lost {
				return nil, errors.New("ACK reply lost")
			}
			if h.mutation == "wrong_reply" {
				copy := *ack
				copy.Seq++
				return json.Marshal(copy)
			}
			return json.Marshal(ack)
		}
		raw, err := base(ctx, op, args)
		if err != nil || op != "rotation_status" || h.ack == nil {
			return raw, err
		}
		var status map[string]any
		if json.Unmarshal(raw, &status) != nil {
			t.Fatal("status fixture")
		}
		claimRaw, _ := json.Marshal(h.claim.receipt)
		var claim map[string]any
		_ = json.Unmarshal(claimRaw, &claim)
		claim["closed"] = true
		claim["ack_seq"] = h.ack.Seq
		intentRaw, _ := json.Marshal(h.claim.intent)
		var intent map[string]any
		_ = json.Unmarshal(intentRaw, &intent)
		intent["state"] = "acknowledged"
		intent["ack_seq"] = h.ack.Seq
		status["claim"] = claim
		status["intent"] = intent
		status["ack"] = h.ack
		status["live"] = false
		status["lifecycle_performed"] = true
		status["new_session_id"] = h.receipt.TargetThreadID
		switch h.mutation {
		case "claim_open":
			claim["closed"] = false
		case "claim_sequence":
			claim["ack_seq"] = h.ack.Seq + 1
		case "claim_identity":
			claim["host_claim_id"] = h.claim.request.Epoch
		case "intent_pending":
			intent["state"] = "commit_requested"
		case "intent_sequence":
			intent["ack_seq"] = h.ack.Seq + 1
		case "missing_live":
			delete(status, "live")
		case "still_live":
			status["live"] = true
		case "wrong_target":
			status["new_session_id"] = h.claim.request.SessionID
		case "missing_registration":
			delete(status, "registration")
		case "missing_native_receipt":
			b, _ := json.Marshal(h.ack)
			var changed map[string]json.RawMessage
			_ = json.Unmarshal(b, &changed)
			delete(changed, "native_receipt")
			status["ack"] = changed
		}
		return json.Marshal(status)
	}
	return h
}
func (h *nativeAckHarness) run() (*hostNativeAckReceipt, error) {
	return acknowledgeHostNativeCompletion(context.Background(), h.host.dir, h.claim.request.SessionID, h.deps)
}
func TestHostNativeAckDurableLostReplyAndIdempotent(t *testing.T) {
	for _, lost := range []bool{false, true} {
		t.Run(map[bool]string{false: "reply", true: "lost"}[lost], func(t *testing.T) {
			h := nativeAckFixture(t)
			h.lost = lost
			first, err := h.run()
			if err != nil {
				t.Fatal(err)
			}
			again, err := h.run()
			if err != nil || !reflect.DeepEqual(first, again) || h.calls != 1 {
				t.Fatal("ACK replayed or changed", err)
			}
			raw, err := os.ReadFile(h.phasePath("ledger_ack_received"))
			var phase hostNativeAckPhase
			if err != nil || decodeHostNativeRecord(raw, &phase) != nil || !reflect.DeepEqual(phase.Ack, first) {
				t.Fatal("ACK not durable")
			}
			if h.nativeRegistrationHarness.calls != 1 {
				t.Fatal("ACK re-registered destination")
			}
			h.unchangedFence(t)
		})
	}
}
func TestHostNativeAckRequiresDurableRegistrationBeforeRPC(t *testing.T) {
	for _, name := range []string{"missing_registration", "partial_registration", "changed_registration", "missing_requested",
		"partial_ack_request", "orphan_ack_receipt", "partial_ack_receipt", "owner", "revision", "cancelled"} {
		t.Run(name, func(t *testing.T) {
			h := nativeAckFixture(t)
			switch name {
			case "missing_registration":
				if err := os.Remove(h.phasePath("registration_received")); err != nil {
					t.Fatal(err)
				}
			case "partial_registration":
				if err := os.WriteFile(h.phasePath("registration_received"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "changed_registration":
				raw, _ := os.ReadFile(h.phasePath("registration_received"))
				var p hostNativeRegistrationPhase
				if json.Unmarshal(raw, &p) != nil {
					t.Fatal("phase")
				}
				p.Request.Receipt.ClaimID = h.claim.receipt.ClaimID
				writeNativeCompletionJSON(t, h.phasePath("registration_received"), p)
			case "missing_requested":
				if err := os.Remove(h.phasePath("registration_requested")); err != nil {
					t.Fatal(err)
				}
			case "partial_ack_request":
				if err := os.WriteFile(h.phasePath("ledger_ack_requested"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "orphan_ack_receipt", "partial_ack_receipt":
				if err := os.WriteFile(h.phasePath("ledger_ack_received"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "owner":
				h.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) {
					return "", errors.New("owner changed")
				}
			case "revision":
				h.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) { return "different", nil }
			case "cancelled":
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				if _, err := acknowledgeHostNativeCompletion(ctx, h.host.dir, h.claim.request.SessionID, h.deps); err == nil {
					t.Fatal("cancelled accepted")
				}
				if h.calls != 0 {
					t.Fatal("cancelled RPC")
				}
				return
			}
			if _, err := h.run(); err == nil {
				t.Fatal("unproven ACK accepted")
			}
			if h.calls != 0 {
				t.Fatal("unproven registration reached ACK")
			}
			if _, err := os.Stat(filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.SessionID+".active.json")); err != nil {
				t.Fatal("fence removed")
			}
		})
	}
}
func TestHostNativeAckRejectsConflictingLedgerAndNativeEvidence(t *testing.T) {
	for _, name := range []string{"missing_ack", "wrong_reply", "claim_open", "claim_sequence", "claim_identity", "intent_pending",
		"intent_sequence", "missing_live", "still_live", "wrong_target", "missing_registration", "missing_native_receipt",
		"native_changed", "host_changed", "target_changed"} {
		t.Run(name, func(t *testing.T) {
			h := nativeAckFixture(t)
			h.mutation = name
			if _, err := h.run(); err == nil {
				t.Fatal("conflicting ACK accepted")
			}
			if _, err := os.Stat(h.phasePath("ledger_ack_received")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("invalid receipt persisted")
			}
			if _, err := h.run(); err == nil && name != "wrong_reply" {
				t.Fatal("conflicting recovery accepted")
			}
			if h.calls != 1 {
				t.Fatal("uncertain ACK replayed")
			}
			if _, err := os.Stat(filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.SessionID+".active.json")); err != nil {
				t.Fatal("fence removed")
			}
		})
	}
}
func TestHostNativeAckRecoveryAndHistoricalLease(t *testing.T) {
	h := nativeAckFixture(t)
	h.lost = true
	h.mutation = "missing_live"
	h.claim.lease.deadline = time.Now().Add(-time.Hour)
	if _, err := h.run(); err == nil {
		t.Fatal("incomplete status accepted")
	}
	h.mutation = ""
	if _, err := h.run(); err != nil {
		t.Fatal("ACK recovery required live preparation", err)
	}
	if h.calls != 1 {
		t.Fatal("ACK replayed")
	}
	h.unchangedFence(t)
}
func TestHostNativeAckStrictReceiptFields(t *testing.T) {
	h := nativeAckFixture(t)
	r, err := h.run()
	if err != nil {
		t.Fatal(err)
	}
	input, err := readHostNativeAckInput(h.host.dir, h.claim.request.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	q := hostNativeAckRequestFor(input)
	raw, _ := json.Marshal(r)
	for _, field := range []string{"v", "mode", "session_id", "epoch", "operation_id", "host_claim_id", "claim_id", "token", "intent_id", "request_sha256", "seq", "lifecycle_performed", "new_session_id", "native_receipt"} {
		t.Run(field, func(t *testing.T) {
			var fields map[string]json.RawMessage
			_ = json.Unmarshal(raw, &fields)
			delete(fields, field)
			bad, _ := json.Marshal(fields)
			if _, err := decodeHostNativeAck(bad, q, h.registered.Seq); err == nil {
				t.Fatal("missing field accepted")
			}
		})
	}
	for _, bad := range [][]byte{append([]byte("{\"unknown\":true,"), raw[1:]...), append([]byte("{\"seq\":1,"), raw[1:]...), []byte("null")} {
		if _, err := decodeHostNativeAck(bad, q, h.registered.Seq); err == nil {
			t.Fatal("unknown or ambiguous accepted")
		}
	}
}
func TestHostNativeAckChittaContractGolden(t *testing.T) {
	raw, err := os.ReadFile("testdata/native_rotation_registration_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]json.RawMessage
	if json.Unmarshal(raw, &wire) != nil {
		t.Fatal("golden")
	}
	var q hostNativeRegistrationRequest
	if decodeHostNativeRecord(wire["register_request"], &q) != nil {
		t.Fatal("request")
	}
	if q.Receipt.Source.AdmissionGeneration != math.MaxUint64 {
		t.Fatal("integer rounded")
	}
	var pending struct {
		Claim  hostNativeClaimReceipt  `json:"claim"`
		Intent hostNativeIntentReceipt `json:"intent"`
	}
	if json.Unmarshal(wire["pending_status"], &pending) != nil {
		t.Fatal("pending")
	}
	r, err := decodeHostNativeRegistration(wire["registration"], q, pending.Intent.Seq)
	if err != nil {
		t.Fatal(err)
	}
	ack, err := decodeHostNativeAck(wire["ack"], hostNativeAckRequest{q.hostNativeIntentRequest, q.Receipt}, r.Seq)
	if err != nil {
		t.Fatal(err)
	}
	input := &hostNativeAckInput{
		completion: &hostNativeCompletionInput{claim: pending.Claim, intent: pending.Intent,
			request: hostNativeClaimRequest{Source: pending.Claim.Native.Source}},
		registration: hostNativeRegistrationPhase{Request: q, Registration: &r},
	}
	observed, err := readHostNativeAckStatus(context.Background(), hostNativeRegistrationDependencies{
		ledger: func(_ context.Context, op string, args any) (json.RawMessage, error) {
			if op != "rotation_status" || args.(map[string]any)["epoch"] != q.Epoch {
				t.Fatal("golden query")
			}
			return wire["completed_status"], nil
		},
	}, input)
	if err != nil || !reflect.DeepEqual(observed, ack) {
		t.Fatal("C++ ACK/status disagrees", err)
	}
}

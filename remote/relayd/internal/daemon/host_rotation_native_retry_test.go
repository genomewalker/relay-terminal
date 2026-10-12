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

func nativeRetryPendingLedger(t *testing.T, c *hostNativeRotationClaim,
	base func(context.Context, string, any) (json.RawMessage, error),
	mutate func(map[string]json.RawMessage)) func(context.Context, string, any) (json.RawMessage, error) {
	t.Helper()
	return func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		raw, err := base(ctx, op, args)
		if err != nil || op != "rotation_status" {
			return raw, err
		}
		var fields map[string]json.RawMessage
		if json.Unmarshal(raw, &fields) != nil {
			t.Fatal("status")
		}
		if prior := fields["ack"]; len(prior) > 0 && string(prior) != "null" {
			return raw, nil
		}
		fields["claim"], _ = json.Marshal(c.receipt)
		fields["intent"], _ = json.Marshal(c.intent)
		fields["ack"] = json.RawMessage("null")
		fields["live"] = json.RawMessage("false") // valid pending intent after lease expiry
		fields["lifecycle_performed"] = json.RawMessage("false")
		fields["new_session_id"] = json.RawMessage("null")
		if mutate != nil {
			mutate(fields)
		}
		return json.Marshal(fields)
	}
}
func TestHostNativeLedgerRetryRegistrationRecoversUnsentExactRequest(t *testing.T) {
	h := nativeRegistrationFixture(t)
	expired := time.Now().Add(-time.Hour).UnixMilli()
	h.claim.receipt.ExpiresAtMS = expired
	for _, state := range []string{"claim_received", "commit_requested"} {
		path := h.phasePath(state)
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var p hostNativeClaimPhase
		if json.Unmarshal(raw, &p) != nil {
			t.Fatal("claim")
		}
		p.Claim.ExpiresAtMS = expired
		writeNativeCompletionJSON(t, path, p)
	}
	var requests []string
	base := h.deps.ledger
	capture := func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if op == "rotation_native_register" {
			raw, _ := json.Marshal(args)
			requests = append(requests, string(raw))
		}
		return base(ctx, op, args)
	}
	h.deps.ledger = nativeRetryPendingLedger(t, h.claim, capture, nil)
	h.lost = true
	h.mutation = "missing_registration"
	if _, err := h.run(); err == nil || h.calls != 1 {
		t.Fatal("undelivered request accepted or repeated")
	}
	before, err := os.ReadFile(h.phasePath("registration_requested"))
	if err != nil {
		t.Fatal(err)
	}
	h.lost = false
	h.mutation = ""
	if _, err := h.run(); err != nil {
		t.Fatal("undelivered registration did not recover", err)
	}
	after, _ := os.ReadFile(h.phasePath("registration_requested"))
	if h.calls != 2 || len(requests) != 2 || requests[0] != requests[1] || string(before) != string(after) {
		t.Fatal("retry changed durable request")
	}
	if _, err := h.run(); err != nil || h.calls != 2 {
		t.Fatal("completed registration repeated", err)
	}
	h.unchangedFence(t)
}
func TestHostNativeLedgerRetryAckRecoversUnsentExactRequest(t *testing.T) {
	h := nativeAckFixture(t)
	var requests []string
	base := h.deps.ledger
	capture := func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if op == "rotation_native_ack" {
			raw, _ := json.Marshal(args)
			requests = append(requests, string(raw))
		}
		return base(ctx, op, args)
	}
	h.deps.ledger = nativeRetryPendingLedger(t, h.claim, capture, nil)
	h.lost = true
	h.mutation = "missing_ack"
	if _, err := h.run(); err == nil || h.calls != 1 {
		t.Fatal("undelivered ACK accepted or repeated")
	}
	before, err := os.ReadFile(h.phasePath("ledger_ack_requested"))
	if err != nil {
		t.Fatal(err)
	}
	h.lost = false
	h.mutation = ""
	if _, err := h.run(); err != nil {
		t.Fatal("undelivered ACK did not recover", err)
	}
	after, _ := os.ReadFile(h.phasePath("ledger_ack_requested"))
	if h.calls != 2 || len(requests) != 2 || requests[0] != requests[1] || string(before) != string(after) {
		t.Fatal("ACK retry changed durable request")
	}
	if _, err := h.run(); err != nil || h.calls != 2 {
		t.Fatal("completed ACK repeated", err)
	}
	h.unchangedFence(t)
}
func nativeRetryCorruptPending(t *testing.T, fields map[string]json.RawMessage, name string) {
	t.Helper()
	switch name {
	case "source":
		fields["session_id"] = json.RawMessage("\"00000000-0000-0000-0000-000000000999\"")
	case "epoch":
		fields["epoch"] = json.RawMessage("\"00000000-0000-0000-0000-000000000999\"")
	case "owner":
		fields["owner"] = json.RawMessage("\"desktop\"")
	case "missing_live":
		delete(fields, "live")
	case "missing_lifecycle":
		delete(fields, "lifecycle_performed")
	case "lifecycle":
		fields["lifecycle_performed"] = json.RawMessage("true")
	case "missing_ack":
		delete(fields, "ack")
	case "ack":
		fields["ack"] = json.RawMessage("{}")
	case "new_session":
		fields["new_session_id"] = json.RawMessage("\"00000000-0000-0000-0000-000000000999\"")
	case "registration":
		fields["registration"] = json.RawMessage("{}")
	case "claim", "intent", "float_token", "unknown_claim":
		key := "claim"
		if name == "intent" {
			key = "intent"
		}
		var nested map[string]json.RawMessage
		if json.Unmarshal(fields[key], &nested) != nil {
			t.Fatal("pending")
		}
		if name == "float_token" {
			nested["token"] = json.RawMessage("1.0")
		} else if name == "unknown_claim" {
			nested["extra"] = json.RawMessage("true")
		} else {
			nested["host_claim_id"] = json.RawMessage("\"00000000-0000-0000-0000-000000000999\"")
		}
		fields[key], _ = json.Marshal(nested)
	}
}
func TestHostNativeLedgerRetryRefusesUnprovenPendingState(t *testing.T) {
	for _, mode := range []string{"registration", "ack"} {
		for _, name := range []string{"source", "epoch", "owner", "missing_live",
			"missing_lifecycle", "lifecycle", "missing_ack", "ack", "new_session", "registration", "claim", "intent", "float_token", "unknown_claim", "unavailable"} {
			t.Run(mode+"/"+name, func(t *testing.T) {
				active := false
				mutate := func(fields map[string]json.RawMessage) {
					if active {
						nativeRetryCorruptPending(t, fields, name)
					}
				}
				if mode == "registration" {
					h := nativeRegistrationFixture(t)
					h.lost = true
					h.mutation = "missing_registration"
					base := nativeRetryPendingLedger(t, h.claim, h.deps.ledger, mutate)
					h.deps.ledger = func(ctx context.Context, op string, a any) (json.RawMessage, error) {
						if active && name == "unavailable" && op == "rotation_status" {
							return nil, errors.New("unavailable")
						}
						return base(ctx, op, a)
					}
					if _, err := h.run(); err == nil {
						t.Fatal("lost accepted")
					}
					active = true
					h.lost = false
					h.mutation = ""
					if _, err := h.run(); err == nil || h.calls != 1 {
						t.Fatal("unproven registration retry", err, h.calls)
					}
					h.unchangedFence(t)
				} else {
					h := nativeAckFixture(t)
					h.lost = true
					h.mutation = "missing_ack"
					base := nativeRetryPendingLedger(t, h.claim, h.deps.ledger, mutate)
					h.deps.ledger = func(ctx context.Context, op string, a any) (json.RawMessage, error) {
						if active && name == "unavailable" && op == "rotation_status" {
							return nil, errors.New("unavailable")
						}
						return base(ctx, op, a)
					}
					if _, err := h.run(); err == nil {
						t.Fatal("lost accepted")
					}
					active = true
					h.lost = false
					h.mutation = ""
					if _, err := h.run(); err == nil || h.calls != 1 {
						t.Fatal("unproven ACK retry", err, h.calls)
					}
					h.unchangedFence(t)
				}
			})
		}
	}
}
func TestHostNativeLedgerRetryRechecksLocalEvidenceAndOwner(t *testing.T) {
	for _, mode := range []string{"registration", "ack"} {
		for _, name := range []string{"request_changed", "receipt_created", "owner_changed"} {
			t.Run(mode+"/"+name, func(t *testing.T) {
				changed := false
				apply := func(path func(string) string, fields map[string]json.RawMessage) {
					if !changed {
						return
					}
					state := "registration_requested"
					received := "registration_received"
					if mode == "ack" {
						state = "ledger_ack_requested"
						received = "ledger_ack_received"
					}
					if name == "request_changed" {
						writeNativeCompletionJSON(t, path(state), map[string]any{})
					}
					if name == "receipt_created" {
						writeNativeCompletionJSON(t, path(received), map[string]any{})
					}
				}
				if mode == "registration" {
					h := nativeRegistrationFixture(t)
					h.lost = true
					h.mutation = "missing_registration"
					h.deps.ledger = nativeRetryPendingLedger(t, h.claim, h.deps.ledger, func(f map[string]json.RawMessage) { apply(h.phasePath, f) })
					if _, err := h.run(); err == nil {
						t.Fatal("lost accepted")
					}
					changed = true
					h.lost = false
					h.mutation = ""
					if name == "owner_changed" {
						h.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) {
							return "", errors.New("changed")
						}
					}
					if _, err := h.run(); err == nil || h.calls != 1 {
						t.Fatal("changed evidence retried", err, h.calls)
					}
				} else {
					h := nativeAckFixture(t)
					h.lost = true
					h.mutation = "missing_ack"
					h.deps.ledger = nativeRetryPendingLedger(t, h.claim, h.deps.ledger, func(f map[string]json.RawMessage) { apply(h.phasePath, f) })
					if _, err := h.run(); err == nil {
						t.Fatal("lost accepted")
					}
					changed = true
					h.lost = false
					h.mutation = ""
					if name == "owner_changed" {
						h.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) {
							return "", errors.New("changed")
						}
					}
					if _, err := h.run(); err == nil || h.calls != 1 {
						t.Fatal("changed evidence retried", err, h.calls)
					}
				}
			})
		}
	}
}
func TestHostNativeLedgerRetryIsBoundedPerInvocation(t *testing.T) {
	h := nativeRegistrationFixture(t)
	h.lost = true
	h.mutation = "missing_registration"
	h.deps.ledger = nativeRetryPendingLedger(t, h.claim, h.deps.ledger, nil)
	for i := 1; i <= 3; i++ {
		if _, err := h.run(); err == nil || h.calls != i {
			t.Fatal("retry loop or false success", err, h.calls)
		}
	}
	h.unchangedFence(t)
}
func TestHostNativeLedgerRetryChittaPendingContract(t *testing.T) {
	raw, err := os.ReadFile("testdata/native_rotation_registration_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]json.RawMessage
	_ = json.Unmarshal(raw, &wire)
	var q hostNativeRegistrationRequest
	if decodeHostNativeRecord(wire["register_request"], &q) != nil {
		t.Fatal("request")
	}
	var pending struct {
		Claim  hostNativeClaimReceipt  `json:"claim"`
		Intent hostNativeIntentReceipt `json:"intent"`
	}
	if json.Unmarshal(wire["pending_status"], &pending) != nil {
		t.Fatal("pending")
	}
	input := &hostNativeCompletionInput{claim: pending.Claim, intent: pending.Intent, request: hostNativeClaimRequest{Source: pending.Claim.Native.Source}}
	r, err := decodeHostNativeRegistration(wire["registration"], q, pending.Intent.Seq)
	if err != nil {
		t.Fatal(err)
	}
	status := wire["pending_status"]
	deps := hostNativeRegistrationDependencies{ledger: func(_ context.Context, op string, args any) (json.RawMessage, error) {
		if op != "rotation_status" || args.(map[string]any)["epoch"] != q.Epoch {
			t.Fatal("exact epoch missing")
		}
		return status, nil
	}}
	if err := verifyHostNativeLedgerRetryPending(context.Background(), deps, input, q, &r); err != nil {
		t.Fatal("C++ pending ACK refused", err)
	}
	if err := verifyHostNativeLedgerRetryPending(context.Background(), deps, input, q, nil); err == nil {
		t.Fatal("registered source permitted registration retry")
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(status, &fields)
	delete(fields, "registration")
	status, _ = json.Marshal(fields)
	if err := verifyHostNativeLedgerRetryPending(context.Background(), deps, input, q, nil); err != nil {
		t.Fatal("C++ pending registration refused", err)
	}
	if !strings.Contains(string(status), "18446744073709551615") {
		t.Fatal("uint64 fixture rounded")
	}
}
func TestHostNativeLedgerRetryNeverRecreatesMissingMarker(t *testing.T) {
	h := nativeRegistrationFixture(t)
	h.lost = true
	h.mutation = "missing_registration"
	h.deps.ledger = nativeRetryPendingLedger(t, h.claim, h.deps.ledger, nil)
	if _, err := h.run(); err == nil {
		t.Fatal("lost accepted")
	}
	path := h.phasePath("registration_requested")
	raw, _ := os.ReadFile(path)
	var phase hostNativeRegistrationPhase
	if json.Unmarshal(raw, &phase) != nil {
		t.Fatal("phase")
	}
	input, err := readHostNativeCompletionInput(h.host.dir, h.claim.request.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if authorizeHostNativeRegistrationRetry(input, phase) == nil {
		t.Fatal("missing marker authorized retry")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("retry recreated marker")
	}
	if _, err := os.Stat(filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.SessionID+".active.json")); err != nil {
		t.Fatal("fence removed")
	}
}

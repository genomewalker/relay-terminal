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

type nativeRetirementHarness struct {
	*nativeAckHarness
	deps     hostNativeRetirementDependencies
	calls    int
	mutation string
	retired  bool
}

func nativeRetirementFixture(t *testing.T) *nativeRetirementHarness {
	t.Helper()
	h := &nativeRetirementHarness{nativeAckHarness: nativeAckFixture(t)}
	if _, err := h.nativeAckHarness.run(); err != nil {
		t.Fatal(err)
	}
	h.deps.hostNativeRegistrationDependencies = h.nativeAckHarness.deps
	h.deps.retire = func(ctx context.Context, e hostRotationEnrollment, r nativeRotationCompletion) (nativeRotationReply, error) {
		if ctx.Err() != nil {
			return nativeRotationReply{}, ctx.Err()
		}
		h.calls++
		if e != h.host.source.Enrollment || r != h.receipt {
			t.Fatal("native retirement identity changed")
		}
		if _, err := os.Stat(h.phasePath("native_ack_requested")); err != nil {
			t.Fatal("native call preceded durable request")
		}
		reply := nativeRotationReply{Version: 1, State: "acknowledged", OperationID: r.OperationID, HostClaimID: r.HostClaimID}
		switch h.mutation {
		case "lost":
			h.retired = true
			return nativeRotationReply{}, errors.New("lost retirement reply")
		case "pending":
			reply.State = "pending"
		case "wrong_operation":
			reply.OperationID = r.HostClaimID
		case "wrong_claim":
			reply.HostClaimID = r.OperationID
		case "wrong_version":
			reply.Version = 0
		case "extra_receipt":
			reply.Completion = &r
		case "native_changed":
			writeNativeCompletionJSON(t, filepath.Join(r.JournalDirectory, "sealed.json"), map[string]any{})
		case "host_changed":
			writeNativeCompletionJSON(t, h.phasePath("ledger_ack_received"), map[string]any{})
		case "ledger_changed":
			h.nativeAckHarness.mutation = "claim_open"
		case "target_changed":
			h.nativeRegistrationHarness.mutation = "wrong_owner"
		}
		h.retired = true
		return reply, nil
	}
	return h
}
func (h *nativeRetirementHarness) run() (*hostNativeRetirementProof, error) {
	return retireHostNativeCompletion(context.Background(), h.host.dir, h.claim.request.SessionID, h.deps)
}
func TestHostNativeRetirementDurableAndIdempotent(t *testing.T) {
	h := nativeRetirementFixture(t)
	first, err := h.run()
	if err != nil {
		t.Fatal(err)
	}
	again, err := h.run()
	if err != nil || !reflect.DeepEqual(first, again) || h.calls != 1 {
		t.Fatal("durable retirement replayed", err)
	}
	if !h.retired || first.State != "native_retired" {
		t.Fatal("retirement not confirmed")
	}
	raw, err := os.ReadFile(h.phasePath("native_retired"))
	var saved hostNativeRetirementProof
	if err != nil || decodeHostNativeRecord(raw, &saved) != nil || saved != *first {
		t.Fatal("retirement not durable")
	}
	if h.nativeAckHarness.calls != 1 || h.nativeRegistrationHarness.calls != 1 {
		t.Fatal("retirement replayed ledger mutations")
	}
	h.unchangedFence(t)
}
func TestHostNativeRetirementLostReplyRetriesExactAcknowledgment(t *testing.T) {
	for _, name := range []string{"lost", "pending"} {
		t.Run(name, func(t *testing.T) {
			h := nativeRetirementFixture(t)
			h.mutation = name
			if _, err := h.run(); err == nil {
				t.Fatal("uncertain retirement accepted")
			}
			if _, err := os.Stat(h.phasePath("native_retired")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("uncertain retirement recorded")
			}
			before, err := os.ReadFile(h.phasePath("native_ack_requested"))
			if err != nil {
				t.Fatal(err)
			}
			h.mutation = ""
			if _, err := h.run(); err != nil {
				t.Fatal("exact duplicate retirement not recovered", err)
			}
			after, _ := os.ReadFile(h.phasePath("native_ack_requested"))
			if string(before) != string(after) || h.calls != 2 {
				t.Fatal("retirement identity replaced")
			}
			if _, err := h.run(); err != nil || h.calls != 2 {
				t.Fatal("completed retirement repeated", err)
			}
			h.unchangedFence(t)
		})
	}
}
func TestHostNativeRetirementRequiresDurableLedgerAck(t *testing.T) {
	for _, name := range []string{"missing_ack", "partial_ack", "missing_ack_request", "changed_ack", "owner", "binding",
		"partial_native_request", "partial_native_receipt", "orphan_native_receipt", "cancelled", "nil_native"} {
		t.Run(name, func(t *testing.T) {
			h := nativeRetirementFixture(t)
			switch name {
			case "missing_ack":
				if err := os.Remove(h.phasePath("ledger_ack_received")); err != nil {
					t.Fatal(err)
				}
			case "partial_ack":
				if err := os.WriteFile(h.phasePath("ledger_ack_received"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "missing_ack_request":
				if err := os.Remove(h.phasePath("ledger_ack_requested")); err != nil {
					t.Fatal(err)
				}
			case "changed_ack":
				raw, _ := os.ReadFile(h.phasePath("ledger_ack_received"))
				var p hostNativeAckPhase
				if json.Unmarshal(raw, &p) != nil {
					t.Fatal("ACK")
				}
				p.Ack.HostClaimID = h.claim.request.Epoch
				writeNativeCompletionJSON(t, h.phasePath("ledger_ack_received"), p)
			case "owner":
				h.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) {
					return "", errors.New("owner changed")
				}
			case "binding":
				h.deps.binding = func(hostRotationEnrollment, nativeRotationCompletion) (string, error) { return "different", nil }
			case "partial_native_request":
				if err := os.WriteFile(h.phasePath("native_ack_requested"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "partial_native_receipt":
				if err := os.WriteFile(h.phasePath("native_retired"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "orphan_native_receipt":
				input, err := readHostNativeRetirementInput(h.host.dir, h.claim.request.SessionID)
				if err != nil {
					t.Fatal(err)
				}
				writeNativeCompletionJSON(t, h.phasePath("native_retired"), hostNativeRetirementPhase(input, "native_retired"))
			case "nil_native":
				h.deps.retire = nil
			case "cancelled":
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				if _, err := retireHostNativeCompletion(ctx, h.host.dir, h.claim.request.SessionID, h.deps); err == nil {
					t.Fatal("cancelled")
				}
				if h.calls != 0 {
					t.Fatal("cancelled submitted")
				}
				return
			}
			if _, err := h.run(); err == nil {
				t.Fatal("unproven native retirement accepted")
			}
			if h.calls != 0 {
				t.Fatal("invalid evidence reached native retirement")
			}
			if _, err := os.Stat(filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.SessionID+".active.json")); err != nil {
				t.Fatal("fence removed")
			}
		})
	}
}
func TestHostNativeRetirementRefusesChangedReplyAndPostAckEvidence(t *testing.T) {
	for _, name := range []string{"wrong_operation", "wrong_claim", "wrong_version", "extra_receipt", "native_changed", "host_changed", "ledger_changed", "target_changed"} {
		t.Run(name, func(t *testing.T) {
			h := nativeRetirementFixture(t)
			h.mutation = name
			if _, err := h.run(); err == nil {
				t.Fatal("conflicting native retirement accepted")
			}
			if _, err := os.Stat(h.phasePath("native_retired")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("conflicting retirement recorded")
			}
			if _, err := os.Stat(filepath.Join(h.host.dir, hostNativeClaimDirectory, h.claim.request.SessionID+".active.json")); err != nil {
				t.Fatal("fence removed")
			}
		})
	}
}
func TestHostNativeRetirementRetryRejectsChangedDurableIdentity(t *testing.T) {
	h := nativeRetirementFixture(t)
	h.mutation = "lost"
	if _, err := h.run(); err == nil {
		t.Fatal("lost reply accepted")
	}
	raw, _ := os.ReadFile(h.phasePath("native_ack_requested"))
	var p hostNativeRetirementProof
	if json.Unmarshal(raw, &p) != nil {
		t.Fatal("request")
	}
	p.HostClaimID = p.OperationID
	writeNativeCompletionJSON(t, h.phasePath("native_ack_requested"), p)
	h.mutation = ""
	if _, err := h.run(); err == nil || h.calls != 1 {
		t.Fatal("changed identity repeated")
	}
	h.unchangedFence(t)
}
func TestNativeRotationRetirementBridgeUsesOnlyExactAck(t *testing.T) {
	bridge, peer := nativeRotationTestBridge(t)
	source := "00000000-0000-0000-0000-000000000701"
	operation := "00000000-0000-0000-0000-000000000801"
	claim := "00000000-0000-0000-0000-000000000802"
	if _, err := bridge.acknowledgeNativeCommit(context.Background(), source, operation, operation); err == nil {
		t.Fatal("invalid identity")
	}
	type result struct {
		reply nativeRotationReply
		err   error
	}
	for i := 0; i < 2; i++ {
		done := make(chan result, 1)
		go func() {
			r, e := bridge.acknowledgeNativeCommit(context.Background(), source, operation, claim)
			done <- result{r, e}
		}()
		command := nativeWireCommand(t, peer)
		if command.Operation != "acknowledge" || command.ThreadID != source || command.OperationID != operation ||
			command.HostClaimID != claim || command.Commit != nil || command.ReservationID != "" {
			t.Fatal("unexpected native operation")
		}
		raw, _ := json.Marshal(nativeRotationReply{Version: 1, ID: command.ID, State: "acknowledged", OperationID: operation, HostClaimID: claim})
		if err := bridge.receive(raw); err != nil {
			t.Fatal(err)
		}
		r := <-done
		if r.err != nil || r.reply.State != "acknowledged" {
			t.Fatal("native ACK unavailable", r.err)
		}
	}
}

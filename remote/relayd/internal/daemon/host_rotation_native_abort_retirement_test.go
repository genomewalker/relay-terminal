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

type nativeAbortRetirementHarness struct {
	*nativeAbortHarness
	deps           hostNativeAbortRetirementDependencies
	retireCalls    int
	retired        bool
	retireMutation string
}

func nativeAbortRetirementFixture(t *testing.T) *nativeAbortRetirementHarness {
	t.Helper()
	h := &nativeAbortRetirementHarness{nativeAbortHarness: nativeAbortFixture(t)}
	if _, err := h.nativeAbortHarness.run(); err != nil {
		t.Fatal(err)
	}
	h.deps.hostNativeAbortDependencies = h.nativeAbortHarness.deps
	h.deps.retire = func(ctx context.Context, e hostRotationEnrollment, r hostNativeRefusalRecord) (nativeRotationReply, error) {
		if err := ctx.Err(); err != nil {
			return nativeRotationReply{}, err
		}
		h.retireCalls++
		if e != h.host.source.Enrollment || r != h.receipt {
			t.Fatal("refusal retirement source changed")
		}
		raw, err := os.ReadFile(h.phase("native_abort_ack_requested"))
		input, readErr := readHostNativeAbortRetirementInput(h.host.dir, h.claim.request.SessionID)
		if err != nil || readErr != nil || !hostNativeRegistrationExactShape(raw, hostNativeAbortRetirementPhase(input, "native_abort_ack_requested")) {
			t.Fatal("native refusal ACK preceded exact durable intent", err, readErr)
		}
		reply := nativeRotationReply{Version: 1, State: "acknowledged", OperationID: r.OperationID, HostClaimID: r.ClaimID}
		h.retired = true
		switch h.retireMutation {
		case "lost":
			return nativeRotationReply{}, errors.New("ACK reply lost")
		case "pending":
			reply.State = "pending"
		case "operation":
			reply.OperationID = r.ClaimID
		case "claim":
			reply.HostClaimID = r.OperationID
		case "version":
			reply.Version = 0
		case "source":
			reply.Source = &r.Source
		case "journal":
			reply.JournalDirectory = h.path
		case "native_changed":
			writeNativeCompletionJSON(t, filepath.Join(h.path, "refused.json"), map[string]any{})
		case "host_changed":
			writeNativeCompletionJSON(t, h.phase("ledger_abort_received"), map[string]any{})
		case "ledger_changed":
			h.nativeAbortHarness.mutation = "claim_open"
		}
		return reply, nil
	}
	return h
}
func (h *nativeAbortRetirementHarness) run() (*hostNativeAbortRetirementProof, error) {
	return retireHostNativeRefusal(context.Background(), h.host.dir, h.claim.request.SessionID, h.deps)
}
func (h *nativeAbortRetirementHarness) noRetired(t *testing.T) {
	t.Helper()
	if _, err := os.Stat(h.phase("native_abort_retired")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unverified retirement recorded", err)
	}
	h.unchanged(t)
}
func TestHostNativeAbortRetirementDurableAndIdempotent(t *testing.T) {
	h := nativeAbortRetirementFixture(t)
	first, err := h.run()
	if err != nil || first == nil {
		t.Fatal(err)
	}
	info, err := os.Stat(h.phase("native_abort_retired"))
	if err != nil {
		t.Fatal(err)
	}
	again, err := h.run()
	if err != nil || !reflect.DeepEqual(first, again) || h.retireCalls != 1 || h.calls != 1 {
		t.Fatal("retirement replayed external work", err)
	}
	after, err := os.Stat(h.phase("native_abort_retired"))
	if err != nil || !os.SameFile(info, after) {
		t.Fatal("retirement replaced proof", err)
	}
	if !h.retired || first.State != "native_abort_retired" || first.SessionID != h.receipt.Source.ThreadID {
		t.Fatal("source retirement not bound")
	}
	h.unchanged(t)
}
func TestHostNativeAbortRetirementLostReplyRetriesExactAck(t *testing.T) {
	for _, mode := range []string{"lost", "pending"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeAbortRetirementFixture(t)
			h.retireMutation = mode
			if _, err := h.run(); err == nil {
				t.Fatal("uncertain ACK completed")
			}
			h.noRetired(t)
			before, err := os.ReadFile(h.phase("native_abort_ack_requested"))
			if err != nil {
				t.Fatal(err)
			}
			h.retireMutation = ""
			if _, err := h.run(); err != nil || h.retireCalls != 2 || h.calls != 1 {
				t.Fatal("exact ACK retry failed", err)
			}
			after, _ := os.ReadFile(h.phase("native_abort_ack_requested"))
			if string(before) != string(after) {
				t.Fatal("retry request changed")
			}
			h.unchanged(t)
		})
	}
}
func TestHostNativeAbortRetirementRequiresDurableAbort(t *testing.T) {
	for _, mode := range []string{"missing_requested", "missing_received", "partial_received", "receipt_changed", "partial_ack", "orphan_retired", "owner", "ledger", "cancelled"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeAbortRetirementFixture(t)
			ctx := context.Background()
			switch mode {
			case "missing_requested":
				if err := os.Remove(h.phase("ledger_abort_requested")); err != nil {
					t.Fatal(err)
				}
			case "missing_received":
				if err := os.Remove(h.phase("ledger_abort_received")); err != nil {
					t.Fatal(err)
				}
			case "partial_received":
				if err := os.WriteFile(h.phase("ledger_abort_received"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "receipt_changed":
				raw, _ := os.ReadFile(h.phase("ledger_abort_received"))
				var p hostNativeAbortPhase
				if json.Unmarshal(raw, &p) != nil {
					t.Fatal("fixture")
				}
				p.Abort.Seq++
				writeNativeCompletionJSON(t, h.phase("ledger_abort_received"), p)
			case "partial_ack":
				if err := os.WriteFile(h.phase("native_abort_ack_requested"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "orphan_retired":
				if err := os.WriteFile(h.phase("native_abort_retired"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "owner":
				h.deps.owner = func(hostRotationEnrollment, hostNativeRefusalRecord) error { return errors.New("owner changed") }
			case "ledger":
				h.nativeAbortHarness.mutation = "claim_open"
			case "cancelled":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			if r, err := retireHostNativeRefusal(ctx, h.host.dir, h.claim.request.SessionID, h.deps); err == nil || r != nil || h.retireCalls != 0 {
				t.Fatal("unproven retirement submitted", err)
			}
			if mode != "orphan_retired" {
				h.noRetired(t)
			} else {
				h.unchanged(t)
			}
		})
	}
}
func TestHostNativeAbortRetirementRejectsReplyAndPostAckChanges(t *testing.T) {
	for _, mode := range []string{"operation", "claim", "version", "source", "journal", "native_changed", "host_changed", "ledger_changed", "owner_changed", "cancelled"} {
		t.Run(mode, func(t *testing.T) {
			h := nativeAbortRetirementFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch mode {
			case "owner_changed":
				h.deps.owner = func(e hostRotationEnrollment, r hostNativeRefusalRecord) error {
					if h.retired {
						return errors.New("owner changed")
					}
					return h.owner(e, r)
				}
			case "cancelled":
				base := h.deps.retire
				h.deps.retire = func(ctx context.Context, e hostRotationEnrollment, r hostNativeRefusalRecord) (nativeRotationReply, error) {
					reply, err := base(ctx, e, r)
					cancel()
					return reply, err
				}
			default:
				h.retireMutation = mode
			}
			if r, err := retireHostNativeRefusal(ctx, h.host.dir, h.claim.request.SessionID, h.deps); err == nil || r != nil || h.retireCalls != 1 {
				t.Fatal("conflicting ACK completed", err)
			}
			h.noRetired(t)
		})
	}
}
func TestHostNativeAbortRetirementRetryRejectsChangedMarker(t *testing.T) {
	h := nativeAbortRetirementFixture(t)
	h.retireMutation = "lost"
	if _, err := h.run(); err == nil {
		t.Fatal("lost reply accepted")
	}
	raw, _ := os.ReadFile(h.phase("native_abort_ack_requested"))
	var p hostNativeAbortRetirementProof
	if json.Unmarshal(raw, &p) != nil {
		t.Fatal("fixture")
	}
	p.HostClaimID = p.OperationID
	writeNativeCompletionJSON(t, h.phase("native_abort_ack_requested"), p)
	h.retireMutation = ""
	if _, err := h.run(); err == nil || h.retireCalls != 1 {
		t.Fatal("changed request replayed")
	}
	h.noRetired(t)
}
func TestHostNativeAbortRetirementBridgeKeepsSourceAndOnlyAcknowledges(t *testing.T) {
	bridge, peer := nativeRotationTestBridge(t)
	h := nativeAbortFixture(t)
	r := h.receipt
	done := make(chan error, 1)
	go func() {
		_, err := bridge.acknowledgeNativeCommit(context.Background(), r.Source.ThreadID, r.OperationID, r.ClaimID)
		done <- err
	}()
	q := nativeWireCommand(t, peer)
	if q.Operation != "acknowledge" || q.ThreadID != r.Source.ThreadID || q.OperationID != r.OperationID || q.HostClaimID != r.ClaimID ||
		q.Commit != nil || q.ReservationID != "" {
		t.Fatal("ACK attempted another native operation")
	}
	raw, _ := json.Marshal(nativeRotationReply{Version: 1, ID: q.ID, State: "acknowledged", OperationID: r.OperationID, HostClaimID: r.ClaimID})
	if err := bridge.receive(raw); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	h.unchanged(t)
}

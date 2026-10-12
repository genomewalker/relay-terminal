package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func nativeIntentFixture(request hostNativeIntentRequest, claim hostNativeClaimReceipt) hostNativeIntentReceipt {
	return hostNativeIntentReceipt{1, "native_v1", request.SessionID, request.Epoch, request.Epoch,
		request.HostClaimID, request.ClaimID, request.Token, request.Epoch, request.RequestSHA256, claim.Seq + 1, "commit_requested"}
}
func nativeCommitFixture(t *testing.T) (*nativeClaimHarness, *hostNativeRotationClaim, *int) {
	t.Helper()
	h := newNativeClaimHarness(t)
	c, err := h.acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	calls := new(int)
	previous := c.deps.ledger
	c.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if op != "rotation_native_intent" {
			return previous(ctx, op, args)
		}
		*calls++
		r := args.(hostNativeIntentRequest)
		if r != (hostNativeIntentRequest{1, c.request.SessionID, c.request.Epoch, c.receipt.ClaimID, c.receipt.Token, c.request.HostClaimID, c.journal.requestSHA256}) {
			t.Fatal("commit changed identity")
		}
		deadline, ok := ctx.Deadline()
		if !ok || deadline.After(c.lease.deadline) {
			t.Fatal("commit extended original reservation")
		}
		raw, err := os.ReadFile(filepath.Join(h.dir, hostNativeClaimDirectory, c.request.Epoch+".commit_requested.json"))
		var marker hostNativeClaimPhase
		if err != nil || decodeHostNativeRecord(raw, &marker) != nil || marker.State != "commit_requested" ||
			marker.Claim == nil || *marker.Claim != c.receipt || marker.RequestSHA256 != r.RequestSHA256 {
			t.Fatal("intent RPC preceded exact durable marker")
		}
		return json.Marshal(nativeIntentFixture(r, c.receipt))
	}
	return h, c, calls
}
func nativeCommitFence(t *testing.T, h *nativeClaimHarness, c *hostNativeRotationClaim) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(h.dir, hostNativeClaimDirectory, c.request.SessionID+".active.json")); err != nil {
		t.Fatal("commit lost active fence", err)
	}
	got, err := inspectHostNativeClaim(context.Background(), h.dir, c.request.SessionID,
		func(context.Context, string, any) (json.RawMessage, error) {
			t.Fatal("commit recovery invoked ledger")
			return nil, nil
		})
	if err != nil || got.State != "commit_pending" {
		t.Fatalf("commit recovery: %+v %v", got, err)
	}
	if c.release(context.Background()) == nil || h.releaseCalls != 0 || h.nativeReleases != 0 {
		t.Fatal("commit attempted release")
	}
}
func TestHostNativeCommitIntentDurableOneShotRetainsOriginalLease(t *testing.T) {
	h, c, calls := nativeCommitFixture(t)
	deadline, lease := c.lease.deadline, c.lease
	got, err := c.requestCommitIntent(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if *calls != 1 || got.State != "commit_requested" || c.intent == nil || *c.intent != got ||
		c.lease != lease || !c.lease.deadline.Equal(deadline) || !c.lease.validFor(h.source.Enrollment, h.source.Boundary.TurnID) {
		t.Fatal("intent lost exact live capability")
	}
	data, err := os.ReadFile(filepath.Join(h.dir, hostNativeClaimDirectory, c.request.Epoch+".intent_received.json"))
	var phase hostNativeIntentPhase
	if err != nil || decodeHostNativeRecord(data, &phase) != nil || phase.Intent != got {
		t.Fatal("intent not persisted")
	}
	if _, err := c.requestCommitIntent(context.Background()); err == nil || *calls != 1 {
		t.Fatal("intent replayed")
	}
	nativeCommitFence(t, h, c)
	request := c.request
	request.Epoch, _ = newHostNativeUUID()
	request.HostClaimID, _ = newHostNativeUUID()
	request.Claimant = "relay:" + request.Epoch
	if next, err := beginHostNativeClaim(h.dir, request); err == nil || next != nil || h.claimCalls != 1 {
		t.Fatal("pending commit reacquired")
	}
}
func TestHostNativeCommitRefusesChangedAdmissionBeforeIntent(t *testing.T) {
	for _, name := range []string{"guard", "source", "capsule", "request", "expiry", "lease_expiry", "revoked", "owner", "missing_guard", "missing_verify", "cancel", "reservation", "source_binding"} {
		t.Run(name, func(t *testing.T) {
			h, c, calls := nativeCommitFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch name {
			case "guard":
				h.blockGuard = true
			case "source":
				h.failRevalidateAt = 3
			case "capsule":
				c.capsule += "changed"
			case "request":
				c.request.LeaseMS--
			case "expiry":
				c.receipt.ExpiresAtMS = time.Now().Add(-time.Second).UnixMilli()
			case "lease_expiry":
				c.lease.deadline = time.Now().Add(-time.Second)
			case "revoked":
				h.bridge.mu.Lock()
				h.bridge.revokeLocked()
				h.bridge.mu.Unlock()
			case "owner":
				c.deps.verify = func(hostRotationEnrollment, *hostNativeRotationLease) error { return errors.New("owner changed") }
			case "missing_guard":
				c.guard = nil
			case "missing_verify":
				c.deps.verify = nil
			case "cancel":
				cancel()
			case "reservation":
				c.lease.native.RuntimeID = c.request.Epoch
			case "source_binding":
				c.source.BindingRevision = "changed"
			}
			if _, err := c.requestCommitIntent(ctx); err == nil || *calls != 0 || c.commitAttempted {
				t.Fatal("invalid admission reached commit")
			}
			if _, err := os.Stat(filepath.Join(h.dir, hostNativeClaimDirectory, c.request.Epoch+".commit_requested.json")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("invalid admission wrote commit")
			}
		})
	}
}
func TestHostNativeCommitUncertaintyKeepsFenceWithoutReplay(t *testing.T) {
	for _, name := range []string{"lost", "misbound", "oversize", "guard_after", "source_after", "expired_after", "revoked_after", "cancel_after", "phase_write"} {
		t.Run(name, func(t *testing.T) {
			h, c, calls := nativeCommitFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			original := c.deps.ledger
			c.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
				raw, err := original(ctx, op, args)
				if op != "rotation_native_intent" {
					return raw, err
				}
				switch name {
				case "lost":
					return nil, errors.New("lost")
				case "misbound":
					var result hostNativeIntentReceipt
					_ = json.Unmarshal(raw, &result)
					result.Token++
					return json.Marshal(result)
				case "oversize":
					return json.RawMessage(strings.Repeat(" ", hostNativeClaimRecordLimit+1)), nil
				case "guard_after":
					h.blockGuard = true
				case "source_after":
					h.failRevalidateAt = 4
				case "expired_after":
					c.lease.deadline = time.Now().Add(-time.Second)
				case "revoked_after":
					h.bridge.mu.Lock()
					h.bridge.revokeLocked()
					h.bridge.mu.Unlock()
				case "cancel_after":
					cancel()
				case "phase_write":
					if err := os.WriteFile(filepath.Join(h.dir, hostNativeClaimDirectory, c.request.Epoch+".intent_received.json"), []byte("{"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				return raw, err
			}
			if _, err := c.requestCommitIntent(ctx); err == nil || *calls != 1 || c.intent != nil {
				t.Fatal("uncertain intent accepted")
			}
			if _, err := c.requestCommitIntent(context.Background()); err == nil || *calls != 1 {
				t.Fatal("uncertain intent replayed")
			}
			nativeCommitFence(t, h, c)
		})
	}
}
func TestHostNativeCommitJournalRefusesConflictingOrPartialPhases(t *testing.T) {
	for _, name := range []string{"claim_uncertain", "release_requested", "released", "commit_requested", "intent_received", "claim_received", "active", "request"} {
		t.Run(name, func(t *testing.T) {
			h, c, calls := nativeCommitFixture(t)
			suffix := name
			id := c.request.Epoch
			if name == "active" {
				id = c.request.SessionID
			}
			if err := os.WriteFile(filepath.Join(h.dir, hostNativeClaimDirectory, id+"."+suffix+".json"), []byte("{"), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := c.requestCommitIntent(context.Background()); err == nil || *calls != 0 || !c.commitAttempted {
				t.Fatal("unsafe journal authorized intent")
			}
			if _, err := c.requestCommitIntent(context.Background()); err == nil || *calls != 0 {
				t.Fatal("partial attempt replayed")
			}
		})
	}
}
func TestHostNativeCommitIntentReceiptStrictShape(t *testing.T) {
	_, c, _ := nativeCommitFixture(t)
	request := hostNativeIntentRequest{1, c.request.SessionID, c.request.Epoch, c.receipt.ClaimID, c.receipt.Token, c.request.HostClaimID, c.journal.requestSHA256}
	raw, _ := json.Marshal(nativeIntentFixture(request, c.receipt))
	for _, name := range []string{"missing", "null", "alias", "unknown", "duplicate", "fraction", "overflow", "old_seq", "state", "digest", "intent", "host"} {
		t.Run(name, func(t *testing.T) {
			var fields map[string]json.RawMessage
			_ = json.Unmarshal(raw, &fields)
			var bad []byte
			switch name {
			case "missing":
				delete(fields, "token")
			case "null":
				fields["token"] = json.RawMessage("null")
			case "alias":
				fields["Token"] = fields["token"]
				delete(fields, "token")
			case "unknown":
				fields["extra"] = json.RawMessage("true")
			case "duplicate":
				bad = []byte(strings.TrimSuffix(string(raw), "}") + `,"v":1}`)
			case "fraction":
				fields["v"] = json.RawMessage("1.0")
			case "overflow":
				fields["token"] = json.RawMessage("18446744073709551616")
			case "old_seq":
				fields["seq"], _ = json.Marshal(c.receipt.Seq)
			case "state":
				fields["state"] = json.RawMessage(`"acknowledged"`)
			case "digest":
				fields["request_sha256"], _ = json.Marshal(strings.Repeat("f", 64))
			case "intent":
				fields["intent_id"], _ = json.Marshal(c.request.HostClaimID)
			case "host":
				fields["host_claim_id"], _ = json.Marshal(c.request.Epoch)
			}
			if bad == nil {
				bad, _ = json.Marshal(fields)
			}
			if _, err := decodeHostNativeIntent(bad, request, c.receipt); err == nil {
				t.Fatal("invalid intent accepted")
			}
		})
	}
}
func TestHostNativeCommitAndReleaseHaveOneWinner(t *testing.T) {
	for i := 0; i < 8; i++ {
		h, c, calls := nativeCommitFixture(t)
		var group sync.WaitGroup
		group.Add(2)
		go func() { defer group.Done(); _, _ = c.requestCommitIntent(context.Background()) }()
		go func() { defer group.Done(); _ = c.release(context.Background()) }()
		group.Wait()
		if *calls+h.releaseCalls != 1 {
			t.Fatal("commit and release both executed or neither executed")
		}
		if *calls == 1 {
			nativeCommitFence(t, h, c)
		} else if h.nativeReleases != 1 {
			t.Fatal("release lost cleanup")
		}
	}
}

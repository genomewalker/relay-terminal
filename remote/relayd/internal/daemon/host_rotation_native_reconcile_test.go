package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestHostNativeClaimReconcileConfirmedReleaseWithoutReplayingLedger(t *testing.T) {
	for _, phaseSaved := range []bool{false, true} {
		name := "lost_response"
		if phaseSaved {
			name = "lost_unlink"
		}
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			c, err := h.acquire(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			h.lostRelease = true
			if c.release(context.Background()) == nil {
				t.Fatal("fixture lost release accepted")
			}
			receipt := h.receipt
			receipt.Closed = true
			receipt.ReleaseSeq = receipt.Seq + 1
			root := filepath.Join(h.dir, hostNativeClaimDirectory)
			if phaseSaved {
				data, _ := json.Marshal(hostNativeClaimPhase{1, "released", c.journal.requestSHA256, &receipt})
				if err := os.WriteFile(filepath.Join(root, h.request.Epoch+".released.json"), data, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			before := nativeRecoveryFiles(t, h)
			calls := 0
			ledger := func(_ context.Context, op string, args any) (json.RawMessage, error) {
				calls++
				r, ok := args.(hostNativeStatusRequest)
				if op != "rotation_status" || !ok || r.Epoch != h.request.Epoch {
					t.Fatal("reconciliation submitted mutation or wrong epoch")
				}
				return json.Marshal(nativeRecoveryStatus(h, &receipt))
			}
			got, err := reconcileHostNativeRelease(context.Background(), h.dir, h.request.SessionID, ledger)
			if err != nil || got.State != "release_reconciled" || calls != 1 || h.releaseCalls != 1 || h.nativeReleases != 1 {
				t.Fatalf("reconciliation: %+v %v calls %d", got, err, calls)
			}
			after := nativeRecoveryFiles(t, h)
			if _, ok := after[h.request.SessionID+".active.json"]; ok {
				t.Fatal("confirmed release retained active")
			}
			if _, ok := after[h.request.Epoch+".released.json"]; !ok {
				t.Fatal("released evidence missing")
			}
			for name, data := range before {
				if name == h.request.SessionID+".active.json" {
					continue
				}
				if after[name] != data {
					t.Fatal("reconciliation changed immutable evidence")
				}
			}
			got, err = reconcileHostNativeRelease(context.Background(), h.dir, h.request.SessionID, ledger)
			if err != nil || got.State != "no_active_claim" || calls != 1 {
				t.Fatal("completed release repeated ledger read/action")
			}
			// A later operation gets new native/host/ledger identities.
			h.lostRelease = false
			next, err := h.acquire(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if next.request.Epoch == c.request.Epoch || next.receipt.Token <= c.receipt.Token {
				t.Fatal("reconciliation reused operation")
			}
			if err := next.release(context.Background()); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestHostNativeClaimReconcileKeepsAllUnprovenFences(t *testing.T) {
	for _, name := range []string{"absent", "expired", "open", "unconfirmed_release", "closed_without_intent", "native_intent", "lost_status", "cancelled"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			lost := name == "absent" || name == "expired" || name == "open" || name == "closed_without_intent"
			h.lostClaim = lost
			c, err := h.acquire(context.Background())
			if lost {
				if err == nil || c != nil {
					t.Fatal("lost claim accepted")
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if name == "unconfirmed_release" {
				h.lostRelease = true
				if c.release(context.Background()) == nil {
					t.Fatal("lost release accepted")
				}
			}
			receipt := h.receipt
			var claim *hostNativeClaimReceipt = &receipt
			switch name {
			case "absent":
				claim = nil
			case "expired":
				receipt.ExpiresAtMS = time.Now().Add(-time.Second).UnixMilli()
			case "closed_without_intent":
				receipt.Closed = true
				receipt.ReleaseSeq = receipt.Seq + 1
			}
			status := nativeRecoveryStatus(h, claim)
			if name == "native_intent" {
				status["intent"] = map[string]any{"v": 1}
			}
			before := nativeRecoveryFiles(t, h)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := 0
			got, err := reconcileHostNativeRelease(ctx, h.dir, h.request.SessionID,
				func(_ context.Context, op string, _ any) (json.RawMessage, error) {
					calls++
					if op != "rotation_status" {
						t.Fatal("unexpected ledger mutation")
					}
					if name == "lost_status" {
						return nil, errors.New("lost read")
					}
					if name == "cancelled" {
						cancel()
					}
					return json.Marshal(status)
				})
			if calls != 1 || got.State == "release_reconciled" || !reflect.DeepEqual(before, nativeRecoveryFiles(t, h)) {
				t.Fatalf("unproven state cleared: %+v %v", got, err)
			}
		})
	}
}

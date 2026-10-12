package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func nativeRecoveryStatus(h *nativeClaimHarness, receipt *hostNativeClaimReceipt) map[string]any {
	return map[string]any{"v": 1, "session_id": h.request.SessionID, "epoch": h.request.Epoch,
		"client": "codex", "cwd": h.request.Source.Enrollment.CWD, "owner": "relay", "signal": nil,
		"turn_seq": h.request.Source.TurnSeq, "claim": receipt,
		"live":    receipt != nil && !receipt.Closed && receipt.ExpiresAtMS > time.Now().UnixMilli(),
		"capsule": nil, "intent": nil, "ack": nil, "lifecycle_performed": false,
		"new_session_id": nil, "usage_history": []any{}}
}

func nativeRecoveryFiles(t *testing.T, h *nativeClaimHarness) map[string]string {
	t.Helper()
	root := filepath.Join(h.dir, hostNativeClaimDirectory)
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	result := make(map[string]string)
	for _, entry := range entries {
		if entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		result[entry.Name()] = string(data)
	}
	return result
}

func nativeRecoveryInspect(t *testing.T, h *nativeClaimHarness, status map[string]any) (hostNativeClaimRecovery, error) {
	t.Helper()
	before := nativeRecoveryFiles(t, h)
	claimCalls, releaseCalls, nativeReleases := h.claimCalls, h.releaseCalls, h.nativeReleases
	calls := 0
	result, err := inspectHostNativeClaim(context.Background(), h.dir, h.request.SessionID,
		func(_ context.Context, op string, args any) (json.RawMessage, error) {
			calls++
			r, ok := args.(hostNativeStatusRequest)
			if op != "rotation_status" || !ok || r.Version != 1 ||
				r.SessionID != h.request.SessionID || r.Epoch != h.request.Epoch {
				t.Fatal("recovery did not use exact epoch read")
			}
			return json.Marshal(status)
		})
	if calls != 1 {
		t.Fatalf("recovery status calls %d", calls)
	}
	if !reflect.DeepEqual(before, nativeRecoveryFiles(t, h)) || claimCalls != h.claimCalls ||
		releaseCalls != h.releaseCalls || nativeReleases != h.nativeReleases {
		t.Fatal("read-only recovery mutated or acted")
	}
	return result, err
}

func TestHostNativeClaimRecoveryObservesLostClaimWithoutRestoringCapability(t *testing.T) {
	for _, name := range []string{"open", "expired", "absent", "closed_without_intent"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			h.lostClaim = true
			if c, err := h.acquire(context.Background()); err == nil || c != nil {
				t.Fatal("fixture lost response was accepted")
			}
			receipt := h.receipt
			var claim *hostNativeClaimReceipt = &receipt
			want := "claim_open"
			switch name {
			case "expired":
				receipt.ExpiresAtMS = time.Now().Add(-time.Second).UnixMilli()
				want = "claim_expired"
			case "absent":
				claim = nil
				want = "claim_not_observed"
			case "closed_without_intent":
				receipt.Closed = true
				receipt.ReleaseSeq = receipt.Seq + 1
				want = "closed_without_release_intent"
			}
			got, err := nativeRecoveryInspect(t, h, nativeRecoveryStatus(h, claim))
			if err != nil || got.State != want || got.OperationID != h.request.Epoch {
				t.Fatalf("recovery: %+v %v", got, err)
			}
			// Even absence/expiry cannot clear a pending claim or create a new operation.
			if c, err := h.acquire(context.Background()); err == nil || c != nil || h.claimCalls != 1 {
				t.Fatal("recovery released the unresolved fence")
			}
		})
	}
}

func TestHostNativeClaimRecoveryObservesLostReleaseAndDurableCompletion(t *testing.T) {
	for _, name := range []string{"unconfirmed", "confirmed", "phase_before_unlink"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			c, err := h.acquire(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			h.lostRelease = true
			if c.release(context.Background()) == nil {
				t.Fatal("lost release accepted")
			}
			receipt := h.receipt
			want := "release_unconfirmed"
			if name != "unconfirmed" {
				receipt.Closed = true
				receipt.ReleaseSeq = receipt.Seq + 1
				want = "release_confirmed"
			}
			if name == "phase_before_unlink" {
				root := filepath.Join(h.dir, hostNativeClaimDirectory)
				data, _ := json.Marshal(hostNativeClaimPhase{1, "released", c.journal.requestSHA256, &receipt})
				if err := os.WriteFile(filepath.Join(root, h.request.Epoch+".released.json"), data, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			got, err := nativeRecoveryInspect(t, h, nativeRecoveryStatus(h, &receipt))
			if err != nil || got.State != want {
				t.Fatalf("%+v %v", got, err)
			}
			if c.release(context.Background()) == nil || h.releaseCalls != 1 {
				t.Fatal("recovery enabled release replay")
			}
		})
	}
}

func TestHostNativeClaimRecoveryRetainsCommitAndNativeTransactionFences(t *testing.T) {
	for _, name := range []string{"host_commit", "ledger_intent", "ledger_ack"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			c, err := h.acquire(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			status := nativeRecoveryStatus(h, &h.receipt)
			if name == "host_commit" {
				path := filepath.Join(h.dir, hostNativeClaimDirectory, h.request.Epoch+".commit_requested.json")
				if err := os.WriteFile(path, []byte("{\"v\":1}"), 0o600); err != nil {
					t.Fatal(err)
				}
				before := nativeRecoveryFiles(t, h)
				got, err := inspectHostNativeClaim(context.Background(), h.dir, h.request.SessionID,
					func(context.Context, string, any) (json.RawMessage, error) {
						t.Fatal("commit boundary queried reservation cleanup")
						return nil, nil
					})
				if err != nil || got.State != "commit_pending" || !reflect.DeepEqual(before, nativeRecoveryFiles(t, h)) {
					t.Fatalf("%+v %v", got, err)
				}
				if c.release(context.Background()) == nil || h.releaseCalls != 0 {
					t.Fatal("commit fence released")
				}
			} else {
				if name == "ledger_intent" {
					status["intent"] = map[string]any{"v": 1}
				} else {
					status["ack"] = map[string]any{"v": 1}
					status["lifecycle_performed"] = true
					status["new_session_id"] = "destination"
				}
				got, err := nativeRecoveryInspect(t, h, status)
				if err != nil || got.State != "native_transaction_pending" || got.Receipt != nil {
					t.Fatalf("%+v %v", got, err)
				}
			}
		})
	}
}

func TestHostNativeClaimRecoveryRefusesChangedOrAmbiguousLedger(t *testing.T) {
	for _, name := range []string{"epoch", "owner", "cwd", "session", "old_turn", "missing_live", "null_live", "unknown_field",
		"wrong_claim", "missing_claim", "wrong_expiry", "closed_live", "missing_lifecycle", "unknown_nested", "null_generation"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			_, err := h.acquire(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			status := nativeRecoveryStatus(h, &h.receipt)
			switch name {
			case "epoch":
				status["epoch"] = "another"
			case "owner":
				status["owner"] = "desktop"
			case "cwd":
				status["cwd"] = "/elsewhere"
			case "session":
				status["session_id"] = "another"
			case "old_turn":
				status["turn_seq"] = 0
			case "missing_live":
				delete(status, "live")
			case "null_live":
				status["live"] = nil
			case "unknown_field":
				status["unknown"] = false
			case "wrong_claim":
				r := h.receipt
				r.HostClaimID = r.OperationID
				status["claim"] = r
			case "missing_claim":
				status["claim"] = nil
				status["live"] = false
			case "wrong_expiry":
				r := h.receipt
				r.ExpiresAtMS++
				status["claim"] = r
			case "closed_live":
				r := h.receipt
				r.Closed = true
				r.ReleaseSeq = r.Seq + 1
				status["claim"] = r
				status["live"] = true
			case "missing_lifecycle":
				delete(status, "lifecycle_performed")
			case "unknown_nested", "null_generation":
				raw, _ := json.Marshal(h.receipt)
				var r map[string]any
				_ = json.Unmarshal(raw, &r)
				reservation := r["native"].(map[string]any)["reservation"].(map[string]any)
				if name == "unknown_nested" {
					reservation["extra"] = true
				} else {
					reservation["frontend"].(map[string]any)["generation"] = nil
				}
				status["claim"] = r
			}
			got, err := nativeRecoveryInspect(t, h, status)
			if err == nil || got.State != "unresolved" || got.Receipt != nil {
				t.Fatalf("bad status accepted: %+v %v", got, err)
			}
		})
	}
}

func TestHostNativeClaimRecoveryRefusesMalformedJournalWithoutRPC(t *testing.T) {
	for _, name := range []string{"partial_active", "active_hash", "request_missing_field", "request_unknown", "request_null",
		"request_uuid", "request_generation", "request_capsule", "phase_request", "phase_claim", "phase_missing",
		"unmatched_release", "unmatched_released", "missing_lock", "symlink", "hardlink", "public"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			c, err := h.acquire(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(h.dir, hostNativeClaimDirectory)
			active := filepath.Join(root, h.request.SessionID+".active.json")
			request := filepath.Join(root, h.request.Epoch+".request.json")
			phase := filepath.Join(root, h.request.Epoch+".claim_received.json")
			write := func(path string, value any) {
				data, e := json.Marshal(value)
				if e != nil {
					t.Fatal(e)
				}
				if e = os.WriteFile(path, data, 0o600); e != nil {
					t.Fatal(e)
				}
			}
			switch name {
			case "partial_active":
				err = os.WriteFile(active, []byte("{"), 0o600)
			case "active_hash":
				write(active, hostNativeClaimActive{1, h.request.Epoch, strings.Repeat("a", 64)})
			case "request_missing_field", "request_unknown", "request_null", "request_uuid", "request_generation", "request_capsule":
				data, _ := os.ReadFile(request)
				var r map[string]any
				_ = json.Unmarshal(data, &r)
				switch name {
				case "request_missing_field":
					delete(r, "v")
				case "request_unknown":
					r["other"] = true
				case "request_null":
					r["lease_ms"] = nil
				case "request_uuid":
					r["host_claim_id"] = r["epoch"]
				case "request_generation":
					r["reservation"].(map[string]any)["frontend"].(map[string]any)["generation"] = "01"
				case "request_capsule":
					r["capsule"].(map[string]any)["bytes"] = 20000
				}
				data, _ = json.Marshal(r)
				err = os.WriteFile(request, data, 0o600)
				write(active, hostNativeClaimActive{1, h.request.Epoch, hostRotationCapsuleHash(data)})
			case "phase_request":
				write(phase, hostNativeClaimPhase{1, "claim_received", strings.Repeat("b", 64), &h.receipt})
			case "phase_claim":
				r := h.receipt
				r.Token++
				write(phase, hostNativeClaimPhase{1, "claim_received", c.journal.requestSHA256, &r})
			case "phase_missing":
				write(phase, map[string]any{"v": 1, "state": "claim_received", "request_sha256": c.journal.requestSHA256})
			case "unmatched_release":
				r := h.receipt
				r.ExpiresAtMS++
				write(filepath.Join(root, h.request.Epoch+".release_requested.json"), hostNativeClaimPhase{1, "release_requested", c.journal.requestSHA256, &r})
			case "unmatched_released":
				r := h.receipt
				r.Closed = true
				r.ReleaseSeq = r.Seq + 1
				write(filepath.Join(root, h.request.Epoch+".released.json"), hostNativeClaimPhase{1, "released", c.journal.requestSHA256, &r})
			case "missing_lock":
				err = os.Remove(filepath.Join(root, "lock"))
			case "symlink":
				err = os.Rename(request, request+".saved")
				if err == nil {
					err = os.Symlink(request+".saved", request)
				}
			case "hardlink":
				err = os.Link(phase, phase+".alias")
			case "public":
				err = os.Chmod(phase, 0o644)
			}
			if err != nil {
				t.Fatal(err)
			}
			before := nativeRecoveryFiles(t, h)
			got, err := inspectHostNativeClaim(context.Background(), h.dir, h.request.SessionID,
				func(context.Context, string, any) (json.RawMessage, error) {
					t.Fatal("invalid journal reached RPC")
					return nil, nil
				})
			if err == nil || got.State != "unresolved" || !reflect.DeepEqual(before, nativeRecoveryFiles(t, h)) {
				t.Fatalf("invalid journal accepted/changed: %+v %v", got, err)
			}
		})
	}
}

func TestHostNativeClaimRecoveryRejectsConcurrentChangeCancellationAndLostRead(t *testing.T) {
	for _, name := range []string{"phase_change", "active_removed", "cancelled", "lost_status", "duplicate_status"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			c, err := h.acquire(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			got, err := inspectHostNativeClaim(ctx, h.dir, h.request.SessionID,
				func(context.Context, string, any) (json.RawMessage, error) {
					switch name {
					case "phase_change":
						if err := c.journal.record("release_requested", &c.receipt); err != nil {
							t.Fatal(err)
						}
					case "active_removed":
						if err := os.Remove(filepath.Join(h.dir, hostNativeClaimDirectory, h.request.SessionID+".active.json")); err != nil {
							t.Fatal(err)
						}
					case "cancelled":
						cancel()
					case "lost_status":
						return nil, errors.New("lost read")
					}
					raw, _ := json.Marshal(nativeRecoveryStatus(h, &h.receipt))
					if name == "duplicate_status" {
						raw = append(raw[:len(raw)-1], []byte(",\"live\":true}")...)
					}
					return raw, nil
				})
			if err == nil || got.State != "unresolved" || got.Receipt != nil || h.claimCalls != 1 || h.releaseCalls != 0 {
				t.Fatalf("unsafe recovery result: %+v %v", got, err)
			}
		})
	}
}

func TestHostNativeClaimRecoveryRecognizesCompletedReleaseWithoutRPC(t *testing.T) {
	h := newNativeClaimHarness(t)
	c, err := h.acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := c.release(context.Background()); err != nil {
		t.Fatal(err)
	}
	before := nativeRecoveryFiles(t, h)
	got, err := inspectHostNativeClaim(context.Background(), h.dir, h.request.SessionID,
		func(context.Context, string, any) (json.RawMessage, error) {
			t.Fatal("no active claim queried ledger")
			return nil, nil
		})
	if err != nil || got.State != "no_active_claim" || !reflect.DeepEqual(before, nativeRecoveryFiles(t, h)) {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestHostNativeClaimHistoricalIdentityCannotPassLiveAdmission(t *testing.T) {
	h := newNativeClaimHarness(t)
	c, err := h.acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	r := c.receipt
	r.ExpiresAtMS = time.Now().Add(-time.Second).UnixMilli()
	raw, _ := json.Marshal(r)
	if _, err := decodeHostNativeClaimIdentity(raw, c.request, false); err != nil {
		t.Fatal(err)
	}
	if _, err := decodeHostNativeClaim(raw, c.request, false); err == nil {
		t.Fatal("historical receipt revived live admission")
	}
	r.ExpiresAtMS = 0
	raw, _ = json.Marshal(r)
	if _, err := decodeHostNativeClaimIdentity(raw, c.request, false); err == nil {
		t.Fatal("invalid expiry accepted")
	}
}

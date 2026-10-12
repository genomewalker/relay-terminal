package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type nativeClaimHarness struct {
	dir              string
	source           hostRotationSource
	prepared         hostRotationPreparation
	deps             hostNativeClaimDependencies
	bridge           *hostNativeRotationBridge
	peer             net.Conn
	prepareCalls     int
	claimCalls       int
	releaseCalls     int
	nativeReleases   int
	revalidations    int
	failRevalidateAt int
	blockGuard       bool
	lostClaim        bool
	lostRelease      bool
	badClaim         bool
	phaseFailure     bool
	afterPrepare     func(*hostNativeRotationLease)
	afterClaim       func()
	request          hostNativeClaimRequest
	receipt          hostNativeClaimReceipt
}

func nativeClaimFixtureReceipt(request hostNativeClaimRequest, seq uint64) hostNativeClaimReceipt {
	return hostNativeClaimReceipt{Version: 1, Mode: "native_v1", SessionID: request.SessionID, Epoch: request.Epoch,
		OperationID: request.Epoch, HostClaimID: request.HostClaimID, ClaimID: request.SessionID + ":" + uintString(seq),
		Claimant: request.Claimant, Token: seq, Seq: seq, ExpectedSeq: request.Source.TurnSeq,
		ExpiresAtMS: time.Now().Add(time.Duration(request.LeaseMS) * time.Millisecond).UnixMilli(),
		Native:      hostNativeClaimBinding{request.Source, request.Capsule, request.Reservation}}
}

func uintString(value uint64) string {
	data, _ := json.Marshal(value)
	return string(data)
}

func newNativeClaimHarness(t *testing.T) *nativeClaimHarness {
	t.Helper()
	h := &nativeClaimHarness{dir: capsuleWorkerDirectory(t), source: capsuleSourceFixture()}
	h.source.Enrollment.Client = "codex"
	h.source.Enrollment.SessionID = "00000000-0000-0000-0000-000000000701"
	h.source.Boundary.TurnID = "turn-1"
	draft := preparationDraftFixture()
	capsule, err := stageHostRotationCapsule(context.Background(), h.dir, h.source, draft)
	if err != nil {
		t.Fatal(err)
	}
	h.prepared = hostRotationPreparation{Version: 1, State: "prepared", TurnSeq: h.source.Boundary.TurnSeq,
		TurnID: h.source.Boundary.TurnID, SourceSHA256: h.source.TranscriptSHA256, EvidenceSHA256: h.source.EvidenceSHA256,
		BindingRevision: h.source.BindingRevision, SourceChunks: len(h.source.Chunks), Draft: &draft, Capsule: capsule}
	bridge, peer := nativeRotationTestBridge(t)
	h.bridge = bridge
	h.peer = peer
	bridge.providerPID = h.source.Enrollment.AgentPID
	bridge.providerStart = h.source.Enrollment.AgentStart
	h.deps.status = func(context.Context, hostRotationEnrollment) (json.RawMessage, error) {
		status := preparationStatusFixture(h.source.Enrollment)
		status["usage_history"].([]any)[0].(map[string]any)["turn_id"] = h.source.Boundary.TurnID
		return json.Marshal(status)
	}
	h.deps.policy = func(context.Context, json.RawMessage, time.Time) (json.RawMessage, error) {
		return json.RawMessage(`{"v":1,"decision":"rotate"}`), nil
	}
	h.deps.collect = func(context.Context, hostRotationEnrollment, hostRotationSourceBoundary) (hostRotationSource, error) {
		return h.source, nil
	}
	h.deps.revalidate = func(ctx context.Context, _ hostRotationSource) error {
		h.revalidations++
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if h.failRevalidateAt > 0 && h.revalidations >= h.failRevalidateAt {
			return errors.New("fixture source changed")
		}
		return nil
	}
	h.deps.verify = func(hostRotationEnrollment, *hostNativeRotationLease) error { return nil }
	h.deps.prepare = func(context.Context, hostRotationEnrollment, string) (*hostNativeRotationLease, error) {
		h.prepareCalls++
		lease := nativeRotationTestPrepare(t, bridge, peer)
		if h.afterPrepare != nil {
			h.afterPrepare(lease)
		}
		return lease, nil
	}
	h.deps.releaseNative = func(_ context.Context, lease *hostNativeRotationLease) error {
		h.nativeReleases++
		bridge.mu.Lock()
		defer bridge.mu.Unlock()
		if bridge.active == lease {
			bridge.revokeLocked()
		}
		return nil
	}
	h.deps.ledger = func(_ context.Context, operation string, args any) (json.RawMessage, error) {
		switch operation {
		case "rotation_native_claim":
			h.claimCalls++
			h.request = args.(hostNativeClaimRequest)
			root := filepath.Join(h.dir, hostNativeClaimDirectory)
			data, err := os.ReadFile(filepath.Join(root, h.request.SessionID+".active.json"))
			var active hostNativeClaimActive
			if err != nil || json.Unmarshal(data, &active) != nil || active.OperationID != h.request.Epoch {
				t.Fatal("RPC preceded durable source reservation")
			}
			data, err = os.ReadFile(filepath.Join(root, h.request.Epoch+".request.json"))
			if err != nil || hostRotationCapsuleHash(data) != active.RequestSHA256 {
				t.Fatal("RPC preceded durable exact request")
			}
			h.receipt = nativeClaimFixtureReceipt(h.request, h.source.Boundary.TurnSeq+uint64(2*h.claimCalls-1))
			if h.lostClaim {
				return nil, errors.New("fixture lost claim response")
			}
			result := h.receipt
			if h.badClaim {
				result.HostClaimID = result.OperationID
			}
			if h.phaseFailure {
				if err := os.WriteFile(filepath.Join(root, h.request.Epoch+".claim_received.json"), []byte("{"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if h.afterClaim != nil {
				h.afterClaim()
			}
			return json.Marshal(result)
		case "rotation_native_release":
			h.releaseCalls++
			request := args.(hostNativeReleaseRequest)
			if request.SessionID != h.request.SessionID || request.Epoch != h.request.Epoch ||
				request.ClaimID != h.receipt.ClaimID || request.Token != h.receipt.Token || request.HostClaimID != h.request.HostClaimID {
				t.Fatal("release changed claim identity")
			}
			path := filepath.Join(h.dir, hostNativeClaimDirectory, h.request.Epoch+".release_requested.json")
			if _, err := os.Stat(path); err != nil {
				t.Fatal("release RPC preceded durable intent")
			}
			if h.lostRelease {
				return nil, errors.New("fixture lost release response")
			}
			result := h.receipt
			result.Closed = true
			result.ReleaseSeq = result.Seq + 1
			return json.Marshal(result)
		default:
			t.Fatal("unexpected ledger operation")
			return nil, nil
		}
	}
	return h
}

func (h *nativeClaimHarness) guard() error {
	if h.blockGuard {
		return errors.New("fixture human takeover")
	}
	return nil
}
func (h *nativeClaimHarness) acquire(ctx context.Context) (*hostNativeRotationClaim, error) {
	return acquireHostNativeClaim(ctx, h.dir, h.source.Enrollment, h.prepared, h.guard, h.deps)
}

func TestHostNativeClaimAcquiresExactCapsuleAndReleasesDurably(t *testing.T) {
	h := newNativeClaimHarness(t)
	claim, err := h.acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(*h.prepared.Draft)
	if claim.capsule != string(body) || !claim.lease.validFor(h.source.Enrollment, h.source.Boundary.TurnID) ||
		claim.receipt.Native.Source != h.request.Source || h.claimCalls != 1 || h.nativeReleases != 0 {
		t.Fatal("native claim lost exact capability or bytes")
	}
	if err := claim.release(context.Background()); err != nil {
		t.Fatal(err)
	}
	if h.releaseCalls != 1 || h.nativeReleases != 1 {
		t.Fatal("release count")
	}
	root := filepath.Join(h.dir, hostNativeClaimDirectory)
	if _, err := os.Stat(filepath.Join(root, h.request.SessionID+".active.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("confirmed release kept active source")
	}
	for _, phase := range []string{"request", "claim_received", "release_requested", "released"} {
		if _, err := os.Stat(filepath.Join(root, h.request.Epoch+"."+phase+".json")); err != nil {
			t.Fatal(err)
		}
	}
	if err := claim.release(context.Background()); err == nil || h.releaseCalls != 1 {
		t.Fatal("release replayed")
	}
	next, err := h.acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if next.request.Epoch == claim.request.Epoch || next.receipt.Token <= claim.receipt.Token {
		t.Fatal("next operation reused identity")
	}
	if err := next.release(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestHostNativeClaimRefusesBeforeLedgerWhenEvidenceChanges(t *testing.T) {
	for _, name := range []string{"draft", "source", "receipt", "policy", "guard", "journal", "revoked", "expired", "owner", "generation", "source_after_prepare"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			switch name {
			case "draft":
				h.prepared.Draft.Summary = "different draft"
			case "source":
				h.prepared.TurnID = "different"
			case "receipt":
				h.prepared.Capsule.SHA256 = strings.Repeat("f", 64)
			case "policy":
				h.deps.policy = func(context.Context, json.RawMessage, time.Time) (json.RawMessage, error) {
					return json.RawMessage(`{"v":1,"decision":"hold"}`), nil
				}
			case "guard":
				h.blockGuard = true
			case "journal":
				if err := os.WriteFile(filepath.Join(h.dir, hostNativeClaimDirectory), []byte("obstruction"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "revoked":
				h.afterPrepare = func(*hostNativeRotationLease) { h.bridge.mu.Lock(); h.bridge.revokeLocked(); h.bridge.mu.Unlock() }
			case "expired":
				h.afterPrepare = func(l *hostNativeRotationLease) { l.deadline = time.Now().Add(-time.Second) }
			case "owner":
				h.deps.verify = func(hostRotationEnrollment, *hostNativeRotationLease) error { return errors.New("changed owner") }
			case "generation":
				h.afterPrepare = func(l *hostNativeRotationLease) { l.native.AdmissionGeneration = "01" }
			case "source_after_prepare":
				h.failRevalidateAt = 1
			}
			if claim, err := h.acquire(context.Background()); err == nil || claim != nil {
				t.Fatal("unsafe claim acquired")
			}
			if h.claimCalls != 0 {
				t.Fatal("invalid source reached ledger")
			}
			if h.prepareCalls > 0 && h.nativeReleases != 1 {
				t.Fatal("native reservation not released exactly once")
			}
		})
	}
}

func TestHostNativeClaimUncertainOutcomeBlocksAnotherAttempt(t *testing.T) {
	for _, name := range []string{"lost", "misbound", "phase_failure"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			h.lostClaim = name == "lost"
			h.badClaim = name == "misbound"
			h.phaseFailure = name == "phase_failure"
			if claim, err := h.acquire(context.Background()); err == nil || claim != nil {
				t.Fatal("uncertain claim accepted")
			}
			if h.claimCalls != 1 || h.nativeReleases != 1 || h.releaseCalls != 0 {
				t.Fatal("uncertain claim repeated or wrong release")
			}
			if _, err := os.Stat(filepath.Join(h.dir, hostNativeClaimDirectory, h.request.SessionID+".active.json")); err != nil {
				t.Fatal("lost pending source")
			}
			if claim, err := h.acquire(context.Background()); err == nil || claim != nil {
				t.Fatal("uncertain source reacquired")
			}
			if h.claimCalls != 1 || h.nativeReleases != 2 {
				t.Fatal("fresh request replayed uncertain claim")
			}
		})
	}
}

func TestHostNativeClaimPostReceiptChangesReleaseWithoutReturningCapability(t *testing.T) {
	for _, name := range []string{"guard", "cancel", "revoked", "source"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			h.afterClaim = func() {
				switch name {
				case "guard":
					h.blockGuard = true
				case "cancel":
					cancel()
				case "revoked":
					h.bridge.mu.Lock()
					h.bridge.revokeLocked()
					h.bridge.mu.Unlock()
				case "source":
					h.failRevalidateAt = 2
				}
			}
			if claim, err := h.acquire(ctx); err == nil || claim != nil {
				t.Fatal("invalidated capability escaped")
			}
			if h.claimCalls != 1 || h.releaseCalls != 1 || h.nativeReleases != 1 {
				t.Fatalf("cleanup counts: claim=%d release=%d native=%d", h.claimCalls, h.releaseCalls, h.nativeReleases)
			}
			if _, err := os.Stat(filepath.Join(h.dir, hostNativeClaimDirectory, h.request.SessionID+".active.json")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("confirmed cancellation left active")
			}
		})
	}
}

func TestHostNativeClaimUncertainReleaseDoesNotReplay(t *testing.T) {
	h := newNativeClaimHarness(t)
	claim, err := h.acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	h.lostRelease = true
	if err := claim.release(context.Background()); err == nil {
		t.Fatal("lost release accepted")
	}
	if err := claim.release(context.Background()); err == nil {
		t.Fatal("release replayed")
	}
	if h.releaseCalls != 1 || h.nativeReleases != 1 {
		t.Fatal("uncertain release repeated")
	}
	if _, err := os.Stat(filepath.Join(h.dir, hostNativeClaimDirectory, h.request.SessionID+".active.json")); err != nil {
		t.Fatal("uncertain release erased active")
	}
}

func TestHostNativeClaimJournalExcludesConcurrentSourcesAndPreservesPartialFiles(t *testing.T) {
	h := newNativeClaimHarness(t)
	claim, err := h.acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	request := claim.request
	dir := capsuleWorkerDirectory(t)
	var wins atomic.Int32
	var workers sync.WaitGroup
	for i := 0; i < 16; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			req := request
			req.Epoch, _ = newHostNativeUUID()
			req.HostClaimID, _ = newHostNativeUUID()
			if _, err := beginHostNativeClaim(dir, req); err == nil {
				wins.Add(1)
			}
		}()
	}
	workers.Wait()
	if wins.Load() != 1 {
		t.Fatalf("journal winners %d", wins.Load())
	}
	if err := claim.release(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"partial_active", "partial_request", "symlink", "hardlink", "public", "commit_pending", "changed_active"} {
		t.Run(name, func(t *testing.T) {
			h := newNativeClaimHarness(t)
			c, err := h.acquire(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(h.dir, hostNativeClaimDirectory)
			active := filepath.Join(root, c.request.SessionID+".active.json")
			switch name {
			case "partial_active":
				err = os.WriteFile(active, []byte("{"), 0o600)
			case "partial_request":
				err = os.WriteFile(filepath.Join(root, c.request.Epoch+".request.json"), []byte("{"), 0o600)
			case "symlink":
				saved := filepath.Join(root, "saved")
				if err = os.Rename(active, saved); err == nil {
					err = os.Symlink(saved, active)
				}
			case "hardlink":
				err = os.Link(active, filepath.Join(root, "alias"))
			case "public":
				err = os.Chmod(active, 0o644)
			case "commit_pending":
				err = os.WriteFile(filepath.Join(root, c.request.Epoch+".commit_requested.json"), []byte(`{"v":1}`), 0o600)
			case "changed_active":
				data, _ := json.Marshal(hostNativeClaimActive{1, "11111111-1111-4111-8111-111111111111", strings.Repeat("a", 64)})
				err = os.WriteFile(active, data, 0o600)
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := c.release(context.Background()); err == nil {
				t.Fatal("unsafe journal authorized release")
			}
			if h.releaseCalls != 0 || h.nativeReleases != 1 {
				t.Fatal("unsafe journal reached ledger")
			}
		})
	}
}

func TestHostNativeClaimWireDecodingRejectsAmbiguousAndMissingFields(t *testing.T) {
	h := newNativeClaimHarness(t)
	c, err := h.acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(c.receipt)
	for _, name := range []string{"missing_closed", "null_closed", "extra", "duplicate", "wrong_runtime", "wrong_capsule", "huge_token"} {
		t.Run(name, func(t *testing.T) {
			var value map[string]json.RawMessage
			if err := json.Unmarshal(raw, &value); err != nil {
				t.Fatal(err)
			}
			var bad []byte
			switch name {
			case "missing_closed":
				delete(value, "closed")
			case "null_closed":
				value["closed"] = json.RawMessage("null")
			case "extra":
				value["extra"] = json.RawMessage("1")
			case "duplicate":
				bad = []byte(strings.TrimSuffix(string(raw), "}") + `,"closed":false}`)
			case "wrong_runtime":
				receipt := c.receipt
				receipt.Native.Reservation.Native.RuntimeID = receipt.OperationID
				bad, _ = json.Marshal(receipt)
			case "wrong_capsule":
				receipt := c.receipt
				receipt.Native.Capsule.Bytes++
				bad, _ = json.Marshal(receipt)
			case "huge_token":
				value["token"] = json.RawMessage("18446744073709551616")
			}
			if bad == nil {
				bad, _ = json.Marshal(value)
			}
			if _, err := decodeHostNativeClaim(bad, c.request, false); err == nil {
				t.Fatal("bad claim accepted")
			}
		})
	}
	envelope := []byte(`{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structured":{"value":{"ok":true}}}}`)
	if _, err := decodeHostNativeLedgerResponse(envelope); err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{
		`{"jsonrpc":"2.0","id":2,"result":{"structured":{"value":{}}}}`,
		`{"jsonrpc":"2.0","id":1,"id":1,"result":{"structured":{"value":{}}}}`,
		`{"jsonrpc":"2.0","id":1,"result":{"isError":true,"structured":{"value":{}}}}`,
		`{"jsonrpc":"2.0","id":1,"error":{"code":-1},"result":{"structured":{"value":{}}}}`,
		`{"jsonrpc":"2.0","id":1,"result":{"structured":{"value":null}}}`,
	} {
		if _, err := decodeHostNativeLedgerResponse([]byte(raw)); err == nil {
			t.Fatal("invalid envelope accepted")
		}
	}
	if err := c.release(context.Background()); err != nil {
		t.Fatal(err)
	}
}

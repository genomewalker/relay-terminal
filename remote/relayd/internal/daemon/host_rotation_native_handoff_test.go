package daemon

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestHostNativeHandoffPersistsExactIntentBeforeOriginalLease(t *testing.T) {
	h, c, calls := nativeCommitFixture(t)
	if _, err := c.requestCommitIntent(context.Background()); err != nil {
		t.Fatal(err)
	}
	lease, deadline := c.lease, c.lease.deadline
	submits := 0
	submit := func(ctx context.Context, actual *hostNativeRotationLease, envelope hostNativeCommitEnvelope) error {
		submits++
		if actual != lease || !actual.deadline.Equal(deadline) || envelope.Intent != *c.intent ||
			envelope.Reservation != c.request.Reservation || envelope.OperationID != c.request.Epoch ||
			envelope.HostClaimID != c.request.HostClaimID {
			t.Fatal("handoff lost original identity or lease")
		}
		capsule, err := base64.StdEncoding.Strict().DecodeString(envelope.CapsuleBase64)
		if err != nil || string(capsule) != c.capsule {
			t.Fatal("capsule changed")
		}
		raw, err := os.ReadFile(filepath.Join(h.dir, hostNativeClaimDirectory, c.request.Epoch+".native_handoff_requested.json"))
		var phase hostNativeHandoffPhase
		encoded, _ := json.Marshal(envelope)
		if err != nil || decodeHostNativeRecord(raw, &phase) != nil ||
			phase.State != "native_handoff_requested" || phase.Intent != *c.intent ||
			phase.RequestSHA256 != c.journal.requestSHA256 ||
			phase.EnvelopeSHA256 != hostRotationCapsuleHash(encoded) {
			t.Fatal("native callback preceded exact durable handoff")
		}
		return nil
	}
	if err := c.handoffNativeCommit(context.Background(), submit); err != nil {
		t.Fatal(err)
	}
	if err := c.handoffNativeCommit(context.Background(), submit); err == nil || submits != 1 || *calls != 1 {
		t.Fatal("native handoff replayed")
	}
	nativeCommitFence(t, h, c)
}

func TestHostNativeHandoffRejectsUnverifiedOrChangedIntent(t *testing.T) {
	for _, name := range []string{"no_intent", "missing_intent", "partial_intent", "changed_intent", "changed_capsule",
		"changed_reservation", "changed_guard", "cancelled", "partial_handoff", "changed_commit", "changed_claim"} {
		t.Run(name, func(t *testing.T) {
			h, c, calls := nativeCommitFixture(t)
			if name != "no_intent" {
				if _, err := c.requestCommitIntent(context.Background()); err != nil {
					t.Fatal(err)
				}
			}
			directory := filepath.Join(h.dir, hostNativeClaimDirectory)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch name {
			case "missing_intent":
				if err := os.Remove(filepath.Join(directory, c.request.Epoch+".intent_received.json")); err != nil {
					t.Fatal(err)
				}
			case "partial_intent":
				if err := os.WriteFile(filepath.Join(directory, c.request.Epoch+".intent_received.json"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "changed_intent":
				c.intent.Seq++
			case "changed_capsule":
				c.capsule += "changed"
			case "changed_reservation":
				c.lease.native.RuntimeID = c.request.Epoch
			case "changed_guard":
				h.blockGuard = true
			case "cancelled":
				cancel()
			case "partial_handoff":
				if err := os.WriteFile(filepath.Join(directory, c.request.Epoch+".native_handoff_requested.json"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "changed_commit":
				if err := os.WriteFile(filepath.Join(directory, c.request.Epoch+".commit_requested.json"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "changed_claim":
				if err := os.WriteFile(filepath.Join(directory, c.request.Epoch+".claim_received.json"), []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			submits := 0
			err := c.handoffNativeCommit(ctx, func(context.Context, *hostNativeRotationLease, hostNativeCommitEnvelope) error {
				submits++
				return nil
			})
			if err == nil || submits != 0 {
				t.Fatal("invalid handoff reached native callback")
			}
			expected := 1
			if name == "no_intent" {
				expected = 0
			}
			if *calls != expected {
				t.Fatal("handoff resubmitted ledger intent")
			}
			if _, err := os.Stat(filepath.Join(directory, c.request.SessionID+".active.json")); err != nil {
				t.Fatal("lost fence", err)
			}
		})
	}
}

func TestHostNativeHandoffLostReplyKeepsFenceWithoutReplay(t *testing.T) {
	h, c, _ := nativeCommitFixture(t)
	if _, err := c.requestCommitIntent(context.Background()); err != nil {
		t.Fatal(err)
	}
	submits := 0
	submit := func(context.Context, *hostNativeRotationLease, hostNativeCommitEnvelope) error {
		submits++
		return errors.New("reply lost")
	}
	err := c.handoffNativeCommit(context.Background(), submit)
	if err == nil || !strings.Contains(err.Error(), "reconciliation required") {
		t.Fatal("lost reply accepted", err)
	}
	if err := c.handoffNativeCommit(context.Background(), submit); err == nil || submits != 1 {
		t.Fatal("uncertain handoff replayed")
	}
	nativeCommitFence(t, h, c)
}

func TestHostNativeHandoffRevalidatesAfterDurableMarker(t *testing.T) {
	h, c, _ := nativeCommitFixture(t)
	if _, err := c.requestCommitIntent(context.Background()); err != nil {
		t.Fatal(err)
	}
	previous := c.deps.revalidate
	c.deps.revalidate = func(ctx context.Context, source hostRotationSource) error {
		if _, err := os.Stat(filepath.Join(h.dir, hostNativeClaimDirectory, c.request.Epoch+".native_handoff_requested.json")); err == nil {
			return errors.New("source changed after durable handoff")
		}
		return previous(ctx, source)
	}
	submits := 0
	submit := func(context.Context, *hostNativeRotationLease, hostNativeCommitEnvelope) error { submits++; return nil }
	if err := c.handoffNativeCommit(context.Background(), submit); err == nil || submits != 0 || !c.handoffAttempted {
		t.Fatal("changed source reached native")
	}
	if err := c.handoffNativeCommit(context.Background(), submit); err == nil || submits != 0 {
		t.Fatal("failed handoff replayed")
	}
	nativeCommitFence(t, h, c)
}

func TestHostNativeHandoffConcurrentCallsHaveOneSubmission(t *testing.T) {
	h, c, _ := nativeCommitFixture(t)
	if _, err := c.requestCommitIntent(context.Background()); err != nil {
		t.Fatal(err)
	}
	submits := 0
	submit := func(context.Context, *hostNativeRotationLease, hostNativeCommitEnvelope) error { submits++; return nil }
	var group sync.WaitGroup
	group.Add(2)
	for i := 0; i < 2; i++ {
		go func() { defer group.Done(); _ = c.handoffNativeCommit(context.Background(), submit) }()
	}
	group.Wait()
	if submits != 1 {
		t.Fatal("native handoff did not have one winner")
	}
	nativeCommitFence(t, h, c)
}

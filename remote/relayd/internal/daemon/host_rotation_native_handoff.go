package daemon

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"
	"unicode/utf8"
)

// The envelope describes a handoff. Only the accompanying original live lease
// can authorize the native foreground submission; this is not a completion.
type hostNativeCommitEnvelope struct {
	Version       int                       `json:"v"`
	OperationID   string                    `json:"operation_id"`
	HostClaimID   string                    `json:"host_claim_id"`
	ThreadID      string                    `json:"thread_id"`
	TurnID        string                    `json:"turn_id"`
	Reservation   hostNativeReservationPair `json:"reservation"`
	Intent        hostNativeIntentReceipt   `json:"intent"`
	CapsuleSHA256 string                    `json:"capsule_sha256"`
	CapsuleBase64 string                    `json:"capsule_base64"`
}

type hostNativeHandoffPhase struct {
	Version        int                     `json:"v"`
	State          string                  `json:"state"`
	RequestSHA256  string                  `json:"request_sha256"`
	EnvelopeSHA256 string                  `json:"envelope_sha256"`
	Intent         hostNativeIntentReceipt `json:"intent"`
}

// Shared admission checks are used both before ledger intent and before the
// native handoff. They do not grant any capability from persisted identifiers.
func (claim *hostNativeRotationClaim) checkNativeCommitAdmission(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := claim.guard(); err != nil {
		return err
	}
	r := claim.request
	binding, err := hostRotationCapsuleSource(claim.source)
	encoded, encodeErr := json.Marshal(r)
	if err != nil || encodeErr != nil || binding != r.Source ||
		validateHostNativeStoredRequest(r) != nil ||
		hostRotationCapsuleHash(encoded) != claim.journal.requestSHA256 ||
		claim.journal.sessionID != r.SessionID || claim.journal.operationID != r.Epoch ||
		len(claim.capsule) != r.Capsule.Bytes || hostRotationCapsuleHash([]byte(claim.capsule)) != r.Capsule.SHA256 {
		return errors.New("native commit source or capsule changed")
	}
	encoded, err = json.Marshal(claim.receipt)
	if err != nil {
		return err
	}
	if _, err := decodeHostNativeClaimIdentity(encoded, r, false); err != nil {
		return err
	}
	if claim.receipt.ExpiresAtMS <= time.Now().UnixMilli() ||
		!claim.lease.validFor(r.Source.Enrollment, r.Source.TurnID) ||
		claim.lease.native != r.Reservation.Native || claim.lease.frontend != r.Reservation.Frontend {
		return errors.New("native commit reservation expired or changed")
	}
	return claim.deps.verify(r.Source.Enrollment, claim.lease)
}

func (j *hostNativeClaimJournal) beginNativeHandoff(
	request hostNativeClaimRequest, claim hostNativeClaimReceipt, envelope hostNativeCommitEnvelope,
) error {
	root, lock, err := lockHostNativeClaimRoot(j.workerDirectory, false)
	if err != nil {
		return err
	}
	defer root.Close()
	defer lock.Close()
	if err := j.checkActive(root); err != nil {
		return err
	}
	encoded, err := json.Marshal(request)
	if err != nil || hostRotationCapsuleHash(encoded) != j.requestSHA256 ||
		request.SessionID != j.sessionID || request.Epoch != j.operationID ||
		validateHostNativeStoredRequest(request) != nil {
		return errors.New("native handoff request changed")
	}
	for _, state := range []string{"claim_uncertain", "release_requested", "released", "native_handoff_requested"} {
		_, err := readHostNativeClaimFile(root, j.operationID+"."+state+".json")
		if !errors.Is(err, os.ErrNotExist) {
			return errors.New("native handoff reconciliation required")
		}
	}
	for _, state := range []string{"claim_received", "commit_requested"} {
		raw, err := readHostNativeClaimFile(root, j.operationID+"."+state+".json")
		var phase hostNativeClaimPhase
		if err != nil || decodeHostNativeRecord(raw, &phase) != nil ||
			phase.Version != 1 || phase.State != state || phase.RequestSHA256 != j.requestSHA256 ||
			phase.Claim == nil || *phase.Claim != claim {
			return errors.New("native handoff lacks exact durable acquisition and commit intent")
		}
	}
	raw, err := readHostNativeClaimFile(root, j.operationID+".intent_received.json")
	var intent hostNativeIntentPhase
	if err != nil || decodeHostNativeRecord(raw, &intent) != nil ||
		intent.Version != 1 || intent.State != "intent_received" ||
		intent.RequestSHA256 != j.requestSHA256 || intent.Intent != envelope.Intent {
		return errors.New("native handoff durable intent changed")
	}
	intentRequest := hostNativeIntentRequest{1, request.SessionID, request.Epoch,
		claim.ClaimID, claim.Token, request.HostClaimID, j.requestSHA256}
	intentRaw, err := json.Marshal(intent.Intent)
	if err != nil {
		return err
	}
	if _, err := decodeHostNativeIntent(intentRaw, intentRequest, claim); err != nil {
		return err
	}
	capsule, err := base64.StdEncoding.Strict().DecodeString(envelope.CapsuleBase64)
	if err != nil || base64.StdEncoding.EncodeToString(capsule) != envelope.CapsuleBase64 ||
		!utf8.Valid(capsule) || bytes.IndexByte(capsule, 0) >= 0 || len(bytes.TrimSpace(capsule)) == 0 || len(capsule) != request.Capsule.Bytes ||
		hostRotationCapsuleHash(capsule) != request.Capsule.SHA256 ||
		envelope.Version != 1 || envelope.OperationID != request.Epoch ||
		envelope.HostClaimID != request.HostClaimID || envelope.ThreadID != request.SessionID ||
		envelope.TurnID != request.Source.TurnID || envelope.Reservation != request.Reservation ||
		envelope.CapsuleSHA256 != request.Capsule.SHA256 {
		return errors.New("native handoff envelope changed")
	}
	encoded, err = json.Marshal(envelope)
	if err != nil || len(encoded) > hostNativeClaimRecordLimit {
		return errors.New("native handoff envelope exceeds limit")
	}
	phase, err := json.Marshal(hostNativeHandoffPhase{1, "native_handoff_requested",
		j.requestSHA256, hostRotationCapsuleHash(encoded), intent.Intent})
	if err != nil {
		return err
	}
	return writeHostNativeClaimFile(root, j.operationID+".native_handoff_requested.json", phase, false)
}

// A nil result means only that the callback returned after the one-shot
// submission. Native completion, journal/process verification and ACK remain
// separate. In particular, neither success nor failure removes the active fence.
func (claim *hostNativeRotationClaim) handoffNativeCommit(ctx context.Context,
	submit func(context.Context, *hostNativeRotationLease, hostNativeCommitEnvelope) error,
) error {
	if claim == nil {
		return errors.New("native claim unavailable")
	}
	claim.mu.Lock()
	defer claim.mu.Unlock()
	if claim.releaseAttempted || !claim.commitAttempted || claim.handoffAttempted || claim.intent == nil {
		return errors.New("native handoff requires its original retained commit intent")
	}
	if submit == nil || claim.lease == nil || claim.journal == nil || claim.guard == nil ||
		claim.deps.verify == nil || claim.deps.revalidate == nil {
		return errors.New("native handoff dependencies unavailable")
	}
	admission, cancel := context.WithDeadline(ctx, claim.lease.deadline)
	defer cancel()
	if err := claim.checkNativeCommitAdmission(admission); err != nil {
		return err
	}
	if err := claim.deps.revalidate(admission, claim.source); err != nil {
		return err
	}
	if err := claim.checkNativeCommitAdmission(admission); err != nil {
		return err
	}
	envelope := hostNativeCommitEnvelope{1, claim.request.Epoch, claim.request.HostClaimID,
		claim.request.SessionID, claim.request.Source.TurnID, claim.request.Reservation, *claim.intent,
		claim.request.Capsule.SHA256, base64.StdEncoding.EncodeToString([]byte(claim.capsule))}
	// A partial marker write is uncertain. Do not permit another native submission.
	claim.handoffAttempted = true
	if err := claim.journal.beginNativeHandoff(claim.request, claim.receipt, envelope); err != nil {
		return err
	}
	if err := claim.checkNativeCommitAdmission(admission); err != nil {
		return err
	}
	if err := claim.deps.revalidate(admission, claim.source); err != nil {
		return err
	}
	if err := claim.checkNativeCommitAdmission(admission); err != nil {
		return err
	}
	// The original lease bounds admission. Once submitted, its expiry is not a
	// cancellation proof. The callback/foreground retains any uncertain outcome.
	if err := submit(ctx, claim.lease, envelope); err != nil {
		return fmt.Errorf("native handoff reconciliation required: %w", err)
	}
	return nil
}

package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
)

// Ledger identity is descriptive. Only the retained claim's real paired lease
// can be handed to a future foreground commit owner.
type hostNativeIntentRequest struct {
	Version       int    `json:"v"`
	SessionID     string `json:"session_id"`
	Epoch         string `json:"epoch"`
	ClaimID       string `json:"claim_id"`
	Token         uint64 `json:"token"`
	HostClaimID   string `json:"host_claim_id"`
	RequestSHA256 string `json:"request_sha256"`
}
type hostNativeIntentReceipt struct {
	Version       int    `json:"v"`
	Mode          string `json:"mode"`
	SessionID     string `json:"session_id"`
	Epoch         string `json:"epoch"`
	OperationID   string `json:"operation_id"`
	HostClaimID   string `json:"host_claim_id"`
	ClaimID       string `json:"claim_id"`
	Token         uint64 `json:"token"`
	IntentID      string `json:"intent_id"`
	RequestSHA256 string `json:"request_sha256"`
	Seq           uint64 `json:"seq"`
	State         string `json:"state"`
}
type hostNativeIntentPhase struct {
	Version       int                     `json:"v"`
	State         string                  `json:"state"`
	RequestSHA256 string                  `json:"request_sha256"`
	Intent        hostNativeIntentReceipt `json:"intent"`
}

func decodeHostNativeIntent(raw []byte, request hostNativeIntentRequest, claim hostNativeClaimReceipt) (hostNativeIntentReceipt, error) {
	var result hostNativeIntentReceipt
	if decodeHostNativeRecord(raw, &result) != nil || result.Version != 1 ||
		result.Mode != "native_v1" || result.State != "commit_requested" ||
		result.SessionID != request.SessionID || result.Epoch != request.Epoch ||
		result.OperationID != request.Epoch || result.IntentID != request.Epoch ||
		result.HostClaimID != request.HostClaimID || result.ClaimID != request.ClaimID ||
		result.Token != request.Token || result.RequestSHA256 != request.RequestSHA256 ||
		result.Seq <= claim.Seq {
		return hostNativeIntentReceipt{}, errors.New("native intent receipt mismatch")
	}
	return result, nil
}

// This one-shot marker precedes every external commit-intent submission. The
// existing active entry is never removed by this path, including on failure.
func (j *hostNativeClaimJournal) beginCommit(claim hostNativeClaimReceipt) error {
	root, lock, err := lockHostNativeClaimRoot(j.workerDirectory, false)
	if err != nil {
		return err
	}
	defer root.Close()
	defer lock.Close()
	if err := j.checkActive(root); err != nil {
		return err
	}
	for _, state := range []string{"claim_uncertain", "release_requested", "released", "commit_requested", "intent_received"} {
		_, err := readHostNativeClaimFile(root, j.operationID+"."+state+".json")
		if !errors.Is(err, os.ErrNotExist) {
			return errors.New("native transaction reconciliation required")
		}
	}
	raw, err := readHostNativeClaimFile(root, j.operationID+".claim_received.json")
	if err != nil {
		return err
	}
	var received hostNativeClaimPhase
	if decodeHostNativeRecord(raw, &received) != nil || received.Version != 1 ||
		received.State != "claim_received" || received.RequestSHA256 != j.requestSHA256 ||
		received.Claim == nil || *received.Claim != claim || claim.Closed ||
		claim.SessionID != j.sessionID || claim.Epoch != j.operationID || claim.OperationID != j.operationID {
		return errors.New("native commit lacks exact durable acquisition")
	}
	marker, err := json.Marshal(hostNativeClaimPhase{1, "commit_requested", j.requestSHA256, &claim})
	if err != nil {
		return err
	}
	return writeHostNativeClaimFile(root, j.operationID+".commit_requested.json", marker, false)
}

func (j *hostNativeClaimJournal) recordIntent(claim hostNativeClaimReceipt, intent hostNativeIntentReceipt) error {
	root, lock, err := lockHostNativeClaimRoot(j.workerDirectory, false)
	if err != nil {
		return err
	}
	defer root.Close()
	defer lock.Close()
	if err := j.checkActive(root); err != nil {
		return err
	}
	raw, err := readHostNativeClaimFile(root, j.operationID+".commit_requested.json")
	if err != nil {
		return err
	}
	var marker hostNativeClaimPhase
	if decodeHostNativeRecord(raw, &marker) != nil || marker.Version != 1 ||
		marker.State != "commit_requested" || marker.RequestSHA256 != j.requestSHA256 ||
		marker.Claim == nil || *marker.Claim != claim {
		return errors.New("native commit marker changed")
	}
	request := hostNativeIntentRequest{1, j.sessionID, j.operationID, claim.ClaimID, claim.Token, claim.HostClaimID, j.requestSHA256}
	encoded, err := json.Marshal(intent)
	if err != nil {
		return err
	}
	if _, err := decodeHostNativeIntent(encoded, request, claim); err != nil {
		return err
	}
	data, err := json.Marshal(hostNativeIntentPhase{1, "intent_received", j.requestSHA256, intent})
	if err != nil {
		return err
	}
	return writeHostNativeClaimFile(root, j.operationID+".intent_received.json", data, false)
}

// Internal preparation for the eventual foreground handoff. It submits no
// native close. A receipt cannot recreate the live lease after restart.
func (claim *hostNativeRotationClaim) requestCommitIntent(ctx context.Context) (hostNativeIntentReceipt, error) {
	var empty hostNativeIntentReceipt
	if claim == nil {
		return empty, errors.New("native claim unavailable")
	}
	claim.mu.Lock()
	defer claim.mu.Unlock()
	if claim.releaseAttempted || claim.commitAttempted {
		return empty, errors.New("native transaction reconciliation required")
	}
	if claim.lease == nil || claim.journal == nil || claim.guard == nil ||
		claim.deps.verify == nil || claim.deps.revalidate == nil || claim.deps.ledger == nil {
		return empty, errors.New("native commit dependencies unavailable")
	}
	callCtx, cancel := context.WithDeadline(ctx, claim.lease.deadline)
	defer cancel()
	watching := make(chan struct{})
	defer close(watching)
	go func() {
		select {
		case <-claim.lease.revoked:
			cancel()
		case <-callCtx.Done():
		case <-watching:
		}
	}()
	check := func() error { return claim.checkNativeCommitAdmission(callCtx) }
	if err := check(); err != nil {
		return empty, err
	}
	if err := claim.deps.revalidate(callCtx, claim.source); err != nil {
		return empty, err
	}
	if err := check(); err != nil {
		return empty, err
	}
	// Even a partial journal write or an uncertain RPC is one-shot.
	claim.commitAttempted = true
	if err := claim.journal.beginCommit(claim.receipt); err != nil {
		return empty, err
	}
	if err := check(); err != nil {
		return empty, err
	}
	request := hostNativeIntentRequest{1, claim.request.SessionID, claim.request.Epoch,
		claim.receipt.ClaimID, claim.receipt.Token, claim.request.HostClaimID, claim.journal.requestSHA256}
	raw, err := claim.deps.ledger(callCtx, "rotation_native_intent", request)
	if err != nil {
		return empty, errors.New("native commit intent reconciliation required")
	}
	receipt, err := decodeHostNativeIntent(raw, request, claim.receipt)
	if err != nil {
		return empty, err
	}
	if err := claim.journal.recordIntent(claim.receipt, receipt); err != nil {
		return empty, err
	}
	if err := check(); err != nil {
		return empty, err
	}
	if err := claim.deps.revalidate(callCtx, claim.source); err != nil {
		return empty, err
	}
	if err := check(); err != nil {
		return empty, err
	}
	claim.intent = &receipt
	return receipt, nil
}

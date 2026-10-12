package daemon

import (
	"context"
	"encoding/json"
	"errors"
)

// Reconcile only a release already proven by an exact ledger receipt and the
// original durable one-shot release request. Never submit a mutation to the
// ledger, reacquire a reservation, or infer cancellation from absence/expiry.
func reconcileHostNativeRelease(ctx context.Context, workerDirectory, sessionID string,
	ledger func(context.Context, string, any) (json.RawMessage, error)) (hostNativeClaimRecovery, error) {
	result, err := inspectHostNativeClaim(ctx, workerDirectory, sessionID, ledger)
	if err != nil || result.State != "release_confirmed" {
		return result, err
	}
	if ctx.Err() != nil {
		result.State = "unresolved"
		result.Receipt = nil
		return result, ctx.Err()
	}
	snapshot, err := readHostNativeClaimSnapshot(workerDirectory, sessionID)
	if err != nil || snapshot == nil || snapshot.commitPending ||
		snapshot.request.Epoch != result.OperationID || snapshot.journal.requestSHA256 != result.RequestSHA256 ||
		result.Receipt == nil {
		result.State = "unresolved"
		result.Receipt = nil
		return result, errors.New("native release changed before reconciliation")
	}
	release, ok := snapshot.phases["release_requested"]
	matching := *result.Receipt
	matching.Closed = false
	matching.ReleaseSeq = 0
	if !ok || release.Claim == nil || matching != *release.Claim {
		result.State = "unresolved"
		result.Receipt = nil
		return result, errors.New("native release lacks original durable intent")
	}
	if ctx.Err() != nil {
		result.State = "unresolved"
		result.Receipt = nil
		return result, ctx.Err()
	}
	// finishRelease rechecks the exact active/request/release identities and
	// the absence of commit intent while holding the local journal lock.
	if err := snapshot.journal.finishRelease(*result.Receipt); err != nil {
		result.State = "unresolved"
		result.Receipt = nil
		return result, err
	}
	result.State = "release_reconciled"
	return result, nil
}

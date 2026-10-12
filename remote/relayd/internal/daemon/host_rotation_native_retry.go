package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
)

// These ledger operations atomically return an existing identical result. A
// matching pending status permits repeating only the already durable request;
// it does not establish refusal of any previously submitted native operation.
func verifyHostNativeLedgerRetryPending(ctx context.Context, deps hostNativeRegistrationDependencies,
	input *hostNativeCompletionInput, q hostNativeRegistrationRequest, want *hostNativeRegistrationReceipt) error {
	raw, err := deps.ledger(ctx, "rotation_status", map[string]any{"session_id": q.SessionID, "epoch": q.Epoch})
	if err != nil {
		return err
	}
	var status struct {
		Version            int             `json:"v"`
		SessionID          string          `json:"session_id"`
		Epoch              string          `json:"epoch"`
		Client             string          `json:"client"`
		CWD                string          `json:"cwd"`
		Owner              string          `json:"owner"`
		Live               *bool           `json:"live"`
		LifecyclePerformed *bool           `json:"lifecycle_performed"`
		NewSessionID       json.RawMessage `json:"new_session_id"`
		Claim              json.RawMessage `json:"claim"`
		Intent             json.RawMessage `json:"intent"`
		Ack                json.RawMessage `json:"ack"`
		Registration       json.RawMessage `json:"registration"`
	}
	if len(raw) > 262144 || !rotationSourceJSONUnambiguous(raw) || json.Unmarshal(raw, &status) != nil ||
		status.Version != 1 || status.SessionID != q.SessionID || status.Epoch != q.Epoch || status.Client != "codex" ||
		status.CWD != input.request.Source.Enrollment.CWD || status.Owner != "relay" || status.Live == nil ||
		status.LifecyclePerformed == nil || *status.LifecyclePerformed || string(status.NewSessionID) != "null" ||
		string(status.Ack) != "null" {
		return errors.New("native ledger retry has no exact pending status")
	}
	var claim hostNativeClaimReceipt
	var intent hostNativeIntentReceipt
	if decodeHostNativeRecord(status.Claim, &claim) != nil || !hostNativeRegistrationExactShape(status.Claim, claim) ||
		decodeHostNativeRecord(status.Intent, &intent) != nil || !hostNativeRegistrationExactShape(status.Intent, intent) ||
		claim != input.claim || claim.Closed || intent != input.intent || intent.State != "commit_requested" {
		return errors.New("native ledger retry pending owner changed")
	}
	if want == nil {
		if len(status.Registration) != 0 && string(status.Registration) != "null" {
			return errors.New("native registration exists; reconcile its destination")
		}
	} else {
		registered, err := decodeHostNativeRegistration(status.Registration, q, input.intent.Seq)
		if err != nil || !reflect.DeepEqual(registered, *want) {
			return errors.New("native ledger retry registration changed")
		}
	}
	// Expiry of preparation is irrelevant to an exact idempotent ledger receipt.
	// The caller separately revalidates the restored target and native journals.
	return ctx.Err()
}

// Revalidate immutable local evidence under the same host lock immediately
// before a duplicate ledger request. Never create or replace a marker here.
func authorizeHostNativeLedgerRetry(workerDirectory, operationID, requestedState, receivedState string,
	expected any, verifyCurrent func(*os.File) error) error {
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return err
	}
	defer root.Close()
	defer lock.Close()
	if err := verifyCurrent(root); err != nil {
		return err
	}
	raw, err := readHostNativeClaimFile(root, operationID+"."+requestedState+".json")
	if err != nil || !hostNativeRegistrationExactShape(raw, expected) {
		return errors.New("native ledger retry request changed")
	}
	if _, err := readHostNativeClaimFile(root, operationID+"."+receivedState+".json"); !errors.Is(err, os.ErrNotExist) {
		return errors.New("native ledger receipt already exists; reconcile only")
	}
	return nil
}
func authorizeHostNativeRegistrationRetry(input *hostNativeCompletionInput, phase hostNativeRegistrationPhase) error {
	return authorizeHostNativeLedgerRetry(input.journal.workerDirectory, input.request.Epoch,
		"registration_requested", "registration_received", phase, func(root *os.File) error {
			current, err := readHostNativeCompletionInputAt(root, input.journal.workerDirectory, input.request.SessionID)
			if err != nil || current.fingerprint != input.fingerprint {
				return errors.New("native registration retry host intent changed")
			}
			raw, err := readHostNativeClaimFile(root, input.request.Epoch+".native_restored_verified.json")
			if err != nil || !hostNativeRegistrationExactShape(raw, phase.Completion) {
				return errors.New("native registration retry completion changed")
			}
			return nil
		})
}
func authorizeHostNativeAckRetry(input *hostNativeAckInput, phase hostNativeAckPhase) error {
	c := input.completion
	return authorizeHostNativeLedgerRetry(c.journal.workerDirectory, c.request.Epoch,
		"ledger_ack_requested", "ledger_ack_received", phase, func(root *os.File) error {
			current, err := readHostNativeAckInputAt(root, c.journal.workerDirectory, c.request.SessionID)
			if err != nil || current.fingerprint != input.fingerprint {
				return errors.New("native ACK retry registration changed")
			}
			return nil
		})
}

package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
)

type hostNativeRetirementInput struct {
	ack         *hostNativeAckInput
	receipt     hostNativeAckReceipt
	fingerprint string
}
type hostNativeRetirementProof struct {
	Version           int    `json:"v"`
	State             string `json:"state"`
	AckSnapshotSHA256 string `json:"ack_snapshot_sha256"`
	SessionID         string `json:"session_id"`
	OperationID       string `json:"operation_id"`
	HostClaimID       string `json:"host_claim_id"`
	TargetSessionID   string `json:"target_session_id"`
}
type hostNativeRetirementDependencies struct {
	hostNativeRegistrationDependencies
	retire func(context.Context, hostRotationEnrollment, nativeRotationCompletion) (nativeRotationReply, error)
}

func readHostNativeRetirementInputAt(root *os.File, workerDirectory, sessionID string) (*hostNativeRetirementInput, error) {
	ack, err := readHostNativeAckInputAt(root, workerDirectory, sessionID)
	if err != nil {
		return nil, err
	}
	hashes := map[string]string{"registration": ack.fingerprint}
	var received hostNativeAckPhase
	for _, state := range []string{"ledger_ack_requested", "ledger_ack_received"} {
		raw, err := readHostNativeClaimFile(root, ack.completion.request.Epoch+"."+state+".json")
		var phase hostNativeAckPhase
		if err != nil || decodeHostNativeRecord(raw, &phase) != nil || !hostNativeRegistrationExactShape(raw, phase) ||
			phase.Version != 1 || phase.State != state || phase.RegistrationSnapshotSHA256 != ack.fingerprint ||
			!reflect.DeepEqual(phase.Request, hostNativeAckRequestFor(ack)) {
			return nil, errors.New("native retirement lacks exact durable ledger ACK")
		}
		if state == "ledger_ack_requested" {
			if phase.Ack != nil {
				return nil, errors.New("native retirement ACK intent changed")
			}
		} else {
			if phase.Ack == nil {
				return nil, errors.New("native retirement ACK receipt unavailable")
			}
			received = phase
		}
		hashes[state] = hostRotationCapsuleHash(raw)
	}
	raw, _ := json.Marshal(received.Ack)
	receipt, err := decodeHostNativeAck(raw, hostNativeAckRequestFor(ack), ack.registration.Registration.Seq)
	if err != nil {
		return nil, err
	}
	raw, _ = json.Marshal(hashes)
	return &hostNativeRetirementInput{ack, receipt, hostRotationCapsuleHash(raw)}, nil
}
func readHostNativeRetirementInput(workerDirectory, sessionID string) (*hostNativeRetirementInput, error) {
	if !validHostNativeUUID(sessionID) {
		return nil, errors.New("invalid native retirement source")
	}
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	return readHostNativeRetirementInputAt(root, workerDirectory, sessionID)
}
func hostNativeRetirementPhase(input *hostNativeRetirementInput, state string) hostNativeRetirementProof {
	r := input.ack.completion.request
	return hostNativeRetirementProof{1, state, input.fingerprint, r.SessionID, r.Epoch, r.HostClaimID, input.receipt.NewSessionID}
}

// The native foreground retains duplicate-ACK identity after successful
// retirement. Persisting this request authorizes only that exact idempotent ACK,
// never another close, restore, reservation or transaction.
func recordHostNativeRetirementPhase(input *hostNativeRetirementInput, finish bool) (bool, error) {
	c := input.ack.completion
	root, lock, err := lockHostNativeClaimRoot(c.journal.workerDirectory, false)
	if err != nil {
		return false, err
	}
	defer root.Close()
	defer lock.Close()
	current, err := readHostNativeRetirementInputAt(root, c.journal.workerDirectory, c.request.SessionID)
	if err != nil || current.fingerprint != input.fingerprint {
		return false, errors.New("native retirement ACK changed")
	}
	read := func(state string) (bool, error) {
		raw, err := readHostNativeClaimFile(root, c.request.Epoch+"."+state+".json")
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		var phase hostNativeRetirementProof
		if decodeHostNativeRecord(raw, &phase) != nil || !hostNativeRegistrationExactShape(raw, phase) ||
			phase != hostNativeRetirementPhase(input, state) {
			return false, errors.New("native retirement phase changed")
		}
		return true, nil
	}
	requested, err := read("native_ack_requested")
	if err != nil {
		return false, err
	}
	completed, err := read("native_retired")
	if err != nil {
		return false, err
	}
	if !requested {
		if finish || completed {
			return false, errors.New("native retirement has no durable request")
		}
		raw, _ := json.Marshal(hostNativeRetirementPhase(input, "native_ack_requested"))
		if err := writeHostNativeClaimFile(root, c.request.Epoch+".native_ack_requested.json", raw, false); err != nil {
			return false, err
		}
	}
	if finish && !completed {
		raw, _ := json.Marshal(hostNativeRetirementPhase(input, "native_retired"))
		if err := writeHostNativeClaimFile(root, c.request.Epoch+".native_retired.json", raw, true); err != nil {
			return false, err
		}
		completed = true
	}
	return completed, nil
}

func retireHostNativeCompletion(ctx context.Context, workerDirectory, sessionID string,
	deps hostNativeRetirementDependencies) (*hostNativeRetirementProof, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if deps.binding == nil || deps.ledger == nil || deps.retire == nil {
		return nil, errors.New("native retirement dependencies unavailable")
	}
	input, err := readHostNativeRetirementInput(workerDirectory, sessionID)
	if err != nil {
		return nil, err
	}
	check := func() error {
		if err := verifyHostNativeAckEvidence(ctx, deps.hostNativeRegistrationDependencies, input.ack); err != nil {
			return err
		}
		current, err := reconcileHostNativeAck(ctx, deps.hostNativeRegistrationDependencies, input.ack)
		if err != nil {
			return err
		}
		if !reflect.DeepEqual(current, input.receipt) {
			return errors.New("native retirement ledger ACK changed")
		}
		return ctx.Err()
	}
	if err := check(); err != nil {
		return nil, err
	}
	completed, err := recordHostNativeRetirementPhase(input, false)
	if err != nil {
		return nil, err
	}
	if !completed {
		if err := check(); err != nil {
			return nil, err
		}
		c := input.ack.completion
		r := input.ack.registration.Completion.Receipt
		reply, err := deps.retire(ctx, c.request.Source.Enrollment, r)
		if err != nil {
			return nil, err
		}
		command := nativeRotationCommand{Operation: "acknowledge", ThreadID: c.request.SessionID, OperationID: r.OperationID, HostClaimID: r.HostClaimID}
		if reply.Version != 1 || reply.State != "acknowledged" || validateNativeRotationReply(command, reply) != nil {
			return nil, errors.New("native retirement is not confirmed")
		}
		if err := check(); err != nil {
			return nil, err
		}
		if _, err := recordHostNativeRetirementPhase(input, true); err != nil {
			return nil, err
		}
	}
	proof := hostNativeRetirementPhase(input, "native_retired")
	// Supervisor transition and host-fence retirement are still ordered durable
	// steps. This function never deletes the active entry or re-enrolls a target.
	return &proof, nil
}

func (bridge *hostNativeRotationBridge) acknowledgeNativeCommit(ctx context.Context, threadID, operationID, hostClaimID string) (nativeRotationReply, error) {
	if bridge == nil || !validHostNativeUUID(threadID) || !validHostNativeUUID(operationID) ||
		!validHostNativeUUID(hostClaimID) || operationID == hostClaimID {
		return nativeRotationReply{}, errors.New("invalid native retirement identity")
	}
	return bridge.call(ctx, nativeRotationCommand{Operation: "acknowledge", ThreadID: threadID, OperationID: operationID, HostClaimID: hostClaimID})
}
func (session *Session) retireNativeContextRotation(ctx context.Context, e hostRotationEnrollment, r nativeRotationCompletion) (nativeRotationReply, error) {
	if session == nil || e.PaneID != session.id || e.WorkerPID != os.Getpid() || e.Client != "codex" {
		return nativeRotationReply{}, errors.New("native retirement worker changed")
	}
	if _, err := readHostNativeRegistrationBinding(e, r); err != nil {
		return nativeRotationReply{}, err
	}
	session.nativeRotationMu.Lock()
	bridge := session.nativeRotation
	session.nativeRotationMu.Unlock()
	if bridge == nil || bridge.providerPID != e.AgentPID || bridge.providerStart != e.AgentStart ||
		!nativeRotationCallerMatches(bridge.helperPID, e.AgentPID, e.AgentStart) {
		return nativeRotationReply{}, errors.New("native retirement foreground bridge unavailable")
	}
	return bridge.acknowledgeNativeCommit(ctx, e.SessionID, r.OperationID, r.HostClaimID)
}
func (session *Session) retireNativeCompletion(ctx context.Context, workerDirectory, sessionID string) (*hostNativeRetirementProof, error) {
	return retireHostNativeCompletion(ctx, workerDirectory, sessionID, hostNativeRetirementDependencies{
		hostNativeRegistrationDependencies: hostNativeRegistrationDependencies{
			binding: readHostNativeRegistrationBinding, ledger: callHostNativeLedger,
		},
		retire: session.retireNativeContextRotation,
	})
}

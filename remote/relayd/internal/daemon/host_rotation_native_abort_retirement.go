package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
)

type hostNativeAbortRetirementInput struct {
	abort       *hostNativeAbortInput
	receipt     hostNativeAbortReceipt
	fingerprint string
}
type hostNativeAbortRetirementProof struct {
	Version             int    `json:"v"`
	State               string `json:"state"`
	AbortSnapshotSHA256 string `json:"abort_snapshot_sha256"`
	SessionID           string `json:"session_id"`
	OperationID         string `json:"operation_id"`
	HostClaimID         string `json:"host_claim_id"`
}
type hostNativeAbortRetirementDependencies struct {
	hostNativeAbortDependencies
	retire func(context.Context, hostRotationEnrollment, hostNativeRefusalRecord) (nativeRotationReply, error)
}

func readHostNativeAbortRetirementInputAt(root *os.File, directory, sessionID string) (*hostNativeAbortRetirementInput, error) {
	input, err := readHostNativeAbortInputAt(root, directory, sessionID)
	if err != nil {
		return nil, err
	}
	hashes := map[string]string{"refusal": input.fingerprint}
	var received hostNativeAbortPhase
	q := hostNativeAbortRequestFor(input)
	for _, state := range []string{"ledger_abort_requested", "ledger_abort_received"} {
		raw, err := readHostNativeClaimFile(root, q.Epoch+"."+state+".json")
		var phase hostNativeAbortPhase
		if err != nil || decodeHostNativeRecord(raw, &phase) != nil || !hostNativeRegistrationExactShape(raw, phase) ||
			phase.Version != 1 || phase.State != state || phase.RefusalSnapshotSHA256 != input.fingerprint ||
			!reflect.DeepEqual(phase.Refusal, input.refusal) || phase.Request != q {
			return nil, errors.New("native refusal retirement lacks exact durable ledger abort")
		}
		if state == "ledger_abort_requested" {
			if phase.Abort != nil {
				return nil, errors.New("native refusal retirement abort request changed")
			}
		} else {
			if phase.Abort == nil {
				return nil, errors.New("native refusal retirement abort receipt unavailable")
			}
			received = phase
		}
		hashes[state] = hostRotationCapsuleHash(raw)
	}
	raw, _ := json.Marshal(received.Abort)
	receipt, err := decodeHostNativeAbort(raw, q, input.completion.intent.Seq)
	if err != nil {
		return nil, err
	}
	raw, _ = json.Marshal(hashes)
	return &hostNativeAbortRetirementInput{input, receipt, hostRotationCapsuleHash(raw)}, nil
}
func readHostNativeAbortRetirementInput(directory, sessionID string) (*hostNativeAbortRetirementInput, error) {
	if !validHostNativeUUID(sessionID) {
		return nil, errors.New("invalid native refusal retirement source")
	}
	root, lock, err := lockHostNativeClaimRoot(directory, false)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	return readHostNativeAbortRetirementInputAt(root, directory, sessionID)
}
func hostNativeAbortRetirementPhase(input *hostNativeAbortRetirementInput, state string) hostNativeAbortRetirementProof {
	r := input.abort.completion.request
	return hostNativeAbortRetirementProof{1, state, input.fingerprint, r.SessionID, r.Epoch, r.HostClaimID}
}
func recordHostNativeAbortRetirement(input *hostNativeAbortRetirementInput, finish bool) (bool, error) {
	c := input.abort.completion
	root, lock, err := lockHostNativeClaimRoot(c.journal.workerDirectory, false)
	if err != nil {
		return false, err
	}
	defer root.Close()
	defer lock.Close()
	current, err := readHostNativeAbortRetirementInputAt(root, c.journal.workerDirectory, c.request.SessionID)
	if err != nil || current.fingerprint != input.fingerprint {
		return false, errors.New("native refusal retirement abort changed")
	}
	read := func(state string) (bool, error) {
		raw, err := readHostNativeClaimFile(root, c.request.Epoch+"."+state+".json")
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		if !hostNativeRegistrationExactShape(raw, hostNativeAbortRetirementPhase(input, state)) {
			return false, errors.New("native refusal retirement phase changed")
		}
		return true, nil
	}
	requested, err := read("native_abort_ack_requested")
	if err != nil {
		return false, err
	}
	completed, err := read("native_abort_retired")
	if err != nil {
		return false, err
	}
	if !requested {
		if finish || completed {
			return false, errors.New("native refusal retirement lacks durable request")
		}
		raw, _ := json.Marshal(hostNativeAbortRetirementPhase(input, "native_abort_ack_requested"))
		if err := writeHostNativeClaimFile(root, c.request.Epoch+".native_abort_ack_requested.json", raw, false); err != nil {
			return false, err
		}
	}
	if finish && !completed {
		raw, _ := json.Marshal(hostNativeAbortRetirementPhase(input, "native_abort_retired"))
		if err := writeHostNativeClaimFile(root, c.request.Epoch+".native_abort_retired.json", raw, true); err != nil {
			return false, err
		}
		completed = true
	}
	return completed, nil
}
func verifyHostNativeAbortRetirementEvidence(ctx context.Context, deps hostNativeAbortDependencies, input *hostNativeAbortRetirementInput) error {
	if err := verifyHostNativeAbortEvidence(ctx, deps, input.abort); err != nil {
		return err
	}
	observed, err := reconcileHostNativeAbort(ctx, deps, input.abort)
	if err != nil {
		return err
	}
	if observed == nil || *observed != input.receipt {
		return errors.New("native refusal retirement ledger abort changed")
	}
	return ctx.Err()
}

// This acknowledges only the already cancelled terminal native operation.
// The source remains attached. The active host fence is retained for finalization.
func retireHostNativeRefusal(ctx context.Context, directory, sessionID string, deps hostNativeAbortRetirementDependencies) (*hostNativeAbortRetirementProof, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if deps.owner == nil || deps.ledger == nil || deps.retire == nil {
		return nil, errors.New("native refusal retirement dependencies unavailable")
	}
	input, err := readHostNativeAbortRetirementInput(directory, sessionID)
	if err != nil {
		return nil, err
	}
	check := func() error {
		return verifyHostNativeAbortRetirementEvidence(ctx, deps.hostNativeAbortDependencies, input)
	}
	if err := check(); err != nil {
		return nil, err
	}
	completed, err := recordHostNativeAbortRetirement(input, false)
	if err != nil {
		return nil, err
	}
	if !completed {
		if err := check(); err != nil {
			return nil, err
		}
		c := input.abort.completion
		reply, err := deps.retire(ctx, c.request.Source.Enrollment, input.abort.refusal.Receipt)
		if err != nil {
			return nil, err
		}
		command := nativeRotationCommand{Operation: "acknowledge", ThreadID: c.request.SessionID, OperationID: c.request.Epoch, HostClaimID: c.request.HostClaimID}
		if reply.Version != 1 || reply.State != "acknowledged" || validateNativeRotationReply(command, reply) != nil {
			return nil, errors.New("native refusal retirement is not confirmed")
		}
		if err := check(); err != nil {
			return nil, err
		}
		if _, err := recordHostNativeAbortRetirement(input, true); err != nil {
			return nil, err
		}
	}
	proof := hostNativeAbortRetirementPhase(input, "native_abort_retired")
	return &proof, nil
}
func (session *Session) retireNativeRefusal(ctx context.Context, e hostRotationEnrollment, r hostNativeRefusalRecord) (nativeRotationReply, error) {
	if err := ctx.Err(); err != nil {
		return nativeRotationReply{}, err
	}
	if session == nil || e.PaneID != session.id || e.WorkerPID != os.Getpid() || e.Client != "codex" {
		return nativeRotationReply{}, errors.New("native refusal retirement worker changed")
	}
	if err := verifyHostNativeRefusalOwner(e, r); err != nil {
		return nativeRotationReply{}, err
	}
	session.nativeRotationMu.Lock()
	bridge := session.nativeRotation
	session.nativeRotationMu.Unlock()
	if bridge == nil || bridge.providerPID != e.AgentPID || bridge.providerStart != e.AgentStart ||
		!nativeRotationCallerMatches(bridge.helperPID, e.AgentPID, e.AgentStart) {
		return nativeRotationReply{}, errors.New("native refusal retirement foreground bridge unavailable")
	}
	return bridge.acknowledgeNativeCommit(ctx, e.SessionID, r.OperationID, r.ClaimID)
}

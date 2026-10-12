package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

// A refusal completes on the original source, without a destination enrollment.
// Pending cleanup survives restart and remains gated while supervision is disabled.
type hostRotationNativeAbortTransition struct {
	Version          int                            `json:"v"`
	Source           hostRotationEnrollment         `json:"source"`
	TurnID           string                         `json:"turn_id"`
	TurnSeq          uint64                         `json:"turn_seq"`
	RequestSHA256    string                         `json:"request_sha256"`
	RetirementSHA256 string                         `json:"retirement_sha256"`
	Retirement       hostNativeAbortRetirementProof `json:"retirement"`
	Finalized        bool                           `json:"finalized"`
}
type hostNativeAbortFinalizationProof struct {
	Version    int                               `json:"v"`
	State      string                            `json:"state"`
	Transition hostRotationNativeAbortTransition `json:"transition"`
}
type hostNativeAbortFinalizationDependencies struct {
	hostNativeAbortDependencies
	after func(string) error
}

func (t hostRotationNativeAbortTransition) identity() hostRotationNativeAbortTransition {
	t.Finalized = false
	return t
}
func (t hostRotationNativeAbortTransition) valid() bool {
	r := t.Retirement
	return t.Version == 1 && t.Source.Client == "codex" && validHostNativeUUID(t.Source.SessionID) &&
		t.Source.SessionID == r.SessionID && t.TurnID != "" && t.TurnSeq > 0 && t.Source.AgentPID > 1 && t.Source.WorkerPID > 1 &&
		t.Source.AgentStart != 0 && t.Source.WorkerStart != 0 && r.Version == 1 && r.State == "native_abort_retired" &&
		validHostNativeUUID(r.OperationID) && validHostNativeUUID(r.HostClaimID) && r.OperationID != r.HostClaimID &&
		nativeWireHash(r.AbortSnapshotSHA256) && nativeWireHash(t.RequestSHA256) && nativeWireHash(t.RetirementSHA256)
}
func hostNativeAbortFinalizationPhase(link hostRotationNativeAbortTransition, state string) hostNativeAbortFinalizationProof {
	return hostNativeAbortFinalizationProof{1, state, link.identity()}
}
func readHostNativeAbortFinalizationPhase(root *os.File, link hostRotationNativeAbortTransition, state string) (bool, error) {
	raw, err := readHostNativeClaimFile(root, link.Retirement.OperationID+"."+state+".json")
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !hostNativeRegistrationExactShape(raw, hostNativeAbortFinalizationPhase(link, state)) {
		return false, errors.New("native abort finalization record changed")
	}
	return true, nil
}
func verifyHostNativeAbortFinalizationHistoryAt(root *os.File, link hostRotationNativeAbortTransition) error {
	if !link.valid() {
		return errors.New("invalid native abort finalization transition")
	}
	for _, state := range []string{"host_abort_finalization_requested", "host_abort_finalized"} {
		exists, err := readHostNativeAbortFinalizationPhase(root, link, state)
		if err != nil {
			return err
		}
		if !exists {
			return errors.New("native abort finalization history incomplete")
		}
	}
	raw, err := readHostNativeClaimFile(root, link.Retirement.OperationID+".native_abort_retired.json")
	if err != nil || hostRotationCapsuleHash(raw) != link.RetirementSHA256 || !hostNativeRegistrationExactShape(raw, link.Retirement) {
		return errors.New("native abort finalization retirement changed")
	}
	raw, err = readHostNativeClaimFile(root, link.Retirement.OperationID+".native_abort_ack_requested.json")
	requested := link.Retirement
	requested.State = "native_abort_ack_requested"
	if err != nil || !hostNativeRegistrationExactShape(raw, requested) {
		return errors.New("native abort finalization retirement intent changed")
	}
	raw, err = readHostNativeClaimFile(root, link.Retirement.OperationID+".request.json")
	var q hostNativeClaimRequest
	if err != nil || hostRotationCapsuleHash(raw) != link.RequestSHA256 || decodeHostNativeRecord(raw, &q) != nil ||
		validateHostNativeStoredRequest(q) != nil || q.SessionID != link.Source.SessionID || q.Epoch != link.Retirement.OperationID ||
		q.HostClaimID != link.Retirement.HostClaimID || q.Source.Enrollment != link.Source || q.Source.TurnID != link.TurnID || q.Source.TurnSeq != link.TurnSeq {
		return errors.New("native abort finalization source changed")
	}
	return nil
}
func readHostNativeAbortFinalizationInput(directory, sessionID string) (*hostNativeAbortRetirementInput, hostRotationNativeAbortTransition, error) {
	var link hostRotationNativeAbortTransition
	root, lock, err := lockHostNativeClaimRoot(directory, false)
	if err != nil {
		return nil, link, err
	}
	defer root.Close()
	defer lock.Close()
	input, err := readHostNativeAbortRetirementInputAt(root, directory, sessionID)
	if err != nil {
		return nil, link, err
	}
	for _, state := range []string{"native_abort_ack_requested", "native_abort_retired"} {
		raw, err := readHostNativeClaimFile(root, input.receipt.Epoch+"."+state+".json")
		if err != nil || !hostNativeRegistrationExactShape(raw, hostNativeAbortRetirementPhase(input, state)) {
			return nil, link, errors.New("native abort finalization requires durable retirement")
		}
		if state == "native_abort_retired" {
			link = hostRotationNativeAbortTransition{Version: 1, Source: input.abort.completion.request.Source.Enrollment,
				TurnID: input.abort.completion.request.Source.TurnID, TurnSeq: input.abort.completion.request.Source.TurnSeq,
				RequestSHA256: input.abort.completion.journal.requestSHA256, RetirementSHA256: hostRotationCapsuleHash(raw),
				Retirement: hostNativeAbortRetirementPhase(input, state)}
		}
	}
	if !link.valid() {
		return nil, link, errors.New("native abort finalization identity unavailable")
	}
	for _, state := range []string{"host_abort_finalization_requested", "host_abort_finalized"} {
		if _, err := readHostNativeAbortFinalizationPhase(root, link, state); err != nil {
			return nil, link, err
		}
	}
	return input, link, nil
}
func writeHostNativeAbortFinalizationPhase(directory string, input *hostNativeAbortRetirementInput, link hostRotationNativeAbortTransition, state string) error {
	root, lock, err := lockHostNativeClaimRoot(directory, false)
	if err != nil {
		return err
	}
	defer root.Close()
	defer lock.Close()
	current, err := readHostNativeAbortRetirementInputAt(root, directory, link.Source.SessionID)
	if err != nil || current.fingerprint != input.fingerprint {
		return errors.New("native abort finalization receipt changed")
	}
	for _, phase := range []string{"native_abort_ack_requested", "native_abort_retired"} {
		raw, err := readHostNativeClaimFile(root, link.Retirement.OperationID+"."+phase+".json")
		if err != nil || !hostNativeRegistrationExactShape(raw, hostNativeAbortRetirementPhase(input, phase)) ||
			(phase == "native_abort_retired" && hostRotationCapsuleHash(raw) != link.RetirementSHA256) {
			return errors.New("native abort finalization retirement changed")
		}
	}
	if state == "host_abort_finalized" {
		exists, err := readHostNativeAbortFinalizationPhase(root, link, "host_abort_finalization_requested")
		if err != nil {
			return err
		}
		if !exists {
			return errors.New("native abort finalization intent unavailable")
		}
	}
	raw, _ := json.Marshal(hostNativeAbortFinalizationPhase(link, state))
	return writeHostNativeClaimFile(root, link.Retirement.OperationID+"."+state+".json", raw, true)
}
func finishHostNativeAbortFinalizationFence(directory string, link hostRotationNativeAbortTransition) error {
	root, lock, err := lockHostNativeClaimRoot(directory, false)
	if err != nil {
		return err
	}
	defer root.Close()
	defer lock.Close()
	if err := verifyHostNativeAbortFinalizationHistoryAt(root, link); err != nil {
		return err
	}
	raw, err := readHostNativeClaimFile(root, link.Source.SessionID+".active.json")
	if errors.Is(err, os.ErrNotExist) {
		return root.Sync()
	}
	if err != nil {
		return err
	}
	want := hostNativeClaimActive{Version: 1, OperationID: link.Retirement.OperationID, RequestSHA256: link.RequestSHA256}
	if !hostNativeRegistrationExactShape(raw, want) {
		return errors.New("native abort finalization will not remove another active operation")
	}
	if err := unix.Unlinkat(int(root.Fd()), link.Source.SessionID+".active.json", 0); err != nil {
		return err
	}
	return root.Sync()
}
func (s *hostRotationSupervisor) completeNativeAbortTransitionLocked(link hostRotationNativeAbortTransition) error {
	if s.record.NativeAbortTransition == nil || s.record.NativeAbortTransition.identity() != link.identity() ||
		s.record.Enrollment != link.Source {
		return errors.New("native abort supervisor transition changed")
	}
	if s.record.NativeAbortTransition.Finalized {
		return nil
	}
	completed := link
	completed.Finalized = true
	s.record.NativeAbortTransition = &completed
	s.record.NativeRecoveryState = ""
	s.record.Generation++
	s.record.NextEvaluationMS = 0
	s.record.Fingerprint = ""
	s.record.Decision = nil
	s.record.Preparation = nil
	if s.record.Enabled {
		s.record.State = "native_refused"
	}
	if err := s.saveLocked(); err != nil {
		s.record.NativeAbortTransition = &link
		s.record.Enabled = false
		s.record.State = "persistence_failed"
		return err
	}
	return nil
}
func recoverHostNativeAbortFinalizedTransition(s *hostRotationSupervisor, directory string, link hostRotationNativeAbortTransition) (bool, error) {
	root, lock, err := lockHostNativeClaimRoot(directory, false)
	if err != nil {
		return false, err
	}
	exists, err := readHostNativeAbortFinalizationPhase(root, link, "host_abort_finalized")
	if err == nil && exists {
		err = verifyHostNativeAbortFinalizationHistoryAt(root, link)
	}
	lock.Close()
	root.Close()
	if err != nil || !exists {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.record.NativeAbortTransition == nil || s.record.NativeAbortTransition.identity() != link.identity() ||
		s.record.Enrollment != link.Source {
		return false, errors.New("native abort supervisor recovery identity changed")
	}
	if s.record.NativeTransition != nil && !s.record.NativeTransition.Finalized {
		return false, errors.New("another native transition is pending")
	}
	if s.record.NativeAbortTransition.Finalized {
		return true, nil
	}
	if err := finishHostNativeAbortFinalizationFence(directory, link); err != nil {
		return false, err
	}
	if err := s.completeNativeAbortTransitionLocked(link); err != nil {
		return false, err
	}
	s.notify()
	return true, nil
}
func finalizeHostNativeRefusal(ctx context.Context, s *hostRotationSupervisor, directory, sessionID string, deps hostNativeAbortFinalizationDependencies) error {
	if s == nil || !validHostNativeUUID(sessionID) {
		return errors.New("native abort finalization source unavailable")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	saved := s.snapshot()
	if link := saved.NativeAbortTransition; link != nil && link.Source.SessionID == sessionID {
		if !link.valid() {
			return errors.New("invalid saved native abort transition")
		}
		done, err := recoverHostNativeAbortFinalizedTransition(s, directory, *link)
		if err != nil || done {
			return err
		}
	}
	if deps.owner == nil || deps.ledger == nil {
		return errors.New("native abort finalization evidence unavailable")
	}
	input, link, err := readHostNativeAbortFinalizationInput(directory, sessionID)
	if err != nil {
		return err
	}
	if err := verifyHostNativeAbortRetirementEvidence(ctx, deps.hostNativeAbortDependencies, input); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.record.Enrollment != link.Source {
		return errors.New("native abort source supervision changed")
	}
	if s.record.NativeTransition != nil && !s.record.NativeTransition.Finalized {
		return errors.New("another native transition is pending")
	}
	old := s.record.NativeAbortTransition
	if old != nil && !old.Finalized && old.identity() != link.identity() {
		return errors.New("another native abort transition is pending")
	}
	step := func(name string) error {
		if deps.after != nil {
			return deps.after(name)
		}
		return nil
	}
	// Persist the supervisor link before any local finalization. Restart cannot
	// evaluate the source until the exact historical completion clears its fence.
	if old == nil || old.identity() != link.identity() {
		pending := link
		s.record.NativeAbortTransition = &pending
		s.record.Generation++
		s.record.NextEvaluationMS = 0
		s.record.Fingerprint = ""
		s.record.Decision = nil
		s.record.Preparation = nil
		if s.record.Enabled {
			s.record.State = "native_abort_finalization_pending"
		}
		if err := s.saveLocked(); err != nil {
			s.record.Enabled = false
			s.record.State = "persistence_failed"
			return err
		}
	}
	if err := step("supervisor_pending"); err != nil {
		return err
	}
	if err := writeHostNativeAbortFinalizationPhase(directory, input, link, "host_abort_finalization_requested"); err != nil {
		return err
	}
	if err := step("intent"); err != nil {
		return err
	}
	// The original enrollment and current human enable/disable choice are retained.
	if err := writeHostNativeAbortFinalizationPhase(directory, input, link, "host_abort_finalized"); err != nil {
		return err
	}
	if err := step("completion"); err != nil {
		return err
	}
	if err := finishHostNativeAbortFinalizationFence(directory, link); err != nil {
		return err
	}
	if err := step("fence_removed"); err != nil {
		return err
	}
	if err := s.completeNativeAbortTransitionLocked(link); err != nil {
		return err
	}
	if err := step("supervisor_complete"); err != nil {
		return err
	}
	s.notify()
	return nil
}

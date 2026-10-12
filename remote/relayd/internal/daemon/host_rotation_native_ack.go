package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
)

type hostNativeAckRequest struct {
	hostNativeIntentRequest
	Receipt hostNativeJournalRecord `json:"receipt"`
}
type hostNativeAckReceipt struct {
	Version            int                     `json:"v"`
	Mode               string                  `json:"mode"`
	SessionID          string                  `json:"session_id"`
	Epoch              string                  `json:"epoch"`
	OperationID        string                  `json:"operation_id"`
	HostClaimID        string                  `json:"host_claim_id"`
	ClaimID            string                  `json:"claim_id"`
	Token              uint64                  `json:"token"`
	IntentID           string                  `json:"intent_id"`
	RequestSHA256      string                  `json:"request_sha256"`
	Seq                uint64                  `json:"seq"`
	LifecyclePerformed bool                    `json:"lifecycle_performed"`
	NewSessionID       string                  `json:"new_session_id"`
	NativeReceipt      hostNativeJournalRecord `json:"native_receipt"`
}
type hostNativeAckInput struct {
	completion   *hostNativeCompletionInput
	registration hostNativeRegistrationPhase
	fingerprint  string
}
type hostNativeAckPhase struct {
	Version                    int                   `json:"v"`
	State                      string                `json:"state"`
	RegistrationSnapshotSHA256 string                `json:"registration_snapshot_sha256"`
	Request                    hostNativeAckRequest  `json:"request"`
	Ack                        *hostNativeAckReceipt `json:"ack"`
}

// Registration is a prerequisite, not an optional legacy admission shortcut.
// All records are read through the same anchored, private, locked host root.
func readHostNativeAckInputAt(root *os.File, workerDirectory, sessionID string) (*hostNativeAckInput, error) {
	completion, err := readHostNativeCompletionInputAt(root, workerDirectory, sessionID)
	if err != nil {
		return nil, err
	}
	input := &hostNativeAckInput{completion: completion}
	hashes := map[string]string{"host": completion.fingerprint}
	read := func(state string, target any) error {
		raw, err := readHostNativeClaimFile(root, completion.request.Epoch+"."+state+".json")
		if err != nil {
			return err
		}
		if decodeHostNativeRecord(raw, target) != nil || !hostNativeRegistrationExactShape(raw, target) {
			return errors.New("native ACK registration record is malformed")
		}
		hashes[state] = hostRotationCapsuleHash(raw)
		return nil
	}
	var proof hostNativeCompletionProof
	if err := read("native_restored_verified", &proof); err != nil {
		return nil, err
	}
	if err := read("registration_received", &input.registration); err != nil {
		return nil, err
	}
	phase := input.registration
	if phase.Version != 1 || phase.State != "registration_received" || phase.HostSnapshotSHA256 != completion.fingerprint ||
		phase.Registration == nil || !reflect.DeepEqual(phase.Completion, proof) ||
		proof.Version != 1 || proof.State != "native_restored_verified" || proof.RequestSHA256 != completion.journal.requestSHA256 ||
		proof.HostSnapshotSHA256 != completion.fingerprint {
		return nil, errors.New("native ACK lacks exact durable registration")
	}
	r := completion.request
	receipt := proof.Receipt
	identity := hostNativeIntentRequest{1, sessionID, r.Epoch, completion.claim.ClaimID, completion.claim.Token, r.HostClaimID, completion.journal.requestSHA256}
	target := r.Source.Enrollment
	target.SessionID = receipt.TargetThreadID
	if phase.Request.hostNativeIntentRequest != identity || !receipt.valid(r.Epoch, r.HostClaimID) ||
		!receipt.Source.matches(r.Reservation.Native) || receipt.CapsuleSHA256 != r.Capsule.SHA256 ||
		receipt.ProcessID != uint32(r.Source.Enrollment.AgentPID) ||
		!reflect.DeepEqual(phase.Request.Receipt, expectedHostNativeJournalRecord(receipt, "restored")) ||
		phase.Request.Target.Enrollment != target || phase.Request.Target.RuntimeID != receipt.TargetRuntimeID ||
		phase.Request.Target.RolloutPath != receipt.TargetRolloutPath || phase.Request.Target.BindingRevision == "" {
		return nil, errors.New("native ACK registration identity changed")
	}
	raw, _ := json.Marshal(phase.Registration)
	if _, err := decodeHostNativeRegistration(raw, phase.Request, completion.intent.Seq); err != nil {
		return nil, err
	}
	var requested hostNativeRegistrationPhase
	if err := read("registration_requested", &requested); err != nil {
		return nil, err
	}
	expected := phase
	expected.State = "registration_requested"
	expected.Registration = nil
	if !reflect.DeepEqual(requested, expected) {
		return nil, errors.New("native ACK registration intent changed")
	}
	raw, _ = json.Marshal(hashes)
	input.fingerprint = hostRotationCapsuleHash(raw)
	return input, nil
}
func readHostNativeAckInput(workerDirectory, sessionID string) (*hostNativeAckInput, error) {
	if !validHostNativeUUID(sessionID) {
		return nil, errors.New("invalid native ACK source")
	}
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	return readHostNativeAckInputAt(root, workerDirectory, sessionID)
}

func decodeHostNativeAck(raw []byte, q hostNativeAckRequest, registrationSeq uint64) (hostNativeAckReceipt, error) {
	var r hostNativeAckReceipt
	if decodeHostNativeRecord(raw, &r) != nil || !hostNativeRegistrationExactShape(raw, r) ||
		r.Version != 1 || r.Mode != "native_v1" || r.SessionID != q.SessionID || r.Epoch != q.Epoch ||
		r.OperationID != q.Epoch || r.HostClaimID != q.HostClaimID || r.ClaimID != q.ClaimID || r.Token != q.Token ||
		r.IntentID != q.Epoch || r.RequestSHA256 != q.RequestSHA256 || r.Seq <= registrationSeq || !r.LifecyclePerformed ||
		q.Receipt.DestinationThreadID == nil || r.NewSessionID != *q.Receipt.DestinationThreadID ||
		!reflect.DeepEqual(r.NativeReceipt, q.Receipt) {
		return hostNativeAckReceipt{}, errors.New("native ledger ACK identity mismatch")
	}
	return r, nil
}
func hostNativeAckRequestFor(input *hostNativeAckInput) hostNativeAckRequest {
	return hostNativeAckRequest{input.registration.Request.hostNativeIntentRequest, input.registration.Request.Receipt}
}

// ACK and the closed claim/acknowledged intent must describe the same ledger
// revision. A bare ACK object or a closed flag alone never proves completion.
func readHostNativeAckStatus(ctx context.Context, deps hostNativeRegistrationDependencies, input *hostNativeAckInput) (hostNativeAckReceipt, error) {
	q := hostNativeAckRequestFor(input)
	raw, err := deps.ledger(ctx, "rotation_status", map[string]any{"session_id": q.SessionID, "epoch": q.Epoch})
	if err != nil {
		return hostNativeAckReceipt{}, err
	}
	var status struct {
		Version            int             `json:"v"`
		SessionID          string          `json:"session_id"`
		Epoch              string          `json:"epoch"`
		Client             string          `json:"client"`
		CWD                string          `json:"cwd"`
		Owner              string          `json:"owner"`
		Live               *bool           `json:"live"`
		LifecyclePerformed bool            `json:"lifecycle_performed"`
		NewSessionID       string          `json:"new_session_id"`
		Registration       json.RawMessage `json:"registration"`
		Ack                json.RawMessage `json:"ack"`
		Claim              json.RawMessage `json:"claim"`
		Intent             json.RawMessage `json:"intent"`
	}
	fail := func() (hostNativeAckReceipt, error) {
		return hostNativeAckReceipt{}, errors.New("native ledger ACK status mismatch")
	}
	if len(raw) > 262144 || !rotationSourceJSONUnambiguous(raw) || json.Unmarshal(raw, &status) != nil ||
		status.Version != 1 || status.SessionID != q.SessionID || status.Epoch != q.Epoch || status.Client != "codex" ||
		status.CWD != input.completion.request.Source.Enrollment.CWD || status.Owner != "relay" ||
		status.Live == nil || *status.Live || !status.LifecyclePerformed {
		return fail()
	}
	r, err := decodeHostNativeAck(status.Ack, q, input.registration.Registration.Seq)
	if err != nil {
		return r, err
	}
	if status.NewSessionID != r.NewSessionID {
		return fail()
	}
	registration, err := decodeHostNativeRegistration(status.Registration, input.registration.Request, input.completion.intent.Seq)
	if err != nil || !reflect.DeepEqual(registration, *input.registration.Registration) {
		return fail()
	}
	var claim struct {
		hostNativeClaimReceipt
		AckSeq uint64 `json:"ack_seq"`
	}
	var intent struct {
		hostNativeIntentReceipt
		AckSeq uint64 `json:"ack_seq"`
	}
	if decodeHostNativeRecord(status.Claim, &claim) != nil || !hostNativeRegistrationExactShape(status.Claim, claim) ||
		decodeHostNativeRecord(status.Intent, &intent) != nil || !hostNativeRegistrationExactShape(status.Intent, intent) {
		return fail()
	}
	expectedClaim := input.completion.claim
	expectedClaim.Closed = true
	expectedIntent := input.completion.intent
	expectedIntent.State = "acknowledged"
	if claim.hostNativeClaimReceipt != expectedClaim || claim.AckSeq != r.Seq ||
		intent.hostNativeIntentReceipt != expectedIntent || intent.AckSeq != r.Seq {
		return fail()
	}
	return r, nil
}
func reconcileHostNativeAck(ctx context.Context, deps hostNativeRegistrationDependencies, input *hostNativeAckInput) (hostNativeAckReceipt, error) {
	r, err := readHostNativeAckStatus(ctx, deps, input)
	if err != nil {
		return r, err
	}
	q := input.registration.Request
	_, thread, provenance, err := readHostNativeRegistrationSession(ctx, deps, q.Target.Enrollment, q.Target.RolloutPath)
	if err != nil {
		return r, err
	}
	registered, err := decodeHostNativeRegistration(provenance, q, input.completion.intent.Seq)
	if err != nil || !reflect.DeepEqual(registered, *input.registration.Registration) || !reflect.DeepEqual(thread, q.Target.ThreadID) {
		return r, errors.New("native ledger ACK destination changed")
	}
	after, err := readHostNativeAckStatus(ctx, deps, input)
	if err != nil || !reflect.DeepEqual(after, r) {
		return r, errors.New("native ledger ACK changed during observation")
	}
	return r, nil
}
func verifyHostNativeAckEvidence(ctx context.Context, deps hostNativeRegistrationDependencies, input *hostNativeAckInput) error {
	c := input.completion
	p := input.registration
	owner := func(e hostRotationEnrollment, r nativeRotationCompletion) error {
		revision, err := deps.binding(e, r)
		if err != nil {
			return err
		}
		if revision != p.Request.Target.BindingRevision {
			return errors.New("native ledger ACK attachment changed")
		}
		return nil
	}
	proof, err := verifyAndRecordHostNativeCompletion(ctx, c.journal.workerDirectory, c.request.SessionID, p.Completion.Receipt, owner)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(*proof, p.Completion) {
		return errors.New("native ledger ACK completion evidence changed")
	}
	_, thread, _, err := readHostNativeRegistrationSession(ctx, deps, c.request.Source.Enrollment, p.Completion.Receipt.Source.RolloutPath)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(thread, p.Request.Target.ThreadID) {
		return errors.New("native ledger ACK logical task changed")
	}
	return ctx.Err()
}
func recordHostNativeAckPhase(input *hostNativeAckInput, phase hostNativeAckPhase, begin bool) (bool, error) {
	c := input.completion
	root, lock, err := lockHostNativeClaimRoot(c.journal.workerDirectory, false)
	if err != nil {
		return false, err
	}
	defer root.Close()
	defer lock.Close()
	current, err := readHostNativeAckInputAt(root, c.journal.workerDirectory, c.request.SessionID)
	if err != nil || current.fingerprint != input.fingerprint {
		return false, errors.New("native ledger ACK registration changed")
	}
	name := c.request.Epoch + ".ledger_ack_requested.json"
	requested := phase
	requested.State = "ledger_ack_requested"
	requested.Ack = nil
	raw, err := readHostNativeClaimFile(root, name)
	if err == nil {
		var saved hostNativeAckPhase
		if decodeHostNativeRecord(raw, &saved) != nil || !hostNativeRegistrationExactShape(raw, saved) || !reflect.DeepEqual(saved, requested) {
			return false, errors.New("native ledger ACK request changed")
		}
		if begin {
			return false, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) || !begin {
		return false, errors.New("native ledger ACK request unavailable")
	} else {
		// A receipt without its request is conflicting evidence, including a
		// partial write. Never manufacture a new request around that evidence.
		if _, err := readHostNativeClaimFile(root, c.request.Epoch+".ledger_ack_received.json"); !errors.Is(err, os.ErrNotExist) {
			return false, errors.New("native ledger ACK receipt lacks durable request")
		}
		data, err := json.Marshal(requested)
		if err != nil {
			return false, err
		}
		return true, writeHostNativeClaimFile(root, name, data, false)
	}
	data, err := json.Marshal(phase)
	if err != nil {
		return false, err
	}
	return false, writeHostNativeClaimFile(root, c.request.Epoch+".ledger_ack_received.json", data, true)
}

func acknowledgeHostNativeCompletion(ctx context.Context, workerDirectory, sessionID string,
	deps hostNativeRegistrationDependencies) (*hostNativeAckReceipt, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if deps.binding == nil || deps.ledger == nil {
		return nil, errors.New("native ledger ACK dependencies unavailable")
	}
	input, err := readHostNativeAckInput(workerDirectory, sessionID)
	if err != nil {
		return nil, err
	}
	check := func() error { return verifyHostNativeAckEvidence(ctx, deps, input) }
	if err := check(); err != nil {
		return nil, err
	}
	registered, err := reconcileHostNativeRegistration(ctx, deps, input.registration.Request, input.completion.intent.Seq)
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(registered, *input.registration.Registration) {
		return nil, errors.New("native ledger registration changed before ACK")
	}
	q := hostNativeAckRequestFor(input)
	phase := hostNativeAckPhase{1, "ledger_ack_requested", input.fingerprint, q, nil}
	submit, err := recordHostNativeAckPhase(input, phase, true)
	if err != nil {
		return nil, err
	}
	var reply *hostNativeAckReceipt
	var ack hostNativeAckReceipt
	retry := false
	if !submit {
		ack, err = reconcileHostNativeAck(ctx, deps, input)
		if err != nil {
			if err := verifyHostNativeLedgerRetryPending(ctx, deps, input.completion, input.registration.Request, input.registration.Registration); err != nil {
				return nil, err
			}
			submit, retry = true, true
		}
	}
	if submit {
		if err := check(); err != nil {
			return nil, err
		}
		if retry {
			if err := authorizeHostNativeAckRetry(input, phase); err != nil {
				return nil, err
			}
		}
		raw, callErr := deps.ledger(ctx, "rotation_native_ack", q)
		if callErr == nil {
			decoded, err := decodeHostNativeAck(raw, q, registered.Seq)
			if err != nil {
				return nil, err
			}
			reply = &decoded
		}
		ack, err = reconcileHostNativeAck(ctx, deps, input)
	}
	if err != nil {
		return nil, err
	}
	if reply != nil && !reflect.DeepEqual(*reply, ack) {
		return nil, errors.New("native ledger ACK reply differs from durable ledger")
	}
	if err := check(); err != nil {
		return nil, err
	}
	phase.State = "ledger_ack_received"
	phase.Ack = &ack
	if _, err := recordHostNativeAckPhase(input, phase, false); err != nil {
		return nil, err
	}
	// Native retirement, supervisor re-enrollment and removal of the host fence
	// follow this phase. A ledger ACK alone never removes the local active entry.
	return &ack, nil
}

func (claim *hostNativeRotationClaim) acknowledgeNativeCompletion(ctx context.Context) (*hostNativeAckReceipt, error) {
	if claim == nil {
		return nil, errors.New("native claim unavailable")
	}
	claim.mu.Lock()
	if claim.journal == nil || !claim.handoffAttempted {
		claim.mu.Unlock()
		return nil, errors.New("native handoff unavailable")
	}
	directory, session := claim.journal.workerDirectory, claim.request.SessionID
	claim.mu.Unlock()
	return acknowledgeHostNativeCompletion(ctx, directory, session, hostNativeRegistrationDependencies{
		binding: readHostNativeRegistrationBinding, ledger: callHostNativeLedger,
	})
}

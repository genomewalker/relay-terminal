package daemon

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

type hostNativeReservationPair struct {
	Native   nativeRotationReceipt  `json:"native"`
	Frontend nativeRotationFrontend `json:"frontend"`
}
type hostNativeClaimBinding struct {
	Source      hostRotationCapsuleBinding `json:"source"`
	Capsule     hostRotationCapsuleReceipt `json:"capsule"`
	Reservation hostNativeReservationPair  `json:"reservation"`
}
type hostNativeClaimRequest struct {
	Version     int                        `json:"v"`
	SessionID   string                     `json:"session_id"`
	Epoch       string                     `json:"epoch"`
	Claimant    string                     `json:"claimant"`
	HostClaimID string                     `json:"host_claim_id"`
	LeaseMS     int64                      `json:"lease_ms"`
	Source      hostRotationCapsuleBinding `json:"source"`
	Capsule     hostRotationCapsuleReceipt `json:"capsule"`
	Reservation hostNativeReservationPair  `json:"reservation"`
}
type hostNativeClaimReceipt struct {
	Version     int                    `json:"v"`
	Mode        string                 `json:"mode"`
	SessionID   string                 `json:"session_id"`
	Epoch       string                 `json:"epoch"`
	OperationID string                 `json:"operation_id"`
	HostClaimID string                 `json:"host_claim_id"`
	ClaimID     string                 `json:"claim_id"`
	Claimant    string                 `json:"claimant"`
	Token       uint64                 `json:"token"`
	Seq         uint64                 `json:"seq"`
	ExpectedSeq uint64                 `json:"expected_seq"`
	ExpiresAtMS int64                  `json:"expires_at_ms"`
	Closed      bool                   `json:"closed"`
	ReleaseSeq  uint64                 `json:"release_seq,omitempty"`
	Native      hostNativeClaimBinding `json:"native"`
}
type hostNativeReleaseRequest struct {
	Version     int    `json:"v"`
	SessionID   string `json:"session_id"`
	Epoch       string `json:"epoch"`
	ClaimID     string `json:"claim_id"`
	Token       uint64 `json:"token"`
	HostClaimID string `json:"host_claim_id"`
}

func validHostNativeUUID(value string) bool {
	return nativeRotationUUID.MatchString(value) && value != "00000000-0000-0000-0000-000000000000"
}
func newHostNativeUUID() (string, error) {
	var data [16]byte
	if _, err := rand.Read(data[:]); err != nil {
		return "", err
	}
	data[6] = (data[6] & 0x0f) | 0x40
	data[8] = (data[8] & 0x3f) | 0x80
	value := hex.EncodeToString(data[:])
	return value[:8] + "-" + value[8:12] + "-" + value[12:16] + "-" + value[16:20] + "-" + value[20:], nil
}

func decodeHostNativeLedgerResponse(raw []byte) (json.RawMessage, error) {
	var response struct {
		Version string          `json:"jsonrpc"`
		ID      int             `json:"id"`
		Error   json.RawMessage `json:"error"`
		Result  struct {
			IsError    bool `json:"isError"`
			Structured struct {
				Value json.RawMessage `json:"value"`
			} `json:"structured"`
		} `json:"result"`
	}
	if len(raw) > 262144 || !rotationSourceJSONUnambiguous(raw) || json.Unmarshal(raw, &response) != nil ||
		response.Version != "2.0" || response.ID != 1 || (len(response.Error) > 0 && string(response.Error) != "null") ||
		response.Result.IsError || len(response.Result.Structured.Value) == 0 || string(response.Result.Structured.Value) == "null" {
		return nil, errors.New("native ledger outcome unavailable")
	}
	return response.Result.Structured.Value, nil
}
func callHostNativeLedger(ctx context.Context, operation string, args any) (json.RawMessage, error) {
	switch operation {
	case "rotation_native_claim", "rotation_native_release", "rotation_native_intent", "rotation_native_register", "rotation_native_ack", "rotation_native_abort", "rotation_status", "session_get":
	default:
		return nil, errors.New("unsupported native ledger operation")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	request, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
		"params": map[string]any{"name": "ledger_op", "arguments": map[string]any{"op": operation, "args": args}}})
	if err != nil || len(request) > hostNativeClaimRecordLimit {
		return nil, errors.New("invalid native ledger request")
	}
	raw, err := hostRotationCommand(ctx, filepath.Join(home, ".claude", "bin", "chitta"), nil, append(request, '\n'))
	if err != nil {
		return nil, errors.New("native ledger outcome unavailable")
	}
	return decodeHostNativeLedgerResponse(raw)
}

func decodeHostNativeClaim(raw []byte, request hostNativeClaimRequest, closed bool) (hostNativeClaimReceipt, error) {
	result, err := decodeHostNativeClaimIdentity(raw, request, closed)
	if err != nil {
		return result, err
	}
	if !closed {
		now := time.Now().UnixMilli()
		if result.ExpiresAtMS <= now || result.ExpiresAtMS > now+request.LeaseMS {
			return hostNativeClaimReceipt{}, errors.New("native claim receipt expired or exceeds lease")
		}
	}
	return result, nil
}

// Historical identity validation cannot grant or recreate a live reservation.
func decodeHostNativeClaimIdentity(raw []byte, request hostNativeClaimRequest, closed bool) (hostNativeClaimReceipt, error) {
	var result hostNativeClaimReceipt
	fail := func() (hostNativeClaimReceipt, error) {
		return hostNativeClaimReceipt{}, errors.New("native claim receipt mismatch")
	}
	if len(raw) > hostNativeClaimRecordLimit || !rotationSourceJSONUnambiguous(raw) {
		return fail()
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&result) != nil {
		return fail()
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		return fail()
	}
	required := []string{"v", "mode", "session_id", "epoch", "operation_id", "host_claim_id", "claim_id", "claimant",
		"token", "seq", "expected_seq", "expires_at_ms", "closed", "native"}
	for _, key := range required {
		if _, ok := fields[key]; !ok {
			return fail()
		}
	}
	expectedFields := 14
	if closed {
		expectedFields++
	}
	if len(fields) != expectedFields || !bytes.Equal(bytes.TrimSpace(fields["closed"]), []byte(strconv.FormatBool(closed))) {
		return fail()
	}
	if result.Version != 1 || result.Mode != "native_v1" || result.SessionID != request.SessionID ||
		result.Epoch != request.Epoch || result.OperationID != request.Epoch || result.HostClaimID != request.HostClaimID ||
		result.Claimant != request.Claimant || result.Token == 0 || result.Token != result.Seq ||
		result.Token <= request.Source.TurnSeq || result.ExpectedSeq != request.Source.TurnSeq ||
		result.ClaimID != fmt.Sprintf("%s:%d", request.SessionID, result.Token) || result.Closed != closed ||
		result.Native != (hostNativeClaimBinding{request.Source, request.Capsule, request.Reservation}) {
		return fail()
	}
	if closed {
		if result.ReleaseSeq <= result.Seq {
			return fail()
		}
	} else if result.ReleaseSeq != 0 {
		return fail()
	}
	if result.ExpiresAtMS <= 0 {
		return fail()
	}
	return result, nil
}

// The caller owns the real bridge reservation, not just its serialized receipt.
func (lease *hostNativeRotationLease) validFor(enrollment hostRotationEnrollment, turnID string) bool {
	if lease == nil || lease.bridge == nil {
		return false
	}
	bridge := lease.bridge
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if bridge.active != lease || lease.submitted || !lease.commitSupported || !time.Now().Before(lease.deadline) ||
		bridge.providerPID != enrollment.AgentPID || bridge.providerStart != enrollment.AgentStart ||
		lease.native.ThreadID != enrollment.SessionID || lease.native.TurnID != turnID {
		return false
	}
	select {
	case <-bridge.done:
		return false
	default:
	}
	select {
	case <-lease.revoked:
		return false
	default:
	}
	return true
}

type hostNativeClaimDependencies struct {
	status        func(context.Context, hostRotationEnrollment) (json.RawMessage, error)
	policy        func(context.Context, json.RawMessage, time.Time) (json.RawMessage, error)
	collect       func(context.Context, hostRotationEnrollment, hostRotationSourceBoundary) (hostRotationSource, error)
	revalidate    func(context.Context, hostRotationSource) error
	prepare       func(context.Context, hostRotationEnrollment, string) (*hostNativeRotationLease, error)
	verify        func(hostRotationEnrollment, *hostNativeRotationLease) error
	ledger        func(context.Context, string, any) (json.RawMessage, error)
	releaseNative func(context.Context, *hostNativeRotationLease) error
}

// This entry point is internal until foreground commit and receipt recovery are
// implemented. Draft completion alone does not automatically acquire a claim.
func (session *Session) claimNativeContextRotation(ctx context.Context, workerDirectory string,
	e hostRotationEnrollment, prepared hostRotationPreparation, guard func() error) (*hostNativeRotationClaim, error) {
	deps := hostNativeClaimDependencies{status: readHostRotationLedgerStatus, policy: evaluateHostRotationStatus,
		collect: collectHostRotationSource, revalidate: revalidateHostRotationSource,
		prepare: session.prepareNativeContextRotation, ledger: callHostNativeLedger,
		releaseNative: func(ctx context.Context, l *hostNativeRotationLease) error { return l.release(ctx) },
		verify: func(e hostRotationEnrollment, l *hostNativeRotationLease) error {
			if err := verifyHostRotationEnrollment(e); err != nil {
				return err
			}
			if l != nil && !nativeRotationCallerMatches(l.bridge.helperPID, e.AgentPID, e.AgentStart) {
				return errors.New("native bridge process changed")
			}
			return nil
		}}
	return acquireHostNativeClaim(ctx, workerDirectory, e, prepared, guard, deps)
}

type hostNativeRotationClaim struct {
	mu               sync.Mutex
	releaseAttempted bool
	commitAttempted  bool
	handoffAttempted bool
	source           hostRotationSource
	guard            func() error
	intent           *hostNativeIntentReceipt
	request          hostNativeClaimRequest
	receipt          hostNativeClaimReceipt
	lease            *hostNativeRotationLease
	journal          *hostNativeClaimJournal
	// These exact bytes, already read from the durable artifact, are reserved
	// for a future native commit. No reserialization or model receipt turn.
	capsule string
	deps    hostNativeClaimDependencies
}

func acquireHostNativeClaim(ctx context.Context, workerDirectory string, e hostRotationEnrollment,
	prepared hostRotationPreparation, guard func() error, deps hostNativeClaimDependencies) (claim *hostNativeRotationClaim, err error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if guard == nil || deps.status == nil || deps.policy == nil || deps.collect == nil || deps.revalidate == nil ||
		deps.prepare == nil || deps.verify == nil || deps.ledger == nil || deps.releaseNative == nil {
		return nil, errors.New("native claim dependencies unavailable")
	}
	if e.Client != "codex" || !validHostNativeUUID(e.SessionID) || prepared.State != "prepared" ||
		prepared.Capsule == nil || prepared.Draft == nil {
		return nil, errors.New("native capsule unavailable")
	}
	if err := guard(); err != nil {
		return nil, err
	}
	if err := deps.verify(e, nil); err != nil {
		return nil, err
	}
	status, err := deps.status(ctx, e)
	if err != nil {
		return nil, err
	}
	boundary, err := hostRotationBoundary(status, e)
	if err != nil {
		return nil, err
	}
	decisionRaw, err := deps.policy(ctx, status, time.Now())
	var decision hostRotationDecision
	if err != nil || json.Unmarshal(decisionRaw, &decision) != nil || decision.Version != 1 || decision.Decision != "rotate" {
		return nil, errors.New("native rotation decision changed")
	}
	source, err := deps.collect(ctx, e, boundary)
	if err != nil {
		return nil, err
	}
	binding, err := hostRotationCapsuleSource(source)
	if err != nil || source.Enrollment != e || source.Boundary != boundary ||
		prepared.TurnSeq != boundary.TurnSeq || prepared.TurnID != boundary.TurnID ||
		prepared.SourceSHA256 != source.TranscriptSHA256 || prepared.EvidenceSHA256 != source.EvidenceSHA256 ||
		prepared.BindingRevision != source.BindingRevision || prepared.SourceChunks != len(source.Chunks) {
		return nil, errors.New("prepared native source changed")
	}
	capsuleReceipt := *prepared.Capsule
	capsule, err := readHostRotationCapsule(ctx, workerDirectory, capsuleReceipt, source)
	if err != nil {
		return nil, err
	}
	_, expected, err := encodeHostRotationCapsule(source, *prepared.Draft)
	if err != nil || expected != capsuleReceipt {
		return nil, errors.New("prepared native draft changed")
	}
	if err := guard(); err != nil {
		return nil, err
	}
	lease, err := deps.prepare(ctx, e, boundary.TurnID)
	if err != nil {
		return nil, err
	}
	if lease == nil {
		return nil, errors.New("native reservation unavailable")
	}
	retained := false
	defer func() {
		if !retained {
			cleanup, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			_ = deps.releaseNative(cleanup, lease)
		}
	}()
	callCtx, cancel := context.WithDeadline(ctx, lease.deadline)
	defer cancel()
	watching := make(chan struct{})
	defer close(watching)
	go func() {
		select {
		case <-lease.revoked:
			cancel()
		case <-callCtx.Done():
		case <-watching:
		}
	}()
	check := func() error {
		if callCtx.Err() != nil {
			return callCtx.Err()
		}
		if err := guard(); err != nil {
			return err
		}
		if !lease.validFor(e, boundary.TurnID) {
			return errors.New("native reservation revoked")
		}
		return deps.verify(e, lease)
	}
	if err := check(); err != nil {
		return nil, err
	}
	if err := deps.revalidate(callCtx, source); err != nil {
		return nil, err
	}
	if err := check(); err != nil {
		return nil, err
	}
	command := nativeRotationCommand{ThreadID: e.SessionID, TurnID: boundary.TurnID}
	if !validNativeRotationReceipt(command, nativeRotationReply{Native: &lease.native, Frontend: &lease.frontend}) ||
		!validHostNativeUUID(lease.native.ReservationID) || !validHostNativeUUID(lease.native.RuntimeID) ||
		!validHostNativeUUID(lease.frontend.RuntimeID) {
		return nil, errors.New("invalid native reservation")
	}
	for _, value := range []string{lease.native.AdmissionGeneration, lease.frontend.Generation} {
		counter, err := strconv.ParseUint(value, 10, 64)
		if err != nil || strconv.FormatUint(counter, 10) != value {
			return nil, errors.New("invalid native reservation generation")
		}
	}
	operationID, err := newHostNativeUUID()
	if err != nil {
		return nil, err
	}
	hostClaimID, err := newHostNativeUUID()
	if err != nil {
		return nil, err
	}
	remaining := time.Until(lease.deadline).Milliseconds()
	if remaining > int64(lease.native.ExpiresInMS) {
		remaining = int64(lease.native.ExpiresInMS)
	}
	if remaining < 1 {
		return nil, errors.New("native reservation expired")
	}
	request := hostNativeClaimRequest{1, e.SessionID, operationID, "relay:" + operationID, hostClaimID, remaining,
		binding, capsuleReceipt, hostNativeReservationPair{lease.native, lease.frontend}}
	journal, err := beginHostNativeClaim(workerDirectory, request)
	if err != nil {
		return nil, err
	}
	if err := check(); err != nil {
		_ = journal.record("claim_uncertain", nil)
		return nil, err
	}
	raw, err := deps.ledger(callCtx, "rotation_native_claim", request)
	if err != nil {
		_ = journal.record("claim_uncertain", nil)
		return nil, errors.New("native claim reconciliation required")
	}
	receipt, err := decodeHostNativeClaim(raw, request, false)
	if err != nil {
		_ = journal.record("claim_uncertain", nil)
		return nil, err
	}
	if err := journal.record("claim_received", &receipt); err != nil {
		return nil, errors.New("native claim reconciliation required")
	}
	acquired := &hostNativeRotationClaim{request: request, receipt: receipt, lease: lease, journal: journal, capsule: capsule, deps: deps, source: source, guard: guard}
	if err := check(); err != nil {
		retained = true
		cleanup, done := context.WithTimeout(context.Background(), 2*time.Second)
		_ = acquired.release(cleanup)
		done()
		return nil, err
	}
	if err := deps.revalidate(callCtx, source); err != nil {
		retained = true
		cleanup, done := context.WithTimeout(context.Background(), 2*time.Second)
		_ = acquired.release(cleanup)
		done()
		return nil, err
	}
	if err := check(); err != nil {
		retained = true
		cleanup, done := context.WithTimeout(context.Background(), 2*time.Second)
		_ = acquired.release(cleanup)
		done()
		return nil, err
	}
	retained = true
	return acquired, nil
}

func (claim *hostNativeRotationClaim) release(ctx context.Context) error {
	claim.mu.Lock()
	defer claim.mu.Unlock()
	if claim.commitAttempted {
		return errors.New("native commit reconciliation required")
	}
	if claim.releaseAttempted {
		return errors.New("native release reconciliation required")
	}
	claim.releaseAttempted = true
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = claim.deps.releaseNative(cleanup, claim.lease)
	}()
	if err := claim.journal.record("release_requested", &claim.receipt); err != nil {
		return err
	}
	request := hostNativeReleaseRequest{1, claim.request.SessionID, claim.request.Epoch,
		claim.receipt.ClaimID, claim.receipt.Token, claim.request.HostClaimID}
	raw, err := claim.deps.ledger(ctx, "rotation_native_release", request)
	if err != nil {
		return errors.New("native release reconciliation required")
	}
	receipt, err := decodeHostNativeClaim(raw, claim.request, true)
	if err != nil {
		return err
	}
	matching := receipt
	matching.Closed = false
	matching.ReleaseSeq = 0
	if matching != claim.receipt {
		return errors.New("native release identity changed")
	}
	return claim.journal.finishRelease(receipt)
}

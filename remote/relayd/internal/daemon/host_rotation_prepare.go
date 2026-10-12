package daemon

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"time"
	"unicode/utf8"
)

type hostRotationDraft struct {
	Summary       string   `json:"summary"`
	Decisions     []string `json:"decisions"`
	Constraints   []string `json:"constraints"`
	PendingWork   []string `json:"pending_work"`
	NextAction    string   `json:"next_action"`
	Uncertainties []string `json:"uncertainties"`
}

// Only descriptive draft text is stored here. This never grants a claim,
// terminal input capability, or permission to save a ledger capsule. A storage
// receipt only identifies the exact durable bytes prepared for a future commit.
type hostRotationPreparation struct {
	Version           int                         `json:"v"`
	State             string                      `json:"state"`
	Code              string                      `json:"code,omitempty"`
	TurnSeq           uint64                      `json:"turn_seq,omitempty"`
	TurnID            string                      `json:"turn_id,omitempty"`
	SourceSHA256      string                      `json:"source_sha256,omitempty"`
	EvidenceSHA256    string                      `json:"evidence_sha256,omitempty"`
	BindingRevision   string                      `json:"binding_revision,omitempty"`
	SourceChunks      int                         `json:"source_chunks,omitempty"`
	CompletedRequests int                         `json:"completed_requests"`
	OperationID       string                      `json:"operation_id,omitempty"`
	Draft             *hostRotationDraft          `json:"draft,omitempty"`
	Capsule           *hostRotationCapsuleReceipt `json:"capsule,omitempty"`
}

type hostRotationPrepare func(context.Context, hostRotationEnrollment, func() error, func(hostRotationPreparation) error) hostRotationPreparation

type hostRotationPrepareDependencies struct {
	ledger     func(context.Context, hostRotationEnrollment) (json.RawMessage, error)
	policy     func(context.Context, json.RawMessage, time.Time) (json.RawMessage, error)
	collect    func(context.Context, hostRotationEnrollment, hostRotationSourceBoundary) (hostRotationSource, error)
	revalidate func(context.Context, hostRotationSource) error
	text       func(context.Context, string, any) (json.RawMessage, error)
	stage      func(context.Context, hostRotationSource, hostRotationDraft) (*hostRotationCapsuleReceipt, error)
}

func nativeHostRotationPreparer(workerDirectory string) hostRotationPrepare {
	dependencies := hostRotationPrepareDependencies{
		ledger: readHostRotationLedgerStatus, policy: evaluateHostRotationStatus,
		stage: func(ctx context.Context, source hostRotationSource, draft hostRotationDraft) (*hostRotationCapsuleReceipt, error) {
			return stageHostRotationCapsule(ctx, workerDirectory, source, draft)
		},
		collect: collectHostRotationSource, revalidate: revalidateHostRotationSource,
		text: func(ctx context.Context, operation string, request any) (json.RawMessage, error) {
			return hostRotationTextService(ctx, workerDirectory, operation, request)
		},
	}
	return func(ctx context.Context, e hostRotationEnrollment, guard func() error, publish func(hostRotationPreparation) error) hostRotationPreparation {
		return prepareHostRotationDraft(ctx, e, guard, publish, dependencies)
	}
}

func cloneHostRotationPreparation(value *hostRotationPreparation) *hostRotationPreparation {
	if value == nil {
		return nil
	}
	data, _ := json.Marshal(value)
	var copy hostRotationPreparation
	if json.Unmarshal(data, &copy) != nil {
		return nil
	}
	return &copy
}

func (s *hostRotationSupervisor) prepareCurrent(generation uint64, e hostRotationEnrollment) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	s.mu.Lock()
	if !s.record.Enabled || s.record.Generation != generation {
		s.mu.Unlock()
		return
	}
	select {
	case <-s.done:
		s.mu.Unlock()
		return
	default:
	}
	s.cancel = cancel
	s.record.NextEvaluationMS = 0
	s.record.Fingerprint = ""
	s.mu.Unlock()
	guard := func() error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if !s.record.Enabled || s.record.Generation != generation || s.record.Enrollment != e {
			return errors.New("preparation generation changed")
		}
		return nil
	}
	publish := func(value hostRotationPreparation) error {
		s.mu.Lock()
		defer s.mu.Unlock()
		if ctx.Err() != nil || !s.record.Enabled || s.record.Generation != generation || s.record.Enrollment != e {
			return errors.New("preparation generation changed")
		}
		s.record.State = "preparing"
		s.record.Preparation = cloneHostRotationPreparation(&value)
		if err := s.saveLocked(); err != nil {
			s.record.Enabled = false
			s.record.State = "persistence_failed"
			cancel()
			return err
		}
		return nil
	}
	result := s.prepare(ctx, e, guard, publish)
	s.mu.Lock()
	if !s.record.Enabled || s.record.Generation != generation || s.record.Enrollment != e {
		s.cancel = nil
		s.mu.Unlock()
		return
	}
	s.record.Preparation = cloneHostRotationPreparation(&result)
	s.record.State = "preparation_" + result.State
	if err := s.saveLocked(); err != nil {
		s.record.Enabled = false
		s.record.State = "persistence_failed"
	}
	drive := s.record.Enabled && result.State == "prepared" && result.Capsule != nil &&
		e.Client == "codex" && s.nativeDriver != nil
	if !drive {
		s.cancel = nil
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()

	// Keep the same cancellation/generation guard through the original-lease
	// claim and commit. Recovery afterwards uses durable evidence independently.
	attempt, stop := context.WithTimeout(ctx, 30*time.Second)
	outcome, err := s.nativeDriver.start(attempt, s, e, result, guard)
	stop()
	s.mu.Lock()
	s.cancel = nil
	if s.record.Enrollment == e {
		if outcome.Pending || err != nil {
			state := outcome.State
			if state == "" {
				state = "native_recovery_unavailable"
			}
			s.record.NativeRecoveryState = state
			if s.record.Enabled && s.record.Generation == generation {
				s.record.State = "native_attempt_pending"
			}
		}
		if err := s.saveLocked(); err != nil {
			s.record.Enabled = false
			s.record.State = "persistence_failed"
		}
	}
	s.mu.Unlock()
	// Re-observe the journal even after cancellation or an uncertain reply.
	// Successful finalization has already queued evaluation of the target.
	s.notify()
}

func hostRotationBoundary(status json.RawMessage, e hostRotationEnrollment) (hostRotationSourceBoundary, error) {
	var empty hostRotationSourceBoundary
	var value struct {
		Version   int                        `json:"v"`
		SessionID string                     `json:"session_id"`
		Client    string                     `json:"client"`
		Owner     string                     `json:"owner"`
		CWD       string                     `json:"cwd"`
		TurnSeq   uint64                     `json:"turn_seq"`
		Live      bool                       `json:"live"`
		Signal    json.RawMessage            `json:"signal"`
		Claim     json.RawMessage            `json:"claim"`
		Intent    json.RawMessage            `json:"intent"`
		Ack       json.RawMessage            `json:"ack"`
		Usage     map[string]json.RawMessage `json:"usage"`
		History   []struct {
			Version   int                        `json:"v"`
			SessionID string                     `json:"session_id"`
			TurnID    string                     `json:"turn_id"`
			Seq       uint64                     `json:"seq"`
			Usage     map[string]json.RawMessage `json:"usage"`
		} `json:"usage_history"`
	}
	if !rotationSourceJSONUnambiguous(status) || json.Unmarshal(status, &value) != nil ||
		value.Version != 1 || value.SessionID != e.SessionID || value.Client != e.Client ||
		value.CWD != e.CWD || value.Owner != "relay" || value.TurnSeq == 0 || value.Live ||
		string(value.Signal) != "null" || string(value.Claim) != "null" || string(value.Intent) != "null" || string(value.Ack) != "null" {
		return empty, errors.New("clean owned turn unavailable")
	}
	// The ledger may retain top-level usage when a newer turn has no usage.
	// Bind every observation to the actual completed turn before preparing text.
	// A Stop watermark is still not proof of a native idle prompt or full flush.
	if len(value.History) == 0 || len(value.History) > 16 || len(value.Usage) == 0 {
		return empty, errors.New("completed turn usage history unavailable")
	}
	var previous uint64
	for _, turn := range value.History {
		if turn.Version != 1 || turn.SessionID != e.SessionID ||
			strings.TrimSpace(turn.TurnID) == "" || len(turn.TurnID) > 256 ||
			strings.ContainsRune(turn.TurnID, '\x00') ||
			turn.Seq <= previous || turn.Seq > value.TurnSeq {
			return empty, errors.New("invalid completed turn usage history")
		}
		previous = turn.Seq
	}
	latest := value.History[len(value.History)-1]
	if latest.Seq != value.TurnSeq || !hostRotationUsageMatches(value.Usage, latest.Usage) {
		return empty, errors.New("usage does not belong to completed turn")
	}
	observation := func(key string) (json.RawMessage, string, bool) {
		var observed struct {
			Value      json.RawMessage `json:"value"`
			Provenance string          `json:"provenance"`
		}
		raw, ok := value.Usage[key]
		if !ok || json.Unmarshal(raw, &observed) != nil || len(observed.Value) == 0 {
			return nil, "", false
		}
		return observed.Value, observed.Provenance, true
	}
	for key, want := range map[string]struct{ value, provenance string }{
		"in_flight_tool": {"false", "transcript"}, "turn_id_fresh": {"true", "transcript"},
		"owner": {`"relay"`, "ledger"}, "client": {`""`, "hook"},
	} {
		if key == "client" {
			encoded, _ := json.Marshal(e.Client)
			want.value = string(encoded)
		}
		observed, provenance, ok := observation(key)
		if !ok || provenance != want.provenance || string(observed) != want.value {
			return empty, errors.New("clean turn observations unavailable")
		}
	}
	boundary := hostRotationSourceBoundary{TurnSeq: value.TurnSeq, TurnID: latest.TurnID}
	for key, target := range map[string]*int64{
		"transcript_mtime_ms_at_stop": &boundary.TranscriptMtimeMS,
		"transcript_bytes_at_stop":    &boundary.TranscriptBytes,
	} {
		observed, provenance, ok := observation(key)
		if !ok || provenance != "hook" || json.Unmarshal(observed, target) != nil || *target <= 0 {
			return empty, errors.New("completed transcript watermark unavailable")
		}
	}
	if boundary.TranscriptBytes > rotationSourceFileLimit {
		return empty, errors.New("completed source exceeds file limit")
	}
	return boundary, nil
}

// UseNumber preserves exact integers; map decoding permits harmless key ordering.
func hostRotationUsageMatches(left, right map[string]json.RawMessage) bool {
	decode := func(value map[string]json.RawMessage) (any, error) {
		data, err := json.Marshal(value)
		if err != nil {
			return nil, err
		}
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.UseNumber()
		var decoded any
		err = decoder.Decode(&decoded)
		return decoded, err
	}
	a, errA := decode(left)
	b, errB := decode(right)
	return errA == nil && errB == nil && reflect.DeepEqual(a, b)
}

func validateHostRotationDraft(draft hostRotationDraft) error {
	for _, value := range []string{draft.Summary, draft.NextAction} {
		if strings.TrimSpace(value) == "" || len(value) > 6400 || !utf8.ValidString(value) || strings.ContainsRune(value, '\x00') {
			return errors.New("invalid draft text")
		}
	}
	for _, list := range [][]string{draft.Decisions, draft.Constraints, draft.PendingWork, draft.Uncertainties} {
		if list == nil || len(list) > 32 {
			return errors.New("invalid draft list")
		}
		for _, value := range list {
			if strings.TrimSpace(value) == "" || len(value) > 6400 || !utf8.ValidString(value) || strings.ContainsRune(value, '\x00') {
				return errors.New("invalid draft list item")
			}
		}
	}
	data, err := json.Marshal(draft)
	if err != nil || len(data) > 16384 {
		return errors.New("draft exceeds limit")
	}
	return nil
}

type hostRotationTextBinding struct {
	SessionID string `json:"session_id"`
	Client    string `json:"client"`
	TurnSeq   uint64 `json:"turn_seq"`
}

func hostRotationDraftOperation(binding hostRotationTextBinding, evidence string) string {
	value, _ := json.Marshal(struct {
		Version  string
		Binding  hostRotationTextBinding
		Evidence string
	}{"relay-preparation-v1", binding, evidence})
	digest := sha256.Sum256(value)
	return hex.EncodeToString(digest[:16])
}

type hostRotationDraftPart struct {
	First int               `json:"first_source_chunk"`
	Last  int               `json:"last_source_chunk"`
	Draft hostRotationDraft `json:"draft"`
}

func hostRotationMergeEvidence(parts []hostRotationDraftPart) string {
	data, _ := json.Marshal(struct {
		Version int                     `json:"v"`
		Kind    string                  `json:"kind"`
		Parts   []hostRotationDraftPart `json:"parts"`
	}{1, "partial_handoff_drafts", parts})
	return string(data)
}

func prepareHostRotationDraft(ctx context.Context, e hostRotationEnrollment, guard func() error, publish func(hostRotationPreparation) error, deps hostRotationPrepareDependencies) hostRotationPreparation {
	state := hostRotationPreparation{Version: 1, State: "checking"}
	fail := func(code string) hostRotationPreparation {
		state.State = "unavailable"
		state.Code = code
		state.Draft = nil
		state.Capsule = nil
		switch code {
		case "reconciliation_required", "request_outcome_unavailable":
			state.State = "reconciliation_required"
		case "spending_limit":
			state.State = "budget_limited"
		case "text_backend_disabled":
			state.State = "disabled"
		case "source_changed":
			state.State = "discarded"
		}
		if ctx.Err() != nil {
			state.State = "cancelled"
			state.Code = "preparation_cancelled"
		}
		return state
	}
	if err := guard(); err != nil {
		return fail("generation_changed")
	}
	if err := publish(state); err != nil {
		return fail("preparation_persistence_failed")
	}
	settingsCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	settingsRaw, err := deps.text(settingsCtx, "status", map[string]any{})
	cancel()
	var settings struct {
		Status   string `json:"status"`
		Settings struct {
			Enabled bool `json:"enabled"`
		} `json:"settings"`
	}
	if err != nil || json.Unmarshal(settingsRaw, &settings) != nil {
		return fail("text_settings_unavailable")
	}
	if settings.Status == "reconciliation_required" {
		state.State = "reconciliation_required"
		return state
	}
	if !settings.Settings.Enabled {
		state.State = "disabled"
		return state
	}
	if settings.Status != "ready" {
		return fail("text_service_unavailable")
	}

	status, err := deps.ledger(ctx, e)
	if err != nil {
		return fail("ledger_unavailable")
	}
	boundary, err := hostRotationBoundary(status, e)
	if err != nil {
		return fail("completed_turn_unavailable")
	}
	decisionRaw, err := deps.policy(ctx, status, time.Now())
	var decision hostRotationDecision
	if err != nil || json.Unmarshal(decisionRaw, &decision) != nil || decision.Version != 1 || decision.Decision != "rotate" {
		return fail("rotation_decision_changed")
	}
	source, err := deps.collect(ctx, e, boundary)
	if err != nil {
		return fail("source_unavailable")
	}
	if source.Boundary != boundary || source.Enrollment != e || len(source.Chunks) == 0 || len(source.Chunks) > rotationSourceMaxChunks ||
		len(source.TranscriptSHA256) != 64 || len(source.EvidenceSHA256) != 64 || source.BindingRevision == "" {
		return fail("invalid_source_binding")
	}
	state.TurnSeq = boundary.TurnSeq
	state.TurnID = boundary.TurnID
	state.SourceSHA256 = source.TranscriptSHA256
	state.EvidenceSHA256 = source.EvidenceSHA256
	state.BindingRevision = source.BindingRevision
	state.SourceChunks = len(source.Chunks)
	binding := hostRotationTextBinding{e.SessionID, e.Client, boundary.TurnSeq}
	check := func() error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err := guard(); err != nil {
			return err
		}
		latest, err := deps.ledger(ctx, e)
		if err != nil {
			return err
		}
		current, err := hostRotationBoundary(latest, e)
		if err != nil || current != boundary {
			return errors.New("source turn changed")
		}
		if err := deps.revalidate(ctx, source); err != nil {
			return err
		}
		return guard()
	}
	requests := 0
	submit := func(evidence string) (hostRotationDraft, error) {
		var empty hostRotationDraft
		if len(evidence) == 0 || len(evidence) > rotationSourceChunkLimit || requests >= 255 {
			return empty, errors.New("preparation request bound")
		}
		if err := check(); err != nil {
			return empty, errors.New("source_changed")
		}
		operation := hostRotationDraftOperation(binding, evidence)
		state.State = "drafting"
		state.OperationID = operation
		if err := publish(state); err != nil {
			return empty, errors.New("preparation_persistence_failed")
		}
		if err := guard(); err != nil {
			return empty, errors.New("generation_changed")
		}
		requests++
		requestCtx, cancel := context.WithTimeout(ctx, 90*time.Second)
		raw, err := deps.text(requestCtx, "submit", struct {
			Version     int                     `json:"v"`
			OperationID string                  `json:"operation_id"`
			Binding     hostRotationTextBinding `json:"binding"`
			Evidence    string                  `json:"evidence"`
		}{1, operation, binding, evidence})
		cancel()
		if err != nil {
			return empty, errors.New("request_outcome_unavailable")
		}
		var receipt struct {
			Version     int    `json:"v"`
			Status      string `json:"status"`
			Code        string `json:"code"`
			OperationID string `json:"operation_id"`
			Result      struct {
				Version      int                     `json:"v"`
				Status       string                  `json:"status"`
				OperationID  string                  `json:"operation_id"`
				Binding      hostRotationTextBinding `json:"binding"`
				SourceSHA256 string                  `json:"source_sha256"`
				Draft        json.RawMessage         `json:"draft"`
			} `json:"result"`
		}
		if len(raw) > 262144 || !rotationSourceJSONUnambiguous(raw) || json.Unmarshal(raw, &receipt) != nil || receipt.Version != 1 {
			return empty, errors.New("invalid_text_receipt")
		}
		if receipt.Status == "pending" || receipt.Status == "uncertain" || receipt.Status == "abandoned" {
			return empty, errors.New("reconciliation_required")
		}
		if receipt.Status != "complete" {
			switch receipt.Code {
			case "spending_limit", "text_backend_disabled", "reconciliation_required":
				return empty, errors.New(receipt.Code)
			default:
				return empty, errors.New("text_request_failed")
			}
		}
		hash := sha256.Sum256([]byte(evidence))
		if receipt.OperationID != operation || receipt.Result.Version != 1 || receipt.Result.Status != "draft" ||
			receipt.Result.OperationID != operation || receipt.Result.Binding != binding ||
			receipt.Result.SourceSHA256 != hex.EncodeToString(hash[:]) {
			return empty, errors.New("text_receipt_binding_mismatch")
		}
		var draft hostRotationDraft
		decoder := json.NewDecoder(bytes.NewReader(receipt.Result.Draft))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&draft) != nil || validateHostRotationDraft(draft) != nil {
			return empty, errors.New("invalid_draft")
		}
		if err := check(); err != nil {
			return empty, errors.New("source_changed")
		}
		state.CompletedRequests++
		return draft, nil
	}
	parts := make([]hostRotationDraftPart, 0, len(source.Chunks))
	for index, chunk := range source.Chunks {
		draft, err := submit(chunk)
		if err != nil {
			return fail(err.Error())
		}
		parts = append(parts, hostRotationDraftPart{index + 1, index + 1, draft})
	}
	// Every source chunk must have a validated draft before reduction starts.
	// Adjacent coverage ranges are generated by code, never by the model.
	for len(parts) > 1 {
		next := []hostRotationDraftPart{}
		for start := 0; start < len(parts); {
			end := start + 1
			for end < len(parts) && len(hostRotationMergeEvidence(parts[start:end+1])) <= rotationSourceChunkLimit {
				end++
			}
			if end-start == 1 {
				next = append(next, parts[start])
				start = end
				continue
			}
			draft, err := submit(hostRotationMergeEvidence(parts[start:end]))
			if err != nil {
				return fail(err.Error())
			}
			next = append(next, hostRotationDraftPart{parts[start].First, parts[end-1].Last, draft})
			start = end
		}
		if len(next) >= len(parts) {
			return fail("merge_limit")
		}
		parts = next
	}
	if len(parts) != 1 || parts[0].First != 1 || parts[0].Last != len(source.Chunks) {
		return fail("incomplete_source_coverage")
	}
	if err := check(); err != nil {
		return fail("source_changed")
	}
	if deps.stage == nil {
		return fail("capsule_storage_unavailable")
	}
	receipt, err := deps.stage(ctx, source, parts[0].Draft)
	if err != nil || receipt == nil {
		return fail("capsule_storage_unavailable")
	}
	// Storage can outlive cancellation. It never publishes a stale receipt or
	// grants a native claim: recheck the full source and generation afterwards.
	if err := check(); err != nil {
		return fail("source_changed")
	}
	_, expected, err := encodeHostRotationCapsule(source, parts[0].Draft)
	if err != nil || *receipt != expected {
		return fail("capsule_receipt_binding_mismatch")
	}
	state.State = "prepared"
	state.Code = ""
	state.OperationID = ""
	state.Draft = &parts[0].Draft
	state.Capsule = receipt
	return state
}

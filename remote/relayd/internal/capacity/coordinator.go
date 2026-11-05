package capacity

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

type Capabilities struct {
	ProviderVersion string `json:"provider_version"`
	Admission       bool   `json:"admission"`
	CompleteWork    bool   `json:"complete_work"`
	ScheduledTasks  bool   `json:"scheduled_tasks"`
	Preservation    bool   `json:"preservation"`
	Pickup          bool   `json:"pickup"`
	Reason          string `json:"reason"`
}

func Unsupported(provider string) Capabilities {
	return Capabilities{Reason: provider + ": native admission/scheduled-work/preservation/pickup contract unavailable"}
}
func (c Capabilities) Ready() bool {
	return c.ProviderVersion != "" && c.Admission && c.CompleteWork && c.ScheduledTasks && c.Preservation && c.Pickup
}

type Plan struct {
	Counters       Counters         `json:"counters"`
	Accounts       []Account        `json:"accounts"`
	ObservedMS     int64            `json:"observed_ms"`
	SourceQuota    Account          `json:"source_quota"`
	TargetQuota    Account          `json:"target_quota"`
	TriggerResets  map[string]int64 `json:"trigger_resets"`
	Origin         string           `json:"origin"`
	SettingsSHA256 string           `json:"settings_sha256"`
	ID             string           `json:"id"`
	Source         Source           `json:"source"`
	Target         string           `json:"target"`
	TargetConfig   string           `json:"target_config"`
	NewSession     string           `json:"new_session"`
	Mode           string           `json:"mode"`
	Reasons        []string         `json:"reasons"`
	UserGeneration uint64           `json:"user_generation"`
	PolicyRevision uint64           `json:"policy_revision"`
	Preparation    Preparation      `json:"preparation"`
	SourceSHA256   string           `json:"source_sha256"`
	Turn           uint64           `json:"turn"`
	InstalledImage string           `json:"installed_image"`
	CurrentImage   string           `json:"current_image"`
}
type Operation struct {
	Plan    Plan              `json:"plan"`
	State   string            `json:"state"`
	Reason  string            `json:"reason"`
	Effects map[string]string `json:"effects"`
	Receipt string            `json:"receipt"`
}

func (o Operation) terminal() bool {
	if o.State == "completed" {
		return true
	}
	if o.State == "cancelled" {
		return len(o.Effects) == 0
	}
	return o.State == "held" && o.Effects["retire"] == "" && o.Effects["launch"] == "" && o.Effects["pickup"] == "" && o.Effects["notice"] != "intent" && o.Effects["notice"] != "unknown"
}

func (o Operation) Valid() bool {
	if !identifier(o.Plan.ID) || !o.Plan.Source.Valid() || o.Effects == nil || len(o.Effects) > 4 || len(o.Reason) > 1024 || len(o.Receipt) > 256 {
		return false
	}
	switch o.State {
	case "held", "prepared", "notice_intent", "notice_confirmed", "retire_intent", "source_exited", "launch_intent", "target_verified", "pickup_intent", "completed", "unknown", "confirmation_required", "cancelled":
	default:
		return false
	}
	for k, v := range o.Effects {
		if k != "notice" && k != "retire" && k != "launch" && k != "pickup" {
			return false
		}
		if v != "intent" && v != "confirmed" && v != "unknown" {
			return false
		}
	}
	if o.State == "completed" {
		for _, kind := range []string{"notice", "retire", "launch", "pickup"} {
			if o.Effects[kind] != "confirmed" {
				return false
			}
		}
	}
	return true
}

// Lease is an acquired native capability, not JSON, a configuration flag or
// model receipt. The installed-provider factory below cannot acquire one. A
// future real adapter must enforce the approved contract at every callback.
// Disposable adapters exercise this same coordinator without provider claims.
type Lease interface {
	Revalidate(context.Context, Plan) error
	VerifyLegacyLineage(context.Context, Plan, Entry) error
	Notice(context.Context, Plan) (string, error)
	RetirePreserving(context.Context, Plan) (string, error)
	VerifySourceExited(context.Context, Plan) error
	Launch(context.Context, Plan) (string, error)
	VerifyTarget(context.Context, Plan) error
	Pickup(context.Context, Plan) (string, error)
	VerifyPickup(context.Context, Plan) error
	Completion(context.Context, Plan) (Completion, error)
	NoPriorLaunch(context.Context, Plan) error
}
type CompletedJob struct {
	State          string `json:"state"`
	Host           string `json:"host"`
	Boot           string `json:"boot"`
	PID            int    `json:"pid"`
	Start          uint64 `json:"start"`
	EvidenceSHA256 string `json:"evidence_sha256"`
}
type Completion struct {
	Source              Source
	ImageSHA256         string
	CapsuleSHA256       string
	Jobs                map[string]CompletedJob
	Receipt             string
	LinkSource          string
	LinkTarget          string
	PermissionsRetained bool
	Counters            Counters
}

type Adapter interface {
	Capabilities(Source) Capabilities
	Acquire(context.Context, Plan) (Lease, error)
}
type NativeUnavailable struct{}

func (NativeUnavailable) Capabilities(s Source) Capabilities { return Unsupported(s.Provider) }
func (NativeUnavailable) Acquire(context.Context, Plan) (Lease, error) {
	return nil, errors.New(RetirementHold)
}

type Coordinator struct {
	Now     func() int64
	Journal Journal
	Adapter Adapter
}

func (c Coordinator) now() int64 {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now().UnixMilli()
}

// Frozen observations never refresh themselves while an intent waits in the
// journal. The native lease independently rechecks provider state at effects.
func planFresh(p Plan, now int64) bool {
	if !fresh(p.ObservedMS, now) || !fresh(p.Counters.ObservedMS, now) {
		return false
	}
	if p.Target != p.Source.Account && !p.TargetQuota.Current(now) {
		return false
	}
	if containsReason(p, "quota") && !p.SourceQuota.Current(now) {
		return false
	}
	return true
}

func requestHash(p Plan) string { raw, _ := json.Marshal(p); return Hash(raw) }
func (c Coordinator) persist(id string, mutate func(*Disk) error) (Disk, error) {
	d, err := c.Journal.Load()
	if err != nil {
		return d, err
	}
	// Every transition has a distinct durable receipt ID. No external effect
	// happens until this synchronous journal append and parent fsync succeed.
	return c.Journal.Update(id, Hash([]byte(id)), d.Revision, mutate)
}

// Request is the only combined context/quota/manual/update operation owner.
// Coalescing occurs by submitting the complete precommit reason set once.
// A committed plan never silently changes target or launches another operation.
func (c Coordinator) Request(ctx context.Context, p Plan) (Operation, error) {
	var zero Operation
	d, err := c.Journal.Load()
	if err != nil {
		return zero, err
	}
	if old, ok := d.Operations[p.ID]; ok {
		if requestHash(old.Plan) != requestHash(p) {
			return zero, errors.New("operation plan conflict")
		}
		return old, nil
	}
	if !identifier(p.ID) || !p.Source.Valid() {
		return zero, errors.New("invalid operation source")
	}
	entry, ok := d.Entries[p.Source.Pane]
	o := Operation{Plan: p, State: "held", Reason: RetirementHold, Effects: map[string]string{}}
	switch {
	case !ok || entry.Source != p.Source || entry.UserGeneration != p.UserGeneration:
		o.Reason = "source_or_user_generation_changed"
	case !entry.Enabled || entry.OptOut || entry.Takeover || entry.Pinned || (entry.Manual && !d.Settings.RebalanceEnabled):
		o.Reason = "pane_policy_paused"
	case !planReasonsAuthorized(p, d.Settings):
		o.Reason = "native_policy_or_user_origin_not_authorized"
	case p.SettingsSHA256 != SettingsHash(d.Settings):
		o.Reason = "settings_fingerprint_changed"
	case p.PolicyRevision != d.Revision:
		o.Reason = "policy_revision_changed"
	case c.Adapter == nil || !c.Adapter.Capabilities(p.Source).Ready():
		o.Reason = RetirementHold
	case !planFresh(p, c.now()):
		o.Reason = "native_observation_expired"
	case !planDecisionAuthorized(p, entry, d.Settings):
		o.Reason = "fresh_native_trigger_or_idle_evidence_unavailable"
	case accountReserved(d, p):
		o.Reason = "shared_account_observation_reserved"
	case !policyTargetAuthorized(p, entry, d.Settings):
		o.Reason = "target_capacity_or_reset_fence_unavailable"
	case p.Target != p.Source.Account && !approved(d.Settings, p.Source.Provider, p.Target):
		o.Reason = "target_not_approved"
	case p.Mode != "fresh_context" && p.Mode != "resume_same_conversation":
		o.Reason = "invalid_move_mode"
	case p.Mode == "fresh_context" && (!identifier(p.NewSession) || p.NewSession == p.Source.Session):
		o.Reason = "distinct_fresh_session_required"
	case p.Mode == "resume_same_conversation" && p.NewSession != p.Source.Session:
		o.Reason = "same_conversation_required"
	case c.Adapter == nil || !c.Adapter.Capabilities(p.Source).Ready():
		o.Reason = RetirementHold
	case p.InstalledImage == "" || !hexDigest(p.InstalledImage):
		o.Reason = "exact_installed_image_unavailable"
	default:
		if c.Adapter == nil || !c.Adapter.Capabilities(p.Source).Ready() {
			o.Reason = RetirementHold
		} else if err := ValidatePreparation(p.Preparation, p.Source, p.SourceSHA256, p.Turn); err != nil {
			o.Reason = err.Error()
		} else {
			o.State = "prepared"
			o.Reason = "checked_data_prepared"
		}
	}
	for _, old := range d.Operations {
		if !old.terminal() {
			return zero, errors.New("shared_capacity_lane_busy")
		}
	}
	next, err := c.Journal.Update("plan-"+p.ID, requestHash(p), d.Revision, func(state *Disk) error {
		if len(state.Operations) >= 128 {
			return errors.New("capacity operation bound")
		}
		state.Operations[p.ID] = o
		if o.State == "prepared" {
			state.Reservations[p.Source.Provider+":"+p.Target] = Reservation{Provider: p.Source.Provider, Account: p.Target, Operation: p.ID, Pane: p.Source.Pane, Pending: true}
		}
		return nil
	})
	if err != nil {
		return zero, err
	}
	return next.Operations[p.ID], nil
}
func (c Coordinator) transition(id, stage, reason, receipt string) (Operation, error) {
	d, err := c.Journal.Load()
	if err != nil {
		return Operation{}, err
	}
	o, ok := d.Operations[id]
	if !ok {
		return o, errors.New("operation unavailable")
	}
	key := id + "-" + stage
	next, err := c.persist(key, func(state *Disk) error {
		current, ok := state.Operations[id]
		if !ok || current.State != o.State {
			return errors.New("operation changed")
		}
		current.State = stage
		current.Reason = reason
		if receipt != "" {
			current.Receipt = receipt
		}
		if stage == "held" && current.Effects["retire"] == "" && current.Effects["launch"] == "" {
			key := current.Plan.Source.Provider + ":" + current.Plan.Target
			if r, ok := state.Reservations[key]; ok && r.Operation == id {
				delete(state.Reservations, key)
			}
		}
		state.Operations[id] = current
		return nil
	})
	if err != nil {
		return o, err
	}
	return next.Operations[id], nil
}
func (c Coordinator) effectIntent(o Operation, kind string) (Operation, error) {
	if _, already := o.Effects[kind]; already {
		return o, errors.New("effect already has a durable intent; reconcile without replay")
	}
	next, err := c.persist(o.Plan.ID+"-"+kind+"-intent", func(d *Disk) error {
		e := d.Entries[o.Plan.Source.Pane]
		if !planFresh(o.Plan, c.now()) {
			return errors.New("native_observation_expired")
		}
		if e.Source != o.Plan.Source || e.UserGeneration != o.Plan.UserGeneration || !e.Enabled || e.OptOut || e.Takeover || e.Pinned || o.Plan.SettingsSHA256 != SettingsHash(d.Settings) {
			return errors.New("effect_admission_revoked")
		}
		current := d.Operations[o.Plan.ID]
		if current.State != o.State {
			return errors.New("operation changed")
		}
		if _, exists := current.Effects[kind]; exists {
			return errors.New("effect intent already exists")
		}
		current.Effects[kind] = "intent"
		current.State = kind + "_intent"
		d.Operations[o.Plan.ID] = current
		return nil
	})
	if err != nil {
		return o, err
	}
	return next.Operations[o.Plan.ID], nil
}
func (c Coordinator) effectConfirmed(o Operation, kind, stage, receipt string) (Operation, error) {
	next, err := c.persist(o.Plan.ID+"-"+kind+"-confirmed", func(d *Disk) error {
		v := d.Operations[o.Plan.ID]
		if v.State != kind+"_intent" || v.Effects[kind] != "intent" {
			return errors.New("effect receipt conflicts")
		}
		v.Effects[kind] = "confirmed"
		v.State = stage
		v.Receipt = receipt
		d.Operations[o.Plan.ID] = v
		return nil
	})
	if err != nil {
		return o, err
	}
	return next.Operations[o.Plan.ID], nil
}
func (c Coordinator) current(p Plan) error {
	if !planFresh(p, c.now()) {
		return errors.New("native_observation_expired")
	}
	d, err := c.Journal.Load()
	if err != nil {
		return err
	}
	e, ok := d.Entries[p.Source.Pane]
	if !ok || e.Source != p.Source || e.UserGeneration != p.UserGeneration || !e.Enabled || e.OptOut || e.Takeover || e.Pinned || (e.Manual && !d.Settings.RebalanceEnabled) {
		return errors.New("user_or_source_changed")
	}
	// Policy revision may advance for this operation's own durable transitions;
	// every real user settings edit changes the settings fingerprint pinned here.
	if p.SettingsSHA256 != SettingsHash(d.Settings) {
		return errors.New("settings_fingerprint_changed")
	}
	o := d.Operations[p.ID]
	if requestHash(o.Plan) != requestHash(p) {
		return errors.New("plan_changed")
	}
	return nil
}

// Advance consumes only a currently acquired native lease. Restart recovery
// never reconstructs a lease from journal bytes. Any intent-state reload holds.
func (c Coordinator) Advance(ctx context.Context, id string) (Operation, error) {
	d, err := c.Journal.Load()
	if err != nil {
		return Operation{}, err
	}
	o, ok := d.Operations[id]
	if !ok {
		return o, errors.New("operation unavailable")
	}
	if o.State == "held" || o.State == "completed" || o.State == "cancelled" || o.State == "unknown" || o.State == "confirmation_required" {
		return o, nil
	}
	if o.State != "prepared" && o.State != "source_exited" {
		return c.transition(id, "unknown", "pending_effect_requires_independent_reconciliation", "")
	}
	if c.Adapter == nil || !c.Adapter.Capabilities(o.Plan.Source).Ready() {
		return c.transition(id, "held", RetirementHold, "")
	}
	lease, err := c.Adapter.Acquire(ctx, o.Plan)
	if err != nil || lease == nil {
		return c.transition(id, "held", "native_capability_acquisition_unavailable", "")
	}
	if err = c.current(o.Plan); err != nil {
		return c.transition(id, "held", err.Error(), "")
	}
	if err = lease.VerifyLegacyLineage(ctx, o.Plan, d.Entries[o.Plan.Source.Pane]); err != nil {
		return c.transition(id, "held", "legacy_quota_lineage_requires_native_review", "")
	}
	if err = lease.Revalidate(ctx, o.Plan); err != nil {
		return c.transition(id, "held", "native_final_preflight_changed", "")
	}
	if o.State == "prepared" {
		o, err = c.effectIntent(o, "notice")
		if err != nil {
			return o, err
		}
		receipt, err := lease.Notice(ctx, o.Plan)
		if err != nil || receipt == "" {
			return c.transition(id, "unknown", "native_notice_outcome_unknown", "")
		}
		o, err = c.effectConfirmed(o, "notice", "notice_confirmed", receipt)
		if err != nil {
			return o, err
		}
		if err = c.current(o.Plan); err != nil {
			return c.transition(id, "held", err.Error(), "")
		}
		if err = lease.Revalidate(ctx, o.Plan); err != nil {
			return c.transition(id, "held", "native_final_preflight_changed", "")
		}
		o, err = c.effectIntent(o, "retire")
		if err != nil {
			return o, err
		}
		receipt, err = lease.RetirePreserving(ctx, o.Plan)
		if errors.Is(err, ErrConfirmation) {
			return c.transition(id, "confirmation_required", "scheduled_task_confirmation_requires_review", "")
		}
		if err != nil || receipt == "" {
			return c.transition(id, "unknown", "retirement_outcome_unknown", "")
		}
		if err = lease.VerifySourceExited(ctx, o.Plan); err != nil {
			return c.transition(id, "unknown", "source_exit_unverified", "")
		}
		o, err = c.effectConfirmed(o, "retire", "source_exited", receipt)
		if err != nil {
			return o, err
		}
	}
	if err = c.current(o.Plan); err != nil {
		return c.transition(id, "held", err.Error(), "")
	}
	if err = lease.Revalidate(ctx, o.Plan); err != nil {
		return c.transition(id, "held", "source_exited_recovery_requires_review", "")
	}
	if err = lease.NoPriorLaunch(ctx, o.Plan); err != nil {
		return c.transition(id, "unknown", "no_prior_launch_not_proven", "")
	}
	o, err = c.effectIntent(o, "launch")
	if err != nil {
		return o, err
	}
	receipt, err := lease.Launch(ctx, o.Plan)
	if err != nil || receipt == "" {
		return c.transition(id, "unknown", "launch_outcome_unknown", "")
	}
	if err = lease.VerifyTarget(ctx, o.Plan); err != nil {
		return c.transition(id, "unknown", "exact_target_account_session_image_unverified", "")
	}
	o, err = c.effectConfirmed(o, "launch", "target_verified", receipt)
	if err != nil {
		return o, err
	}
	if err = c.current(o.Plan); err != nil {
		return c.transition(id, "held", err.Error(), "")
	}
	o, err = c.effectIntent(o, "pickup")
	if err != nil {
		return o, err
	}
	receipt, err = lease.Pickup(ctx, o.Plan)
	if err != nil || receipt == "" {
		return c.transition(id, "unknown", "pickup_outcome_unknown", "")
	}
	if err = lease.VerifyPickup(ctx, o.Plan); err != nil {
		return c.transition(id, "unknown", "canonical_job_pickup_unverified", "")
	}
	completion, err := lease.Completion(ctx, o.Plan)
	if err != nil {
		return c.transition(id, "unknown", "independent_completion_receipt_unavailable", "")
	}
	if !fresh(completion.Counters.ObservedMS, c.now()) {
		return c.transition(id, "unknown", "completion_observation_expired", "")
	}
	if err = validateCompletion(o.Plan, completion); err != nil {
		return c.transition(id, "unknown", err.Error(), "")
	}
	next, err := c.persist(id+"-finalize", func(d *Disk) error {
		current := d.Operations[id]
		e := d.Entries[o.Plan.Source.Pane]
		if current.State != "pickup_intent" || current.Effects["pickup"] != "intent" || e.Source != o.Plan.Source || e.UserGeneration != o.Plan.UserGeneration || !e.Enabled || e.OptOut || e.Takeover || e.Pinned || o.Plan.SettingsSHA256 != SettingsHash(d.Settings) {
			return errors.New("finalization_source_or_policy_changed")
		}
		if e.Away != nil && o.Plan.Target == e.Away.OriginalAccount {
			if !canReturn(e, o.Plan.TargetQuota, d.Settings, o.Plan.ObservedMS) {
				return errors.New("quota_return_fence_changed")
			}
			e.Away = nil
		} else if e.Away == nil && containsReason(o.Plan, "quota") && o.Plan.Target != o.Plan.Source.Account {
			e.Away = &Away{OriginalAccount: o.Plan.Source.Account, OriginalConfig: o.Plan.Source.Config, Owner: id, Resets: o.Plan.TriggerResets}
		}
		e.Source = completion.Source
		if o.Plan.Mode == "fresh_context" {
			e.Baseline = completion.Counters.Tokens
			e.BaselineTurn = completion.Counters.Turn
			e.LastMoveMS = completion.Counters.ObservedMS
		}
		current.Effects["pickup"] = "confirmed"
		current.State = "completed"
		current.Reason = "exact_native_target_jobs_pickup_and_metadata_confirmed"
		current.Receipt = completion.Receipt
		d.Reservations[o.Plan.Source.Provider+":"+o.Plan.Target] = Reservation{Provider: o.Plan.Source.Provider, Account: o.Plan.Target, Operation: id, Pane: o.Plan.Source.Pane, AfterMS: completion.Counters.ObservedMS, Pending: false}
		d.Entries[e.Source.Pane] = e
		d.Operations[id] = current
		return nil
	})
	if err != nil {
		return o, err
	}
	return next.Operations[id], nil
}

var ErrConfirmation = errors.New("task-preserving exit confirmation required")

func SettingsHash(s Settings) string { raw, _ := json.Marshal(s); return Hash(raw) }

// Coalesce replaces only a data-preparation plan before ANY effect intent.
// Notice is also one-shot, so a changed plan after notice needs user review.
func (c Coordinator) Coalesce(ctx context.Context, p Plan) (Operation, error) {
	if err := ctx.Err(); err != nil {
		return Operation{}, err
	}
	d, err := c.Journal.Load()
	if err != nil {
		return Operation{}, err
	}
	old, ok := d.Operations[p.ID]
	if !ok {
		return c.Request(ctx, p)
	}
	if len(old.Effects) != 0 || (old.State != "held" && old.State != "prepared") || p.Source != old.Plan.Source || p.UserGeneration != old.Plan.UserGeneration || p.SettingsSHA256 != old.Plan.SettingsSHA256 {
		return old, errors.New("committed_or_changed_plan_cannot_coalesce")
	}
	for id, other := range d.Operations {
		if id != p.ID && !other.terminal() {
			return old, errors.New("shared_capacity_lane_busy")
		}
	}
	if !planFresh(p, c.now()) {
		return old, errors.New("native_observation_expired")
	}
	if accountReserved(d, p) {
		return old, errors.New("shared_account_observation_reserved")
	}
	e := d.Entries[p.Source.Pane]
	if !e.Enabled || e.UserGeneration != p.UserGeneration || e.Source != p.Source || p.SettingsSHA256 != SettingsHash(d.Settings) {
		return old, errors.New("policy_or_user_changed")
	}
	if !planDecisionAuthorized(p, e, d.Settings) {
		return old, errors.New("fresh_native_trigger_or_idle_evidence_unavailable")
	}
	if !policyTargetAuthorized(p, e, d.Settings) {
		return old, errors.New("target_capacity_or_reset_fence_unavailable")
	}
	if !planReasonsAuthorized(p, d.Settings) {
		return old, errors.New("native_policy_or_user_origin_not_authorized")
	}
	if p.Target != p.Source.Account && !approved(d.Settings, p.Source.Provider, p.Target) {
		return old, errors.New("target_not_approved")
	}
	if p.Mode != "fresh_context" && p.Mode != "resume_same_conversation" {
		return old, errors.New("invalid_move_mode")
	}
	if p.Mode == "fresh_context" && (p.NewSession == p.Source.Session || !identifier(p.NewSession)) {
		return old, errors.New("distinct_fresh_session_required")
	}
	if p.Mode == "resume_same_conversation" && p.NewSession != p.Source.Session {
		return old, errors.New("same_conversation_required")
	}
	old.Plan = p
	old.State = "held"
	old.Reason = RetirementHold
	if c.Adapter != nil && c.Adapter.Capabilities(p.Source).Ready() && ValidatePreparation(p.Preparation, p.Source, p.SourceSHA256, p.Turn) == nil && hexDigest(p.InstalledImage) {
		old.State = "prepared"
		old.Reason = "checked_data_prepared"
	}
	raw, _ := json.Marshal(p)
	key := p.ID + "-merge-" + Hash(raw)[:16]
	next, err := c.Journal.Update(key, Hash(raw), d.Revision, func(state *Disk) error {
		current := state.Operations[p.ID]
		if len(current.Effects) != 0 || current.State != d.Operations[p.ID].State {
			return errors.New("operation changed")
		}
		for key, r := range state.Reservations {
			if r.Operation == p.ID {
				delete(state.Reservations, key)
			}
		}
		if old.State == "prepared" {
			state.Reservations[p.Source.Provider+":"+p.Target] = Reservation{Provider: p.Source.Provider, Account: p.Target, Operation: p.ID, Pane: p.Source.Pane, Pending: true}
		}
		state.Operations[p.ID] = old
		return nil
	})
	if err != nil {
		return old, err
	}
	return next.Operations[p.ID], nil
}

// ReconcileSourceExit accepts only independent native observations, never a
// model/transport-write acknowledgement. It may classify an old exit forward;
// it cannot reissue exit or a possibly issued target launch.
func (c Coordinator) ReconcileSourceExit(ctx context.Context, id string) (Operation, error) {
	d, err := c.Journal.Load()
	if err != nil {
		return Operation{}, err
	}
	o, ok := d.Operations[id]
	if !ok {
		return o, errors.New("operation unavailable")
	}
	if (o.State != "unknown" && o.State != "retire_intent" && o.State != "confirmation_required") || o.Effects["retire"] == "" {
		return o, errors.New("no retirement intent to reconcile")
	}
	if _, issued := o.Effects["launch"]; issued {
		return o, errors.New("launch outcome requires its own exact receipt; no replay")
	}
	if c.Adapter == nil || !c.Adapter.Capabilities(o.Plan.Source).Ready() {
		return o, errors.New(RetirementHold)
	}
	if err = c.current(o.Plan); err != nil {
		return o, err
	}
	lease, err := c.Adapter.Acquire(ctx, o.Plan)
	if err != nil || lease == nil {
		return o, errors.New("independent native evidence unavailable")
	}
	if lease.Revalidate(ctx, o.Plan) != nil || lease.VerifySourceExited(ctx, o.Plan) != nil || lease.NoPriorLaunch(ctx, o.Plan) != nil {
		return o, errors.New("independent exit/no-launch evidence unavailable")
	}
	next, err := c.persist(id+"-exit-reconciled", func(d *Disk) error {
		v := d.Operations[id]
		if v.State != o.State || v.Effects["launch"] != "" {
			return errors.New("operation changed")
		}
		v.State = "source_exited"
		v.Effects["retire"] = "confirmed"
		v.Reason = "independently_reconciled_source_exit"
		d.Operations[id] = v
		return nil
	})
	if err != nil {
		return o, err
	}
	return next.Operations[id], nil
}

func planReasonsAuthorized(p Plan, s Settings) bool {
	if len(p.Reasons) == 0 || len(p.Reasons) > 8 {
		return false
	}
	seen := map[string]bool{}
	fresh := false
	for _, r := range p.Reasons {
		if seen[r] {
			return false
		}
		seen[r] = true
		switch r {
		case "context":
			if !s.ContextEnabled || p.Origin != "automation" {
				return false
			}
			fresh = true
		case "quota", "return":
			if !s.QuotaEnabled || p.Origin != "automation" {
				return false
			}
			fresh = true
		case "rebalance":
			if !s.RebalanceEnabled || p.Origin != "automation" {
				return false
			}
			fresh = true
		case "installed_update":
			if !s.AdoptInstalledUpdates || p.Origin != "automation" {
				return false
			}
		case "manual_refresh", "manual_move":
			if p.Origin != "native_user" {
				return false
			}
			fresh = true
		default:
			return false
		}
	}
	if fresh {
		return p.Mode == "fresh_context"
	}
	return p.Mode == "resume_same_conversation" && p.Target == p.Source.Account && p.TargetConfig == p.Source.Config
}

func containsReason(p Plan, reason string) bool {
	for _, r := range p.Reasons {
		if r == reason {
			return true
		}
	}
	return false
}
func policyTargetAuthorized(p Plan, e Entry, s Settings) bool {
	if p.Target == "" || p.TargetConfig == "" {
		return false
	}
	changing := containsReason(p, "quota") || containsReason(p, "return") || containsReason(p, "rebalance") || containsReason(p, "manual_move")
	if !changing && (p.Target != p.Source.Account || p.TargetConfig != p.Source.Config) {
		return false
	}
	if e.Away != nil && p.Target == e.Away.OriginalAccount && !canReturn(e, p.TargetQuota, s, p.ObservedMS) {
		return false
	}
	if containsReason(p, "quota") {
		if !p.SourceQuota.Current(p.ObservedMS) || p.SourceQuota.Label != p.Source.Account || p.SourceQuota.Config != p.Source.Config || p.SourceQuota.Provider != p.Source.Provider || p.SourceQuota.Model != p.Source.Model {
			return false
		}
		expected := triggers(p.SourceQuota, s)
		if len(expected) == 0 || len(expected) != len(p.TriggerResets) {
			return false
		}
		for name, r := range expected {
			if p.TriggerResets[name] != r {
				return false
			}
		}
	}
	if p.Target != p.Source.Account && changing {
		if !p.TargetQuota.Current(p.ObservedMS) || p.TargetQuota.Label != p.Target || p.TargetQuota.Config != p.TargetConfig || p.TargetQuota.Provider != p.Source.Provider || p.TargetQuota.Model != p.Source.Model {
			return false
		}
		for _, w := range p.TargetQuota.Windows {
			if w.Used >= s.TargetCeiling {
				return false
			}
		}
	}
	return true
}
func validateCompletion(p Plan, c Completion) error {
	s := c.Source
	old := p.Source
	if !s.Valid() || s.Host != old.Host || s.Boot != old.Boot || s.Pane != old.Pane || s.WorkerPID != old.WorkerPID || s.WorkerStart != old.WorkerStart || s.Provider != old.Provider || s.Model != old.Model || s.Root != old.Root || s.Session != p.NewSession || s.Account != p.Target || s.Config != p.TargetConfig || (s.PID == old.PID && s.Start == old.Start) {
		return errors.New("exact_target_identity_unconfirmed")
	}
	if c.ImageSHA256 != p.InstalledImage || c.CapsuleSHA256 != p.Preparation.Capsule.SHA256 || c.Receipt == "" {
		return errors.New("target_image_or_canonical_hash_unconfirmed")
	}
	if !c.PermissionsRetained || c.LinkSource != old.Session || c.LinkTarget != p.NewSession {
		return errors.New("exact_link_lineage_or_permissions_unconfirmed")
	}
	if len(c.Jobs) != len(p.Preparation.Jobs) {
		return errors.New("job_pickup_coverage_unconfirmed")
	}
	for _, j := range p.Preparation.Jobs {
		v, ok := c.Jobs[j.ID]
		if !ok || (v.State != "same_incarnation" && v.State != "finished") || v.Host != j.Host || v.Boot != j.Boot || v.PID != j.PID || v.Start != j.Start || !hexDigest(v.EvidenceSHA256) {
			return errors.New("exact_job_pickup_unconfirmed")
		}
	}
	if p.Mode == "resume_same_conversation" && c.Counters.Turn < p.Counters.Turn {
		return errors.New("same_conversation_watermark_regressed")
	}
	if c.Counters.Session != s.Session || !c.Counters.CompletedIdle || c.Counters.Turn == 0 || c.Counters.Tokens <= 0 || c.Counters.Window <= c.Counters.Tokens || c.Counters.ObservedMS <= 0 {
		return errors.New("fresh_pickup_baseline_unconfirmed")
	}
	return nil
}

func planDecisionAuthorized(p Plan, e Entry, s Settings) bool {
	if p.Counters.Session != e.Source.Session || !p.Counters.CompletedIdle || p.Counters.Turn == 0 || !fresh(p.Counters.ObservedMS, p.ObservedMS) {
		return false
	}
	if p.Origin == "native_user" {
		return true
	}
	onlyUpdate := len(p.Reasons) == 1 && containsReason(p, "installed_update")
	d := Decide(e, s, p.Counters, p.Accounts, p.ObservedMS)
	if onlyUpdate {
		return !d.ContextDue && !d.QuotaDue && !d.ReturnDue && !d.RebalanceDue && hexDigest(p.CurrentImage) && p.CurrentImage != p.InstalledImage
	}
	return (d.State == "policy_due_capability_held") && containsReason(p, "context") == d.ContextDue && containsReason(p, "quota") == d.QuotaDue && containsReason(p, "return") == d.ReturnDue && containsReason(p, "rebalance") == d.RebalanceDue && p.Target == d.Target && p.TargetConfig == d.TargetConfig
}

func accountReserved(d Disk, p Plan) bool {
	r, ok := d.Reservations[p.Source.Provider+":"+p.Target]
	return ok && r.Operation != p.ID && (r.Pending || p.TargetQuota.ObservedMS <= r.AfterMS)
}

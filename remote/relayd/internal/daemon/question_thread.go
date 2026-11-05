package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"time"
)

// A question thread binds one live pane to one chitta question. The pane's
// session holds a chitta lease on the thread; relayd renews it while the pane
// stays bound to the same session and process, and notifies the pane when the
// thread's job or question changes. chitta is the authority for the lease and
// the event log. relayd stores only the cursor and a delivery outbox.

const (
	questionThreadDirectory   = "question-threads"
	questionPollInterval      = 30 * time.Second
	questionDefaultTTLSeconds = 900
	questionMinTTLSeconds     = 30
	questionMaxTTLSeconds     = 86400
	questionOutboxLimit       = 64
)

// Release stages. A record that is releasing is never renewed, polled or
// delivered from. Only its remaining cleanup is retried.
const (
	questionReleaseLease   = "lease"
	questionReleaseCleanup = "cleanup"
)

var (
	questionThreadID = regexp.MustCompile(`^[A-Za-z0-9_:.-]{1,128}$`)
	questionRealm    = regexp.MustCompile(`^[A-Za-z0-9_:.-]{1,128}$`)
)

// questionLedger is the chitta ledger_op transport. Production uses
// callHostNativeLedger; tests substitute a fake.
type questionLedger func(ctx context.Context, operation string, args any) (json.RawMessage, error)

type questionThreadDeps struct {
	ledger     questionLedger
	binding    func(pane string) (AgentBindingRecord, error)
	cwd        func(pane string) (string, error)
	store      questionThreadStore
	configHome string
	// lock serializes every read-modify-write of bindings and outboxes across
	// processes. It is the communication root flock that ExecuteCommunication
	// already holds for app requests, so callers of the state functions must
	// hold it. Tests substitute a no-op.
	lock func() (unlock func(), err error)
	// send delivers one notice on the Relay app's request. status is the native
	// admission status. definitelyNotSent is true only when nothing reached the pane.
	send func(ctx context.Context, pane, messageID, text string, admitted questionRecipient) (status string, definitelyNotSent bool, err error)
	now  func() time.Time
}

type questionThreadBinding struct {
	Version      int                   `json:"version"`
	PaneID       string                `json:"pane_id"`
	SessionID    string                `json:"session_id"`
	Provider     string                `json:"provider"`
	ProcessID    int                   `json:"process_id"`
	ProcessStart uint64                `json:"process_start"`
	ThreadID     string                `json:"thread_id"`
	Realm        string                `json:"realm"`
	Generation   uint64                `json:"generation"`
	TTLSeconds   int                   `json:"ttl_seconds"`
	RenewAt      time.Time             `json:"renew_at"`
	Cursor       uint64                `json:"cursor"`
	PolledAt     time.Time             `json:"polled_at"`
	Outbox       []questionOutboxEntry `json:"outbox,omitempty"`
	Acks         []questionNoticeAck   `json:"acks,omitempty"`
	// ReleaseStage is persisted before a release starts, so a failed step is
	// retried as the same step and never turns into a new lease claim.
	ReleaseStage string `json:"release_stage,omitempty"`
	// Incarnation identifies one bind. It is fresh for every bind and never reused,
	// so a completion from an earlier bind of the same pane cannot touch this one.
	Incarnation string `json:"incarnation,omitempty"`
	// Phase is questionThreadPhaseReserved while a bind is in flight. ReservedAt
	// lets a tick clear a reservation whose bind never finished.
	Phase      string    `json:"phase,omitempty"`
	ReservedAt time.Time `json:"reserved_at,omitempty"`
	// LeasePending is set while the bind holds no confirmed lease, because an
	// older mutation on its key is unresolved. Notices wait until it is cleared.
	LeasePending bool `json:"lease_pending,omitempty"`
	// LeaseEpoch is the lease_epoch of the lease this bind holds. It is nil when
	// chitta returned none, and the release then sends no epoch.
	LeaseEpoch *uint64 `json:"lease_epoch,omitempty"`
}

// Outbox states only move forward. "sending" is persisted before the write, so
// a crash mid-send leaves it as outcome_unknown on reload, never queued again.
const (
	questionOutboxQueued         = "queued"
	questionOutboxSending        = "sending"
	questionOutboxOutcomeUnknown = "outcome_unknown"
)

type questionOutboxEntry struct {
	Revision  uint64 `json:"revision"`
	MessageID string `json:"message_id"`
	Text      string `json:"text"`
	State     string `json:"state"`
}

type questionLeaseReply struct {
	Claimed        bool   `json:"claimed"`
	Reason         string `json:"reason,omitempty"`
	OwnerSessionID string `json:"owner_session_id,omitempty"`
	Generation     uint64 `json:"generation,omitempty"`
	// LeaseEpoch is chitta's lease_epoch. It is nil until chitta returns one.
	LeaseEpoch *uint64 `json:"lease_epoch,omitempty"`
}

type questionEventRow struct {
	Revision uint64         `json:"revision"`
	Op       string         `json:"op"`
	Table    string         `json:"table"`
	ID       string         `json:"id"`
	ThreadID string         `json:"thread_id"`
	Realm    string         `json:"realm"`
	Row      map[string]any `json:"row"`
}

type questionEventsReply struct {
	Rows     []questionEventRow `json:"rows"`
	Revision uint64             `json:"revision"`
}

func defaultQuestionThreadDeps(home string, getenv func(string) string) questionThreadDeps {
	configHome := getenv("XDG_CONFIG_HOME")
	if configHome == "" {
		configHome = filepath.Join(home, ".config")
	}
	return questionThreadDeps{
		ledger:     callHostNativeLedger,
		binding:    ReadVerifiedAgentBinding,
		cwd:        paneWorkingDirectory,
		store:      questionThreadStore{dir: filepath.Join(defaultWorkerStateDir(), questionThreadDirectory)},
		configHome: configHome,
		lock:       lockCommunicationRootForQuestions,
		// Until the pane-messaging path is wired, nothing is written to a pane.
		send: func(context.Context, string, string, string, questionRecipient) (string, bool, error) {
			return "", true, errors.New("question thread delivery is not wired")
		},
		now: time.Now,
	}
}

func paneWorkingDirectory(pane string) (string, error) {
	if !validSessionID.MatchString(pane) {
		return "", errors.New("invalid pane")
	}
	manifest, err := loadManifest(NewServer().manifestPath(pane))
	if err != nil || manifest.SessionID != pane || validateWorkerIdentity(manifest) != nil || manifest.WorkingDirectory == "" {
		return "", errors.New("pane working directory unavailable")
	}
	return manifest.WorkingDirectory, nil
}

// bindQuestionThread refuses a live owner. There is no force path for agents.
// The pane is reserved under the question-state lock first. chitta and the
// opt-in are then touched with no lock held, and the binding is committed
// under the lock only if the reservation is still this bind's.
func bindQuestionThread(ctx context.Context, deps questionThreadDeps, pane, threadID, realm string, ttl int) (questionThreadBinding, error) {
	if !validSessionID.MatchString(pane) || !questionThreadID.MatchString(threadID) || !questionRealm.MatchString(realm) {
		return questionThreadBinding{}, errors.New("invalid question thread binding request")
	}
	if ttl == 0 {
		ttl = questionDefaultTTLSeconds
	}
	if ttl < questionMinTTLSeconds || ttl > questionMaxTTLSeconds {
		return questionThreadBinding{}, errors.New("question thread ttl out of range")
	}
	reservation := questionThreadBinding{Version: 1, PaneID: pane, ThreadID: threadID, Realm: realm,
		TTLSeconds: ttl, Phase: questionThreadPhaseReserved, ReservedAt: deps.now()}
	err := deps.withQuestionState(func() error {
		existing, found, err := deps.store.load(pane)
		if err != nil {
			return err
		}
		if found && existing.Phase == questionThreadPhaseReserved {
			return errors.New("question thread binding is already in progress for this pane")
		}
		if found {
			return fmt.Errorf("pane is already bound to question thread %s", existing.ThreadID)
		}
		return deps.store.save(reservation)
	})
	if err != nil {
		return questionThreadBinding{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, questionBindTimeout)
	defer cancel()
	return finishQuestionBind(ctx, deps, reservation)
}

// finishQuestionBind runs the external steps of a bind for a reserved pane. A
// failure before chitta grants a lease removes the reservation. A failure after
// it releases the lease through the release path, which keeps its own retry.
func finishQuestionBind(ctx context.Context, deps questionThreadDeps, reservation questionThreadBinding) (questionThreadBinding, error) {
	pane := reservation.PaneID
	abandon := func(err error) (questionThreadBinding, error) {
		cleanupErr := deps.withQuestionState(func() error {
			existing, found, err := deps.store.load(pane)
			if err != nil || !found || existing.Phase != questionThreadPhaseReserved {
				return err
			}
			return deps.store.remove(pane)
		})
		return questionThreadBinding{}, errors.Join(err, cleanupErr)
	}
	record, err := deps.binding(pane)
	if err != nil {
		return abandon(errors.New("verified agent binding unavailable"))
	}
	provider := record.Producer.Provider
	if provider != "claude" && provider != "codex" || !questionClassifierSession.MatchString(record.SessionID) {
		return abandon(errors.New("pane has no bound provider session"))
	}
	cwd, err := deps.cwd(pane)
	if err != nil {
		return abandon(err)
	}
	if _, err := questionCall(ctx, deps, "session_bind", map[string]any{"session_id": record.SessionID,
		"client": provider, "cwd": cwd, "owner": "relay"}); err != nil {
		return abandon(errors.New("chitta session bind unavailable"))
	}
	if stateRealm, ok := questionStateRealm(ctx, deps, reservation.ThreadID); ok && stateRealm != reservation.Realm {
		return abandon(errors.New("question thread realm does not match chitta"))
	}
	claim, held, err := claimTrackedLease(ctx, deps, record.SessionID, reservation.ThreadID, reservation.TTLSeconds)
	if err != nil {
		// The claim may have been granted, so its lease is recorded to be released.
		orphanErr := deps.saveQuestionOrphan(record.SessionID, reservation.ThreadID, nil)
		return abandon(errors.Join(err, orphanErr))
	}
	if !held && !claim.Claimed {
		if claim.Reason == "live_owner" {
			return abandon(fmt.Errorf("question thread is held by live owner session %s; not overriding", claim.OwnerSessionID))
		}
		return abandon(errors.New("question thread lease not granted"))
	}
	incarnation, err := newHostNativeUUID()
	if err != nil {
		return abandon(err)
	}
	binding := questionThreadBinding{Version: 1, PaneID: pane, SessionID: record.SessionID, Provider: provider,
		Incarnation: incarnation,
		ProcessID:   record.Producer.ProcessID, ProcessStart: record.Producer.ProcessStart,
		ThreadID: reservation.ThreadID, Realm: reservation.Realm, Generation: claim.Generation,
		TTLSeconds: reservation.TTLSeconds, RenewAt: deps.now().Add(time.Duration(reservation.TTLSeconds) * time.Second / 2),
		LeasePending: held, LeaseEpoch: claim.LeaseEpoch}
	if held {
		// Renewal claims this lease as soon as its key is clear.
		binding.RenewAt = deps.now()
	}
	// From here the lease is held. Any failure releases it.
	commitErr := deps.withQuestionState(func() error {
		existing, found, err := deps.store.load(pane)
		if err != nil {
			return err
		}
		if !found || existing.Phase != questionThreadPhaseReserved {
			return errors.New("question thread reservation was lost")
		}
		// The opt-in waits for a confirmed lease, so a held bind is inert.
		if provider == "codex" && !binding.LeasePending {
			if err := writeQuestionClassifierOptIn(deps.configHome, record.SessionID); err != nil {
				return err
			}
		}
		return deps.store.save(binding)
	})
	if commitErr != nil {
		return questionThreadBinding{}, errors.Join(commitErr, releaseClaimedQuestionLease(ctx, deps, binding))
	}
	return binding, nil
}

// releaseClaimedQuestionLease records a lease that a bind holds and releases it
// through releaseQuestionThread, so a failed release is retried by the tick. If
// the record can no longer be written, the lease is released directly.
func releaseClaimedQuestionLease(ctx context.Context, deps questionThreadDeps, binding questionThreadBinding) error {
	err := deps.withQuestionState(func() error {
		existing, found, err := deps.store.load(binding.PaneID)
		if err != nil {
			return err
		}
		if found && existing.Phase != questionThreadPhaseReserved {
			return errors.New("question thread binding changed during bind")
		}
		return deps.store.save(binding)
	})
	if err != nil {
		cleanupErr := error(nil)
		if binding.Provider == "codex" {
			cleanupErr = removeQuestionClassifierOptIn(deps.configHome, binding.SessionID)
		}
		return errors.Join(err, releaseQuestionLease(ctx, deps, binding), cleanupErr)
	}
	return releaseQuestionThread(ctx, deps, binding.PaneID)
}

func claimQuestionLease(ctx context.Context, deps questionThreadDeps, sessionID, threadID string, ttl int) (questionLeaseReply, error) {
	raw, err := questionCall(ctx, deps, "lease_claim", map[string]any{"thread_id": threadID, "session_id": sessionID, "ttl": ttl})
	if err != nil {
		return questionLeaseReply{}, errors.New("chitta lease claim unavailable")
	}
	var reply questionLeaseReply
	if json.Unmarshal(raw, &reply) != nil {
		return questionLeaseReply{}, errors.New("invalid chitta lease reply")
	}
	return reply, nil
}

// renewQuestionThread renews the lease at half its TTL, for the bind the snapshot
// describes. A held binding, whose lease is not confirmed, claims as soon as its
// key has no unresolved mutation. The thread is released if the pane's session or
// process changed. The commit is fenced on the bind's incarnation. A claim that
// lands after the pane was rebound is judged by its key: a live record on the same
// key owns it, and any other claim is recorded as an orphan and released. A claim
// that lands after the record was removed writes a tombstone and releases through
// the normal release path.
func renewQuestionThread(ctx context.Context, deps questionThreadDeps, snapshot questionThreadBinding) (questionThreadBinding, error) {
	stored, found, err := deps.loadQuestionState(snapshot.PaneID)
	if err != nil {
		return snapshot, err
	}
	if !found || stored.Phase == questionThreadPhaseReserved {
		return snapshot, errors.New("no active question thread binding for this pane")
	}
	if !sameQuestionBinding(stored, snapshot) {
		return stored, errors.New("question thread binding changed; not renewed")
	}
	if stored.ReleaseStage != "" {
		return stored, releaseQuestionThread(ctx, deps, stored.PaneID)
	}
	if !stored.LeasePending && deps.now().Before(stored.RenewAt) {
		return stored, nil
	}
	current, err := deps.binding(stored.PaneID)
	if err != nil {
		return stored, errors.New("verified agent binding unavailable; lease not renewed")
	}
	if current.SessionID != stored.SessionID || current.Producer.ProcessID != stored.ProcessID ||
		current.Producer.ProcessStart != stored.ProcessStart {
		return stored, releaseQuestionThread(ctx, deps, stored.PaneID)
	}
	claim, held, err := claimTrackedLease(ctx, deps, stored.SessionID, stored.ThreadID, stored.TTLSeconds)
	if held {
		// An older mutation on this key is unresolved. The claim waits for it.
		return stored, nil
	}
	if err != nil {
		return stored, err
	}
	if !claim.Claimed {
		return stored, errors.Join(errors.New("question thread lease lost"), releaseQuestionThread(ctx, deps, stored.PaneID))
	}
	const (
		committed = iota
		leftToNewer
		orphaned
		tombstoned
	)
	outcome := committed
	releaseOwn := false
	var result questionThreadBinding
	var orphan questionLeaseOrphan
	err = deps.withQuestionState(func() error {
		latest, found, err := deps.store.load(stored.PaneID)
		if err != nil {
			return err
		}
		switch {
		case found && sameQuestionBinding(latest, stored) && latest.ReleaseStage == "":
			if latest.LeasePending && latest.Provider == "codex" {
				// Confirming a held bind is what turns its opt-in on. A failed write
				// leaves the bind held, and the next renewal retries it.
				if err := writeQuestionClassifierOptIn(deps.configHome, latest.SessionID); err != nil {
					return err
				}
			}
			latest.Generation = claim.Generation
			latest.LeaseEpoch = claim.LeaseEpoch
			latest.LeasePending = false
			latest.RenewAt = deps.now().Add(time.Duration(latest.TTLSeconds) * time.Second / 2)
			if err := deps.store.save(latest); err != nil {
				return err
			}
			result = latest
		case found && sameQuestionBinding(latest, stored):
			// This bind is releasing. Its claim may have landed after its release
			// call, so the key is released again after the orphan is recorded.
			outcome, releaseOwn, result = orphaned, true, latest
			orphan, err = deps.recordOrphanLocked(stored.SessionID, stored.ThreadID, claim.LeaseEpoch)
			return err
		case found && latest.ReleaseStage == "" && latest.SessionID == stored.SessionID && latest.ThreadID == stored.ThreadID:
			// A newer bind on the same key owns this claim, so it is left alone.
			outcome = leftToNewer
			return appendQuestionLog(communicationRoot(), fmt.Sprintf("renewal of %s landed after rebind on the same key; left to the newer bind at %s",
				stored.PaneID, deps.now().UTC().Format(time.RFC3339)))
		case found:
			// A newer record has another key or is releasing. Nothing owns this claim.
			outcome = orphaned
			orphan, err = deps.recordOrphanLocked(stored.SessionID, stored.ThreadID, claim.LeaseEpoch)
			return err
		default:
			incarnation, err := newHostNativeUUID()
			if err != nil {
				return err
			}
			tombstone := stored
			tombstone.Incarnation = incarnation
			tombstone.Generation = claim.Generation
			tombstone.Phase = ""
			tombstone.LeasePending = false
			// The late claim may have granted a new epoch, so the tombstone releases that one.
			tombstone.LeaseEpoch = claim.LeaseEpoch
			tombstone.Outbox = nil
			tombstone.Acks = nil
			tombstone.ReleaseStage = questionReleaseLease
			if err := deps.store.save(tombstone); err != nil {
				return err
			}
			outcome = tombstoned
			result = tombstone
		}
		return nil
	})
	if err != nil {
		return stored, err
	}
	// This claim may have resolved the last older mutation on the key, so a held
	// rebind on it can be confirmed now, without waiting for the next tick.
	reacquireHeldLeases(ctx, deps, stored.SessionID, stored.ThreadID)
	switch outcome {
	case orphaned:
		if err := settleQuestionOrphan(ctx, deps, orphan); err != nil {
			return stored, err
		}
		if releaseOwn {
			return result, releaseQuestionThread(ctx, deps, stored.PaneID)
		}
		return stored, nil
	case tombstoned:
		return result, releaseQuestionThread(ctx, deps, stored.PaneID)
	}
	return result, nil
}

func releaseQuestionLease(ctx context.Context, deps questionThreadDeps, binding questionThreadBinding) error {
	return releaseLeaseKey(ctx, deps, questionLeaseOp{SessionID: binding.SessionID, ThreadID: binding.ThreadID}, binding.LeaseEpoch)
}

// releaseQuestionThread releases the stored bind for pane in persisted stages:
// the lease, then the opt-in and the record. Every stage change and the final
// cleanup are fenced on the incarnation the release started from, so a release
// that finishes late can change nothing that a newer bind wrote. The opt-in is
// removed under the same lock as the record check. A failed stage is retried by
// the tick. If the record is gone or replaced, the release is already done.
func releaseQuestionThread(ctx context.Context, deps questionThreadDeps, pane string) error {
	binding, found, err := deps.loadQuestionState(pane)
	if err != nil || !found {
		return err
	}
	if binding.Phase == questionThreadPhaseReserved {
		return errors.New("question thread binding is in progress")
	}
	if binding.ReleaseStage == "" {
		if err := setQuestionReleaseStage(deps, binding, questionReleaseLease); err != nil {
			return ignoreSupersededRelease(err)
		}
		binding.ReleaseStage = questionReleaseLease
	}
	if binding.ReleaseStage == questionReleaseLease {
		if err := releaseQuestionLease(ctx, deps, binding); err != nil {
			return err
		}
		// This release may have resolved the last older mutation on the key, so
		// held rebinds on it can claim now.
		reacquireHeldLeases(ctx, deps, binding.SessionID, binding.ThreadID)
		if err := setQuestionReleaseStage(deps, binding, questionReleaseCleanup); err != nil {
			return ignoreSupersededRelease(err)
		}
		binding.ReleaseStage = questionReleaseCleanup
	}
	return ignoreSupersededRelease(finishQuestionRelease(deps, binding))
}

// finishQuestionRelease removes the opt-in and the record for one bind. It runs
// under the question-state lock and returns errReleaseSuperseded, without any
// side effect, when the stored record is another bind.
func finishQuestionRelease(deps questionThreadDeps, binding questionThreadBinding) error {
	return deps.withQuestionState(func() error {
		latest, found, err := deps.store.load(binding.PaneID)
		if err != nil {
			return err
		}
		if !found || !sameQuestionBinding(latest, binding) {
			return errReleaseSuperseded
		}
		if binding.Provider == "codex" {
			if err := removeQuestionClassifierOptIn(deps.configHome, binding.SessionID); err != nil {
				return err
			}
		}
		return deps.store.remove(binding.PaneID)
	})
}

// errReleaseSuperseded means the record a release started from is gone or has
// been replaced, so there is nothing left for that release to do.
var errReleaseSuperseded = errors.New("question thread binding was superseded")

func ignoreSupersededRelease(err error) error {
	if errors.Is(err, errReleaseSuperseded) {
		return nil
	}
	return err
}

// setQuestionReleaseStage moves the stored record to stage, if it is still the
// binding the release started from. Only the stage changes, so an outbox or
// cursor written meanwhile is kept.
func setQuestionReleaseStage(deps questionThreadDeps, binding questionThreadBinding, stage string) error {
	return deps.withQuestionState(func() error {
		latest, found, err := deps.store.load(binding.PaneID)
		if err != nil {
			return err
		}
		if !found || !sameQuestionBinding(latest, binding) {
			return errReleaseSuperseded
		}
		latest.ReleaseStage = stage
		return deps.store.save(latest)
	})
}

// unbindQuestionThread releases the thread for a pane, if it is bound.
func unbindQuestionThread(ctx context.Context, deps questionThreadDeps, pane string) (bool, error) {
	binding, found, err := deps.loadQuestionState(pane)
	if err != nil || !found {
		return false, err
	}
	if binding.Phase == questionThreadPhaseReserved {
		return false, errors.New("question thread binding is in progress")
	}
	return true, releaseQuestionThread(ctx, deps, pane)
}

func questionStateRealm(ctx context.Context, deps questionThreadDeps, threadID string) (string, bool) {
	raw, err := questionCall(ctx, deps, "question_state", map[string]any{"thread_id": threadID})
	if err != nil {
		return "", false
	}
	var reply struct {
		Realm string `json:"realm"`
	}
	if json.Unmarshal(raw, &reply) != nil || !questionRealm.MatchString(reply.Realm) {
		return "", false
	}
	return reply.Realm, true
}

// pollQuestionThread reads chitta events at most once per questionPollInterval
// and records notices for the Relay app to pull. The chitta read holds no lock.
// Its rows are merged into the stored record only if that binding is still
// active, and only rows past the stored cursor are added.
func pollQuestionThread(ctx context.Context, deps questionThreadDeps, stale questionThreadBinding) (questionThreadBinding, error) {
	stored, found, err := deps.loadQuestionState(stale.PaneID)
	if err != nil {
		return stale, err
	}
	if !found || stored.Phase == questionThreadPhaseReserved {
		return stale, errors.New("no active question thread binding for this pane")
	}
	if stored.ReleaseStage != "" {
		return stored, errors.New("question thread is releasing; not polled")
	}
	if stored.LeasePending {
		// A held bind has no confirmed lease, so it polls nothing.
		return stored, nil
	}
	now := deps.now()
	if !stored.PolledAt.IsZero() && now.Sub(stored.PolledAt) < questionPollInterval {
		return stored, nil
	}
	raw, err := questionCall(ctx, deps, "question_events", map[string]any{"after_revision": stored.Cursor, "realm": stored.Realm})
	if err != nil {
		return stored, errors.New("chitta question events unavailable")
	}
	var reply questionEventsReply
	if json.Unmarshal(raw, &reply) != nil || reply.Revision < stored.Cursor {
		return stored, errors.New("invalid chitta question events reply")
	}
	var fresh []questionOutboxEntry
	for _, row := range reply.Rows {
		if row.ThreadID != stored.ThreadID || row.Revision <= stored.Cursor {
			continue
		}
		if text, ok := questionNotificationText(row); ok {
			messageID, err := newHostNativeUUID()
			if err != nil {
				return stored, err
			}
			fresh = append(fresh, questionOutboxEntry{Revision: row.Revision,
				MessageID: messageID, Text: text, State: questionOutboxQueued})
		}
	}
	result := stored
	err = deps.withQuestionState(func() error {
		latest, found, err := deps.store.load(stored.PaneID)
		if err != nil {
			return err
		}
		if !found || latest.Phase == questionThreadPhaseReserved || latest.ReleaseStage != "" || !sameQuestionBinding(latest, stored) {
			return errors.New("question thread binding changed during poll; events not recorded")
		}
		for _, entry := range fresh {
			if entry.Revision > latest.Cursor {
				latest.Outbox = append(latest.Outbox, entry)
			}
		}
		if reply.Revision > latest.Cursor {
			latest.Cursor = reply.Revision
		}
		latest.PolledAt = now
		if err := deps.store.save(latest); err != nil {
			return err
		}
		result = latest
		return nil
	})
	return result, err
}

// questionNotificationText covers the three events that wake a pane: a
// terminal job, a closed question, and a correction note. Only IDs and enum
// values are copied; free text from the row never reaches the pane.
func questionNotificationText(row questionEventRow) (string, bool) {
	switch {
	case row.Op == "job_update":
		status, _ := row.Row["status"].(string)
		if status == "done" || status == "failed" || status == "lost" {
			return fmt.Sprintf("Chitta question thread %s: job %s is %s (revision %d).", row.ThreadID, row.ID, status, row.Revision), true
		}
	case row.Op == "question_close":
		return fmt.Sprintf("Chitta question thread %s was closed (revision %d).", row.ThreadID, row.Revision), true
	case row.Op == "question_note":
		if kind, _ := row.Row["kind"].(string); kind == "correction" {
			return fmt.Sprintf("Chitta question thread %s has a correction note (revision %d).", row.ThreadID, row.Revision), true
		}
	}
	return "", false
}

// settleQuestionOutbox turns entries left in "sending" by a crash into
// outcome_unknown. Those are never replayed.
func settleQuestionOutbox(binding questionThreadBinding) questionThreadBinding {
	for index := range binding.Outbox {
		if binding.Outbox[index].State == questionOutboxSending {
			binding.Outbox[index].State = questionOutboxOutcomeUnknown
		}
	}
	if len(binding.Outbox) > questionOutboxLimit {
		binding.Outbox = binding.Outbox[len(binding.Outbox)-questionOutboxLimit:]
	}
	return binding
}

// questionThreadPhaseReserved marks a record while its bind is in flight.
const questionThreadPhaseReserved = "reserved"

// External calls are bounded. Each chitta call and each native step has its own
// deadline, and none runs while the question-state lock is held.
const (
	questionBindTimeout    = 45 * time.Second
	questionSendTimeout    = 45 * time.Second
	questionReserveTimeout = 3 * time.Minute
)

// questionCallTimeout bounds each chitta call. A variable so tests can shorten it.
var questionCallTimeout = 10 * time.Second

// questionRecipient is the pane identity a notice was admitted for. Delivery
// refuses unless the pane still matches it.
type questionRecipient struct {
	SessionID    string
	ProcessID    int
	ProcessStart uint64
}

func (binding questionThreadBinding) recipient() questionRecipient {
	return questionRecipient{SessionID: binding.SessionID, ProcessID: binding.ProcessID, ProcessStart: binding.ProcessStart}
}

// sameQuestionBinding reports whether two records are the same bind. The
// incarnation is part of the identity, so an older bind with the same session,
// process and thread never matches a newer one. Outbox, cursor and generation
// are not part of it.
func sameQuestionBinding(a, b questionThreadBinding) bool {
	return a.Incarnation == b.Incarnation && a.PaneID == b.PaneID && a.SessionID == b.SessionID &&
		a.ProcessID == b.ProcessID && a.ProcessStart == b.ProcessStart && a.ThreadID == b.ThreadID && a.Realm == b.Realm
}

// withQuestionState runs fn under the question-state lock. fn must stay local.
// It must not call chitta, discovery, or the native adapter, and must not take
// the lock again.
func (deps questionThreadDeps) withQuestionState(fn func() error) error {
	unlock, err := deps.lock()
	if err != nil {
		return err
	}
	defer unlock()
	return fn()
}

// loadQuestionState reads one pane's stored record under the lock.
func (deps questionThreadDeps) loadQuestionState(pane string) (questionThreadBinding, bool, error) {
	var binding questionThreadBinding
	var found bool
	err := deps.withQuestionState(func() error {
		var err error
		binding, found, err = deps.store.load(pane)
		return err
	})
	return binding, found, err
}

// saveQuestionState writes one record under the lock.
func (deps questionThreadDeps) saveQuestionState(binding questionThreadBinding) error {
	return deps.withQuestionState(func() error { return deps.store.save(binding) })
}

// questionCall runs one chitta ledger call with its own deadline.
func questionCall(ctx context.Context, deps questionThreadDeps, operation string, args any) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, questionCallTimeout)
	defer cancel()
	return deps.ledger(ctx, operation, args)
}

// loadQuestionBinding returns the stored record for pane, or an error when there is none.
func loadQuestionBinding(deps questionThreadDeps, pane string) (questionThreadBinding, error) {
	binding, found, err := deps.loadQuestionState(pane)
	if err != nil {
		return questionThreadBinding{}, err
	}
	if !found {
		return questionThreadBinding{}, errors.New("no question thread binding for this pane")
	}
	return binding, nil
}

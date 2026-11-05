package daemon

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Notices are recorded by the poller and delivered only when the Relay app
// asks for them. The app runs the draft check. relayd checks the live verified
// binding, writes each state change before it returns or sends, and never
// sends a notice that is not queued.

const (
	questionAckDelivered      = "delivered"
	questionAckHeldDraft      = "held_draft"
	questionAckDropped        = "dropped"
	questionAckOutcomeUnknown = "outcome_unknown"
	questionAckLimit          = 64
)

type questionNoticeAck struct {
	MessageID string    `json:"message_id"`
	Outcome   string    `json:"outcome"`
	Status    string    `json:"status,omitempty"`
	Reason    string    `json:"reason,omitempty"`
	At        time.Time `json:"at"`
}

type questionPendingNotice struct {
	PaneID    string `json:"pane_id"`
	ThreadID  string `json:"thread_id"`
	Revision  uint64 `json:"revision"`
	MessageID string `json:"message_id"`
	Text      string `json:"text"`
}

// questionBindingLive reports whether the pane's verified binding still matches
// the session and process the thread was bound to. An error means unknown.
func questionBindingLive(deps questionThreadDeps, binding questionThreadBinding) (bool, error) {
	current, err := deps.binding(binding.PaneID)
	if err != nil {
		return false, err
	}
	return current.SessionID == binding.SessionID && current.Producer.ProcessID == binding.ProcessID &&
		current.Producer.ProcessStart == binding.ProcessStart, nil
}

func questionOutboxIndex(binding questionThreadBinding, messageID string) int {
	for index, entry := range binding.Outbox {
		if entry.MessageID == messageID {
			return index
		}
	}
	return -1
}

// recordQuestionAck keeps one ack per message, newest last, and drops the oldest past the limit.
func recordQuestionAck(binding *questionThreadBinding, ack questionNoticeAck) {
	for index := range binding.Acks {
		if binding.Acks[index].MessageID == ack.MessageID {
			binding.Acks[index] = ack
			return
		}
	}
	binding.Acks = append(binding.Acks, ack)
	if len(binding.Acks) > questionAckLimit {
		binding.Acks = binding.Acks[len(binding.Acks)-questionAckLimit:]
	}
}

// dropQuestionNotices removes queued notices that can no longer go to this
// binding. Each drop is acked with its reason. Sent or unknown entries are never dropped.
func dropQuestionNotices(binding questionThreadBinding, reason string, now time.Time) questionThreadBinding {
	kept := binding.Outbox[:0]
	for _, entry := range binding.Outbox {
		if entry.State != questionOutboxQueued {
			kept = append(kept, entry)
			continue
		}
		recordQuestionAck(&binding, questionNoticeAck{MessageID: entry.MessageID, Outcome: questionAckDropped, Reason: reason, At: now})
	}
	binding.Outbox = kept
	return binding
}

// communicationQuestionNotices is the app's pull request.
func communicationQuestionNotices(r CommunicationRequest) (map[string]any, error) {
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return nil, err
	}
	return pullQuestionNotices(deps, r.Panes)
}

// pullQuestionNotices returns queued notices for the listed panes. The live
// binding check runs with no lock held. A pane whose binding no longer matches
// has its queued notices dropped. Reserved and releasing records are skipped.
// "bound" lists the panes with any binding record, including one being bound
// or released, so a client can stop pulling a host with none.
func pullQuestionNotices(deps questionThreadDeps, panes []string) (map[string]any, error) {
	notices := []questionPendingNotice{}
	bound := []string{}
	for _, raw := range panes {
		pane := strings.ToLower(raw)
		if !validSessionID.MatchString(pane) {
			return nil, errors.New("invalid pane")
		}
		snapshot, found, err := deps.loadQuestionState(pane)
		if err != nil || found {
			// An unreadable record is reported as bound: unknown is not idle.
			bound = append(bound, pane)
		}
		if err != nil || !found || snapshot.Phase == questionThreadPhaseReserved || snapshot.ReleaseStage != "" {
			continue
		}
		live, err := questionBindingLive(deps, snapshot)
		if err != nil {
			// Unknown is not a mismatch: nothing is delivered and nothing is dropped.
			continue
		}
		if !live {
			if err := dropBindingNotices(deps, snapshot); err != nil {
				return nil, err
			}
			continue
		}
		for _, entry := range snapshot.Outbox {
			if entry.State == questionOutboxQueued {
				notices = append(notices, questionPendingNotice{PaneID: pane, ThreadID: snapshot.ThreadID,
					Revision: entry.Revision, MessageID: entry.MessageID, Text: entry.Text})
			}
		}
	}
	return map[string]any{"notices": notices, "bound": bound, "authority": "relayd", "desktop_required": false}, nil
}

// dropBindingNotices drops the queued notices of a binding that no longer
// matches its pane. The drop is written only if the stored record is still that binding.
func dropBindingNotices(deps questionThreadDeps, snapshot questionThreadBinding) error {
	return deps.withQuestionState(func() error {
		latest, found, err := deps.store.load(snapshot.PaneID)
		if err != nil || !found || !sameQuestionBinding(latest, snapshot) {
			return err
		}
		return deps.store.save(dropQuestionNotices(latest, "binding_changed", deps.now()))
	})
}

// communicationQuestionNoticeSend is the app's request to deliver one notice.
func communicationQuestionNoticeSend(r CommunicationRequest) (map[string]any, error) {
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return nil, err
	}
	return sendQuestionNotice(deps, strings.ToLower(r.PaneID), strings.ToLower(r.MessageID))
}

// sendQuestionNotice delivers one queued notice, by message ID only. The text
// comes from the recorded outbox, never from the caller. The entry is claimed
// under the lock, the native write runs with no lock held, and the outcome is
// recorded under the lock.
func sendQuestionNotice(deps questionThreadDeps, pane, messageID string) (map[string]any, error) {
	if !validSessionID.MatchString(pane) || !validHostNativeUUID(messageID) {
		return nil, errors.New("valid pane and notice identity required")
	}
	snapshot, found, err := deps.loadQuestionState(pane)
	if err != nil || !found {
		return nil, errors.New("no question thread binding for this pane")
	}
	if snapshot.Phase == questionThreadPhaseReserved || snapshot.ReleaseStage != "" {
		return nil, errors.New("binding is not active; notice held")
	}
	if snapshot.LeasePending {
		return nil, errors.New(questionLeaseUnconfirmedReason + ": binding lease is not confirmed; notice held")
	}
	index := questionOutboxIndex(snapshot, messageID)
	if index < 0 {
		return nil, errors.New("unknown notice")
	}
	if state := snapshot.Outbox[index].State; state != questionOutboxQueued {
		return nil, fmt.Errorf("notice is %s; it is not replayed", state)
	}
	live, err := questionBindingLive(deps, snapshot)
	if err != nil {
		return nil, errors.New("verified agent binding unavailable; notice held")
	}
	if !live {
		if err := dropBindingNotices(deps, snapshot); err != nil {
			return nil, err
		}
		return map[string]any{"outcome": questionAckDropped, "reason": "binding_changed", "authority": "relayd"}, nil
	}
	text := snapshot.Outbox[index].Text
	err = deps.withQuestionState(func() error {
		latest, found, err := deps.store.load(pane)
		if err != nil {
			return err
		}
		if !found || !sameQuestionBinding(latest, snapshot) || latest.Phase == questionThreadPhaseReserved || latest.ReleaseStage != "" {
			return errors.New("binding changed before send; notice held")
		}
		claimed := questionOutboxIndex(latest, messageID)
		if claimed < 0 || latest.Outbox[claimed].State != questionOutboxQueued {
			return errors.New("notice is not queued")
		}
		latest.Outbox[claimed].State = questionOutboxSending
		return deps.store.save(latest)
	})
	if err != nil {
		return nil, err
	}
	sendCtx, cancel := context.WithTimeout(context.Background(), questionSendTimeout)
	defer cancel()
	status, notSent, sendErr := deps.send(sendCtx, pane, messageID, text, snapshot.recipient())
	return recordQuestionSendOutcome(deps, pane, messageID, status, notSent, sendErr)
}

// recordQuestionSendOutcome applies one native result to the stored entry.
// Success removes it, a definite no-write failure returns it to queued, and
// anything ambiguous becomes outcome_unknown, which is never replayed.
func recordQuestionSendOutcome(deps questionThreadDeps, pane, messageID, status string, notSent bool, sendErr error) (map[string]any, error) {
	now := deps.now()
	err := deps.withQuestionState(func() error {
		latest, found, err := deps.store.load(pane)
		if err != nil || !found {
			return err
		}
		index := questionOutboxIndex(latest, messageID)
		if index < 0 {
			return nil
		}
		switch {
		case sendErr == nil:
			latest.Outbox = append(latest.Outbox[:index], latest.Outbox[index+1:]...)
			recordQuestionAck(&latest, questionNoticeAck{MessageID: messageID, Outcome: questionAckDelivered, Status: status, At: now})
		case notSent:
			latest.Outbox[index].State = questionOutboxQueued
		default:
			latest.Outbox[index].State = questionOutboxOutcomeUnknown
			recordQuestionAck(&latest, questionNoticeAck{MessageID: messageID, Outcome: questionAckOutcomeUnknown,
				Reason: sendErr.Error(), At: now})
		}
		return deps.store.save(latest)
	})
	if err != nil {
		return nil, err
	}
	switch {
	case sendErr == nil:
		return map[string]any{"outcome": questionAckDelivered, "status": status, "authority": "relayd"}, nil
	case notSent:
		return map[string]any{"outcome": "not_sent", "reason": sendErr.Error(), "authority": "relayd"}, nil
	}
	return map[string]any{"outcome": questionAckOutcomeUnknown, "status": status, "authority": "relayd"}, nil
}

// communicationQuestionNoticeAck is the app's ack. Only held_draft is accepted
// here. delivered and outcome_unknown are recorded by the send itself.
func communicationQuestionNoticeAck(r CommunicationRequest) (map[string]any, error) {
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return nil, err
	}
	if r.Outcome != questionAckHeldDraft {
		return nil, errors.New("only a held_draft ack is accepted here; delivered and outcome_unknown come from the send")
	}
	return ackQuestionNoticeHeld(deps, strings.ToLower(r.PaneID), strings.ToLower(r.MessageID))
}

// ackQuestionNoticeHeld keeps the notice queued for the next pull.
func ackQuestionNoticeHeld(deps questionThreadDeps, pane, messageID string) (map[string]any, error) {
	if !validSessionID.MatchString(pane) || !validHostNativeUUID(messageID) {
		return nil, errors.New("valid pane and notice identity required")
	}
	snapshot, found, err := deps.loadQuestionState(pane)
	if err != nil || !found {
		return nil, errors.New("no question thread binding for this pane")
	}
	if snapshot.Phase == questionThreadPhaseReserved || snapshot.ReleaseStage != "" {
		return nil, errors.New("binding is not active; notice held")
	}
	index := questionOutboxIndex(snapshot, messageID)
	if index < 0 || snapshot.Outbox[index].State != questionOutboxQueued {
		return nil, errors.New("notice is not queued")
	}
	live, err := questionBindingLive(deps, snapshot)
	if err != nil {
		return nil, errors.New("verified agent binding unavailable")
	}
	if !live {
		if err := dropBindingNotices(deps, snapshot); err != nil {
			return nil, err
		}
		return map[string]any{"outcome": questionAckDropped, "reason": "binding_changed", "authority": "relayd"}, nil
	}
	err = deps.withQuestionState(func() error {
		latest, found, err := deps.store.load(pane)
		if err != nil {
			return err
		}
		if !found || !sameQuestionBinding(latest, snapshot) {
			return errors.New("binding changed; notice not held")
		}
		recordQuestionAck(&latest, questionNoticeAck{MessageID: messageID, Outcome: questionAckHeldDraft, At: deps.now()})
		return deps.store.save(latest)
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"outcome": questionAckHeldDraft, "authority": "relayd"}, nil
}

package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// questionThreadDepsFromEnv is the production wiring for bind, release, the
// poller and the app's notice requests. Notices go through the native system path.
func questionThreadDepsFromEnv() (questionThreadDeps, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return questionThreadDeps{}, err
	}
	deps := defaultQuestionThreadDeps(home, os.Getenv)
	deps.send = deliverQuestionNotice
	return deps, nil
}

var questionTTLDigits = regexp.MustCompile(`^[0-9]{2,6}$`)

// communicationQuestionOperation handles question_bind and question_unbind from
// the communication helper. The caller may bind only its own pane. Mutations
// already require a registered caller credential and a matching actor.
func communicationQuestionOperation(r CommunicationRequest) (map[string]any, error) {
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	return questionOperation(ctx, deps, r)
}

// questionOperation applies the own-pane gate and the bind or unbind. The
// source pane must equal the target pane, which is how a caller's identity
// reaches the binding.
func questionOperation(ctx context.Context, deps questionThreadDeps, r CommunicationRequest) (map[string]any, error) {
	pane := strings.ToLower(r.PaneID)
	if !validSessionID.MatchString(pane) || !strings.EqualFold(r.SourcePaneID, pane) {
		return nil, errors.New("a question thread binds only the caller's own pane")
	}
	switch r.Operation {
	case "question_bind":
		ttl := 0
		if r.TTL != "" {
			if !questionTTLDigits.MatchString(r.TTL) {
				return nil, errors.New("question thread ttl must be an integer number of seconds")
			}
			parsed, err := strconv.Atoi(r.TTL)
			if err != nil {
				return nil, errors.New("question thread ttl must be an integer number of seconds")
			}
			ttl = parsed
		}
		binding, err := bindQuestionThread(ctx, deps, pane, r.ThreadID, r.Realm, ttl)
		if err != nil {
			return nil, err
		}
		// A held bind is not reported as bound until its lease is confirmed. Its
		// inert state and the reason are reported, because the hold can last until an
		// operator reconciles an unresolved lease mutation.
		status := "bound"
		result := map[string]any{"pane_id": pane, "thread_id": binding.ThreadID,
			"realm": binding.Realm, "generation": binding.Generation, "ttl_seconds": binding.TTLSeconds,
			"lease_confirmed": !binding.LeasePending, "authority": "relayd", "desktop_required": false}
		if binding.LeasePending {
			status = "pending_lease"
			result["reason"] = questionLeaseUnconfirmedReason
			result["message"] = "the lease is not confirmed: an earlier lease mutation on this thread has no known outcome, so notices, polling and the classifier opt-in stay off until it is reconciled"
		}
		result["status"] = status
		return result, nil
	case "question_unbind":
		found, err := unbindQuestionThread(ctx, deps, pane)
		if err != nil {
			return nil, err
		}
		status := "not_bound"
		if found {
			status = "unbound"
		}
		return map[string]any{"status": status, "pane_id": pane, "authority": "relayd", "desktop_required": false}, nil
	}
	return nil, errors.New("unknown question thread operation")
}

// RunQuestionThreadPoller renews and polls every bound thread until ctx ends.
// Each binding is renewed and polled no more often than its own interval.
func RunQuestionThreadPoller(ctx context.Context) {
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return
	}
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			tickQuestionThreads(ctx, deps)
		}
	}
}

// tickQuestionThreads runs one pass over the stored bindings. Each pane's
// external calls run with no lock held, so a slow chitta call delays only that
// pane's step and never the host's ordinary communication.
func tickQuestionThreads(ctx context.Context, deps questionThreadDeps) {
	settleQuestionOrphans(ctx, deps)
	panes, err := deps.store.panes()
	if err != nil {
		return
	}
	for _, pane := range panes {
		if ctx.Err() != nil {
			return
		}
		tickQuestionPane(ctx, deps, pane)
	}
}

func tickQuestionPane(ctx context.Context, deps questionThreadDeps, pane string) {
	binding, found, err := deps.loadQuestionState(pane)
	if err != nil || !found {
		return
	}
	if binding.Phase == questionThreadPhaseReserved {
		// A reservation whose bind never finished is cleared. Any lease that bind
		// claimed expires by its TTL.
		if deps.now().Sub(binding.ReservedAt) > questionReserveTimeout {
			_ = deps.withQuestionState(func() error {
				latest, found, err := deps.store.load(pane)
				if err != nil || !found || latest.Phase != questionThreadPhaseReserved {
					return err
				}
				return deps.store.remove(pane)
			})
		}
		return
	}
	if binding.ReleaseStage != "" {
		// A failed release is finished as cleanup only. Nothing else runs for it.
		_ = releaseQuestionThread(ctx, deps, pane)
		return
	}
	_, _ = renewQuestionThread(ctx, deps, binding)
	_, _ = pollQuestionThread(ctx, deps, binding)
}

// Seams for the final recipient check and the native write. Tests replace them.
var (
	questionDiscover        = communicationObserve
	questionVerifiedBinding = ReadVerifiedAgentBinding
	questionNativeSend      = communicationNative
)

// deliverQuestionNotice performs the single native write for one queued notice.
// It persists a delivery claim first, so the same message ID is never submitted
// twice. The pane must still match the admitted recipient at final discovery
// and in the verified binding, or nothing is written. status is the native
// admission status. notSent is true only when nothing was written.
func deliverQuestionNotice(ctx context.Context, pane, messageID, text string, admitted questionRecipient) (string, bool, error) {
	if err := ctx.Err(); err != nil {
		return "", true, err
	}
	root := communicationRoot()
	// The claim is taken first. An existing claim or receipt means an earlier
	// attempt may have reached the pane, so nothing is written again.
	receiptPath := filepath.Join(root, "message-"+strings.ToLower(messageID)+".json")
	claim, err := os.OpenFile(receiptPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if errors.Is(err, os.ErrExist) {
		return "", false, errors.New("notice already has a delivery record; not replayed")
	}
	if err != nil {
		return "", true, err
	}
	claim.Close()
	// Nothing was written yet, so the claim is undone and the notice can be held.
	refuse := func(err error) (string, bool, error) {
		os.Remove(receiptPath)
		return "", true, err
	}
	// The claim gates the single native write, so it must be durable before the
	// write. A claim that cannot be made durable is undone, nothing is written.
	if err := durableCreated(receiptPath); err != nil {
		return refuse(err)
	}
	target := questionDiscover(pane)
	if target.Endpoint == nil || target.Unavailable != "" {
		return refuse(communicationUnverifiedEndpoint("pane has no verified native communication endpoint", communicationMember{}, target))
	}
	if target.SessionID != admitted.SessionID || target.PID != admitted.ProcessID {
		return refuse(errors.New("pane recipient does not match the admitted binding; notice held"))
	}
	verified, err := questionVerifiedBinding(pane)
	if err != nil || verified.SessionID != admitted.SessionID || verified.Producer.ProcessID != admitted.ProcessID ||
		verified.Producer.ProcessStart != admitted.ProcessStart {
		return refuse(errors.New("pane binding no longer matches the admitted recipient; notice held"))
	}
	nodeID, _ := currentNodeIdentity()
	digest := sha256.Sum256([]byte(pane + "\n" + messageID + "\n" + text))
	receipt := communicationReceipt{Version: 1, Fingerprint: hex.EncodeToString(digest[:]), CreatedAt: time.Now().UTC(),
		Result: map[string]any{"message_id": messageID, "pane_id": pane, "status": "outcome_unknown",
			"replay_permitted": false, "source_authentication": questionNoticeAuthentication,
			"authority": "relayd", "desktop_required": false}}
	if err := communicationAtomic(receiptPath, receipt); err != nil {
		return refuse(err)
	}
	// The native adapter receives the endpoint that matched the admitted recipient.
	packet := map[string]any{"operation": "send", "expected": target.Endpoint, "messageID": messageID,
		"targetPaneID": pane, "text": text, "submittingClientID": "relayd-question-thread",
		"source": map[string]any{"authentication": questionNoticeAuthentication, "principal": "relayd", "hostID": nodeID}}
	result, sendErr := questionNativeSend(pane, packet)
	for key, value := range communicationNativeOutcome(result, sendErr) {
		receipt.Result[key] = value
	}
	if err := recordQuestionAdmission(root, receiptPath, receipt); err != nil {
		return "", false, err
	}
	status, _ := receipt.Result["status"].(string)
	return status, false, sendErr
}

// questionNoticeAuthentication is set only by relayd. The pane-messaging path
// treats it as a system notice, never as a pane's sender identity.
const questionNoticeAuthentication = "relayd_system"

// markTurnStarted turns a Codex admission into turn_started with the turn ID
// that turn/start returned. Consumers treat it as admitted, as they did accepted_by_provider.
func markTurnStarted(result map[string]any) {
	status, _ := result["status"].(string)
	turn, _ := result["provider_turn_id"].(string)
	if status == "accepted_by_provider" && paneTurnID.MatchString(turn) {
		result["status"] = paneReceiptTurnStarted
		result["turn_id"] = turn
	}
}

// recordQuestionTurnStop completes the turn_started receipt whose turn ID matches
// a Stop hook. A Stop that matches nothing is logged and journaled. The admission
// that carries the same turn ID completes it, even when the Stop arrived before
// the admission was persisted.
func recordQuestionTurnStop(turn string) error {
	if !paneTurnID.MatchString(turn) {
		return nil
	}
	root := communicationRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	return withCommunicationRootLock(root, func() error {
		paths, err := filepath.Glob(filepath.Join(root, "message-*.json"))
		if err != nil {
			return err
		}
		matched := 0
		for _, path := range paths {
			var receipt communicationReceipt
			if communicationRead(path, &receipt) != nil {
				continue
			}
			if receipt.Result["status"] == paneReceiptTurnStarted && receipt.Result["turn_id"] == turn {
				receipt.Result["status"] = paneReceiptTurnCompleted
				if err := communicationAtomic(path, receipt); err != nil {
					return err
				}
				matched++
			}
		}
		if matched > 0 {
			return nil
		}
		if err := writeTurnStopJournal(root, turn); err != nil {
			return err
		}
		return appendQuestionLog(root, fmt.Sprintf("stop turn_id %s matched no turn_started receipt; journaled at %s", turn, time.Now().UTC().Format(time.RFC3339)))
	})
}

func appendQuestionLog(root, line string) error {
	file, err := OpenPrivateFile(filepath.Join(root, "turn-mismatch.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.WriteString(line + "\n")
	return err
}

// lockCommunicationRootForQuestions takes the question-state lock. The lock is a
// file in the communication root, separate from the communication lock. It is
// held only for short local reads and writes of question records. The name is
// kept for existing callers and tests.
func lockCommunicationRootForQuestions() (func(), error) {
	root := communicationRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	// The communication lock file is created here, with the same layout the
	// communication path uses. It is not locked here.
	communicationLock, err := OpenPrivateFile(filepath.Join(root, "lock"), os.O_CREATE|os.O_RDWR)
	if err != nil {
		return nil, err
	}
	communicationLock.Close()
	lock, err := OpenPrivateFile(filepath.Join(root, "question-state.lock"), os.O_CREATE|os.O_RDWR)
	if err != nil {
		return nil, err
	}
	if err := lockCommunicationRoot(lock); err != nil {
		lock.Close()
		return nil, err
	}
	return func() {
		unlockCommunicationRoot(lock)
		lock.Close()
	}, nil
}

func lockCommunicationRoot(lock *os.File) error {
	return communicationLockExclusive(lock)
}

func unlockCommunicationRoot(lock *os.File) {
	communicationUnlock(lock)
}

// communicationQuestionRequest serves the app's question operations. The
// communication lock covers only the caller check. The question operations run
// with no communication lock held, so chitta or native calls cannot stall
// ordinary pane communication.
func communicationQuestionRequest(root string, r CommunicationRequest) (map[string]any, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	if err := privateBindingObject(root, true); err != nil {
		return nil, err
	}
	lock, err := OpenPrivateFile(filepath.Join(root, "lock"), os.O_CREATE|os.O_RDWR)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if err := lockCommunicationRoot(lock); err != nil {
		return nil, err
	}
	_, err = communicationAuthorize(root, r)
	unlockCommunicationRoot(lock)
	if err != nil {
		return nil, err
	}
	switch r.Operation {
	case "question_bind", "question_unbind":
		return communicationQuestionOperation(r)
	case "question_notices":
		return communicationQuestionNotices(r)
	case "question_notice_send":
		return communicationQuestionNoticeSend(r)
	case "question_notice_ack":
		return communicationQuestionNoticeAck(r)
	}
	return nil, errors.New("unknown question thread operation")
}

// questionStopJournalTTL bounds how long an unmatched Stop waits for its admission.
const questionStopJournalTTL = 10 * time.Minute

// withCommunicationRootLock runs fn under the communication lock. It is for
// short local receipt work only. No external call runs inside it.
func withCommunicationRootLock(root string, fn func() error) error {
	lock, err := OpenPrivateFile(filepath.Join(root, "lock"), os.O_CREATE|os.O_RDWR)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := lockCommunicationRoot(lock); err != nil {
		return err
	}
	defer unlockCommunicationRoot(lock)
	return fn()
}

func turnStopJournalPath(root, turn string) string {
	return filepath.Join(root, "turn-stop-"+turn+".json")
}

// writeTurnStopJournal records a Stop that matched no admitted receipt yet, and
// removes journal entries older than questionStopJournalTTL. Called under the
// communication lock.
func writeTurnStopJournal(root, turn string) error {
	now := time.Now().UTC()
	if err := communicationAtomic(turnStopJournalPath(root, turn), map[string]any{"turn_id": turn, "at": now.Format(time.RFC3339)}); err != nil {
		return err
	}
	paths, err := filepath.Glob(filepath.Join(root, "turn-stop-*.json"))
	if err != nil {
		return err
	}
	for _, path := range paths {
		info, err := os.Stat(path)
		if err == nil && now.Sub(info.ModTime()) > questionStopJournalTTL {
			os.Remove(path)
		}
	}
	return nil
}

// recordQuestionAdmission persists a native admission. A Stop for the same turn
// that was journaled first completes the turn in the same locked step, so the
// turn always reaches turn_completed.
func recordQuestionAdmission(root, path string, receipt communicationReceipt) error {
	return withCommunicationRootLock(root, func() error {
		markTurnStarted(receipt.Result)
		if err := communicationAtomic(path, receipt); err != nil {
			return err
		}
		turn, _ := receipt.Result["turn_id"].(string)
		if receipt.Result["status"] != paneReceiptTurnStarted || turn == "" {
			return nil
		}
		journal := turnStopJournalPath(root, turn)
		if _, err := os.Stat(journal); err != nil {
			return nil
		}
		receipt.Result["status"] = paneReceiptTurnCompleted
		if err := communicationAtomic(path, receipt); err != nil {
			return err
		}
		return os.Remove(journal)
	})
}

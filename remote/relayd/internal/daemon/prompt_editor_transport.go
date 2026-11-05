package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"os"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

type promptEditorRequest struct {
	Operation string             `json:"operation"`
	ID        string             `json:"id"`
	Owner     PromptOwnerBinding `json:"owner"`
	Digest    string             `json:"digest,omitempty"`
	Text      []byte             `json:"text,omitempty"`
}

type promptEditorResponse struct {
	Owner       *PromptOwnerBinding `json:"owner,omitempty"`
	State       string              `json:"state"`
	ID          string              `json:"id,omitempty"`
	Digest      string              `json:"digest,omitempty"`
	Text        []byte              `json:"text,omitempty"`
	Apply       bool                `json:"apply,omitempty"`
	Unsupported bool                `json:"unsupported,omitempty"`
	Message     string              `json:"message,omitempty"`
}

type promptEditorPending struct {
	id          string
	transaction *promptEditorTransaction
	timer       *time.Timer
}

func validPromptEditorID(id string) bool {
	if len(id) != 32 {
		return false
	}
	decoded, err := hex.DecodeString(id)
	return err == nil && len(decoded) == 16 && strings.ToLower(id) == id
}

// promptEditOpen reports whether the pane's last prompt edit is still in
// progress (see promptEditorTransaction.inProgress).
func (session *Session) promptEditOpen(now time.Time) bool {
	session.promptEditorMu.Lock()
	pending := session.promptEditor
	session.promptEditorMu.Unlock()
	return pending != nil && pending.transaction.inProgress(now)
}

func (session *Session) promptEditorControlIsCurrent(clientID string) bool {
	session.mu.Lock()
	defer session.mu.Unlock()
	return clientID != "" && clientID == session.controlClientID && session.controlConnections > 0
}

func promptEditorCallerBelongs(pid int, owner PromptOwnerBinding) bool {
	start, err := processStartIdentity(pid)
	if err != nil {
		return false
	}
	ancestors, err := networkAncestors(pid, start)
	if err != nil {
		return false
	}
	providerSeen := false
	for _, ancestor := range ancestors {
		if ancestor == owner.ProcessID {
			providerSeen = true
		}
	}
	actual, err := processStartTime(owner.ProcessID)
	return providerSeen && err == nil && actual == owner.ProcessStart
}

// This branch does not acquire a terminal input lease. Controller operations
// must already hold the pane's live lease; editor capture must be a kernel-
// verified descendant of the bound provider. Neither route creates a worker.
func servePromptEditorRequest(connection net.Conn, writer *protocol.Writer,
	hello protocol.HelloPayload, session *Session, readOwner func() (PromptOwnerBinding, error), validateBridge func(PromptOwnerBinding) error) {
	reply := func(response promptEditorResponse) {
		frame, err := protocol.JSONFrame(protocol.Status, response)
		if err == nil {
			_ = writer.Write(frame)
		}
	}
	uid, pid, err := PeerCredentials(connection)
	if err != nil || uid != os.Getuid() {
		reply(promptEditorResponse{State: "refused"})
		return
	}
	var request promptEditorRequest
	if len(hello.PromptEditor) > 2*promptEditorDraftLimit || json.Unmarshal(hello.PromptEditor, &request) != nil {
		reply(promptEditorResponse{State: "refused"})
		return
	}
	editorOperation := request.Operation == "capture" || request.Operation == "editor-status" || request.Operation == "editor-applied" || request.Operation == "editor-failed"
	if !editorOperation && (!validPromptEditorID(request.ID) || !session.promptEditorControlIsCurrent(hello.ClientID)) {
		reply(promptEditorResponse{State: "refused"})
		return
	}
	session.promptEditorMu.Lock()
	pending := session.promptEditor
	if request.Operation == "arm" {
		if pending != nil {
			pending.transaction.mu.Lock()
			state := pending.transaction.state
			pending.transaction.mu.Unlock()
			if pending.id == request.ID {
				pending.transaction.mu.Lock()
				current := pending.transaction.owner == request.Owner && pending.transaction.ownerMatchesLocked()
				state = pending.transaction.state
				pending.transaction.mu.Unlock()
				session.promptEditorMu.Unlock()
				if !current {
					reply(promptEditorResponse{State: "refused"})
					return
				}
				reply(promptEditorResponse{State: state, ID: pending.id})
				return
			}
			if state != "cancelled" && state != "delivered" {
				session.promptEditorMu.Unlock()
				reply(promptEditorResponse{State: "busy"})
				return
			}
			pending.timer.Stop()
		}
		readLeasedOwner := func() (PromptOwnerBinding, error) {
			if !session.promptEditorControlIsCurrent(hello.ClientID) {
				return PromptOwnerBinding{}, errors.New("prompt input lease changed")
			}
			owner, err := readOwner()
			if err == nil && !session.promptEditorControlIsCurrent(hello.ClientID) {
				err = errors.New("prompt input lease changed")
			}
			return owner, err
		}
		transaction, err := newPromptEditorTransaction(request.Owner, readLeasedOwner)
		if err != nil {
			session.promptEditorMu.Unlock()
			reply(promptEditorResponse{State: "refused", Message: err.Error()})
			return
		}
		var bridgeError error
		if validateBridge == nil {
			bridgeError = errors.New("prompt editor capability verification unavailable")
		} else {
			bridgeError = validateBridge(request.Owner)
		}
		if bridgeError != nil {
			unsupported := errors.Is(bridgeError, errPromptEditorUnsupported) && transaction.ownerMatchesLocked()
			session.promptEditorMu.Unlock()
			if unsupported {
				reply(promptEditorResponse{State: "unavailable", ID: request.ID,
					Owner: &request.Owner, Unsupported: true, Message: bridgeError.Error()})
			} else {
				reply(promptEditorResponse{State: "refused", Message: "provider has no verified prompt editor bridge"})
			}
			return
		}
		pending = &promptEditorPending{id: request.ID, transaction: transaction}
		pending.timer = time.AfterFunc(20*time.Second, transaction.cancel)
		session.promptEditor = pending
		session.promptEditorMu.Unlock()
		reply(promptEditorResponse{State: "armed", ID: pending.id})
		return
	}
	session.promptEditorMu.Unlock()
	if pending == nil {
		reply(promptEditorResponse{State: "unarmed"})
		return
	}
	if request.Operation != "editor-status" && request.ID != pending.id {
		reply(promptEditorResponse{State: "refused"})
		return
	}
	if !editorOperation && request.Owner != pending.transaction.owner {
		reply(promptEditorResponse{State: "refused", ID: pending.id})
		return
	}
	if request.Operation == "editor-status" {
		// Terminal status carries no owner or draft. It cannot intercept a
		// later manual editor after the previous provider identity changes.
		pending.transaction.mu.Lock()
		finished := pending.transaction.state == "delivered" &&
			(!pending.transaction.result.Apply || pending.transaction.appliedState != "")
		pending.transaction.mu.Unlock()
		if finished {
			reply(promptEditorResponse{State: "unarmed"})
			return
		}
	}
	if editorOperation && !promptEditorCallerBelongs(pid, pending.transaction.owner) {
		reply(promptEditorResponse{State: "refused"})
		return
	}
	switch request.Operation {
	case "editor-applied", "editor-failed":
		var digest [sha256.Size]byte
		if request.Operation == "editor-applied" {
			decoded, err := hex.DecodeString(request.Digest)
			if err != nil || len(decoded) != len(digest) {
				reply(promptEditorResponse{State: "refused"})
				return
			}
			copy(digest[:], decoded)
		}
		if err := pending.transaction.recordApplication(pending.transaction.owner, digest, request.Operation == "editor-applied"); err != nil {
			reply(promptEditorResponse{State: "refused", Message: err.Error()})
			return
		}
		state, _ := pending.transaction.applicationReceipt()
		reply(promptEditorResponse{State: state, ID: pending.id})
	case "receipt":
		deadline := time.NewTimer(20 * time.Second)
		defer deadline.Stop()
		select {
		case <-pending.transaction.appliedDone:
		case <-deadline.C:
			reply(promptEditorResponse{State: "unavailable", ID: pending.id})
			return
		}
		state, digest := pending.transaction.applicationReceipt()
		digestString := ""
		if state == "applied" {
			digestString = hex.EncodeToString(digest[:])
		}
		reply(promptEditorResponse{State: state, ID: pending.id, Digest: digestString})
	case "editor-status":
		pending.transaction.mu.Lock()
		valid := pending.transaction.ownerMatchesLocked()
		state := pending.transaction.state
		pending.transaction.mu.Unlock()
		if !valid {
			reply(promptEditorResponse{State: "cancelled", ID: pending.id})
			return
		}
		owner := pending.transaction.owner
		reply(promptEditorResponse{State: state, ID: pending.id, Owner: &owner})
	case "capture":
		if err := pending.transaction.capture(pending.transaction.owner, request.Text); err != nil {
			reply(promptEditorResponse{State: "refused", Message: err.Error()})
			return
		}
		// Closing the editor connection cancels its pending transaction. The
		// editor sends no further frame until it has received the decision.
		disconnected := make(chan struct{})
		go func() { var one [1]byte; _, _ = connection.Read(one[:]); close(disconnected) }()
		select {
		case <-pending.transaction.completion():
		case <-disconnected:
			pending.transaction.cancel()
		}
		result, err := pending.transaction.completedResult()
		pending.timer.Stop()
		if err != nil {
			reply(promptEditorResponse{State: "cancelled", ID: pending.id})
			return
		}
		state := "cancelled"
		if result.Apply {
			state = "committed"
		}
		reply(promptEditorResponse{State: state, ID: pending.id, Apply: result.Apply, Text: result.Text})
	case "snapshot":
		select {
		case <-pending.transaction.captured:
		case <-pending.transaction.completion():
		}
		draft, digest, err := pending.transaction.snapshot()
		if err != nil {
			reply(promptEditorResponse{State: "unavailable", ID: pending.id})
			return
		}
		reply(promptEditorResponse{State: "captured", ID: pending.id, Text: draft, Digest: hex.EncodeToString(digest[:])})
	case "commit":
		var digest [sha256.Size]byte
		decoded, err := hex.DecodeString(request.Digest)
		if err == nil && len(decoded) == len(digest) {
			copy(digest[:], decoded)
		} else {
			err = errors.New("invalid draft digest")
		}
		if err == nil {
			err = pending.transaction.commit(digest, request.Text)
		}
		if err != nil {
			reply(promptEditorResponse{State: "refused", ID: pending.id, Message: err.Error()})
			return
		}
		reply(promptEditorResponse{State: "committed", ID: pending.id})
	case "cancel":
		pending.transaction.cancel()
		pending.timer.Stop()
		pending.transaction.mu.Lock()
		state := pending.transaction.state
		// Delivery can race the cancel response. Preserve the readonly
		// decision while keeping delivered mutations distinguishable.
		if state == "delivered" && !pending.transaction.result.Apply {
			state = "cancelled"
		}
		pending.transaction.mu.Unlock()
		reply(promptEditorResponse{State: state, ID: pending.id})
	default:
		reply(promptEditorResponse{State: "refused"})
	}
}

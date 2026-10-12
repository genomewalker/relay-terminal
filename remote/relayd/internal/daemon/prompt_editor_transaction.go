package daemon

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"sync"
	"unicode/utf8"
)

const promptEditorDraftLimit = 1 << 20

// A provider editor owns its file for the duration of this transaction. A
// cancelled result tells that editor to leave the file untouched. The bridge
// never reconstructs logical input from a renderer row or a paste placeholder.
type promptEditorResult struct {
	Apply bool
	Text  []byte
}

type promptEditorTransaction struct {
	mu            sync.Mutex
	owner         PromptOwnerBinding
	readOwner     func() (PromptOwnerBinding, error)
	state         string
	draft         []byte
	digest        [32]byte
	result        promptEditorResult
	done          chan struct{}
	captured      chan struct{}
	appliedDone   chan struct{}
	appliedState  string
	appliedDigest [32]byte
}

func newPromptEditorTransaction(expected PromptOwnerBinding,
	readOwner func() (PromptOwnerBinding, error)) (*promptEditorTransaction, error) {
	if readOwner == nil || expected.Version != 1 || expected.PaneID == "" ||
		expected.NodeBootID == "" || expected.WorkerPID <= 1 || expected.WorkerStart == 0 ||
		expected.ShellPID <= 1 || expected.ShellStart == 0 || expected.ProcessID <= 1 ||
		expected.ProcessStart == 0 || expected.Provider != "claude" || expected.SessionID == "" ||
		expected.TranscriptIdentity == "" {
		return nil, errors.New("prompt editor owner unavailable")
	}
	observed, err := readOwner()
	if err != nil || observed != expected {
		return nil, errors.New("prompt editor owner changed")
	}
	return &promptEditorTransaction{owner: expected, readOwner: readOwner,
		state: "armed", done: make(chan struct{}), captured: make(chan struct{}), appliedDone: make(chan struct{})}, nil
}

func validPromptEditorText(text []byte) bool {
	return len(text) <= promptEditorDraftLimit && utf8.Valid(text) && !bytes.ContainsRune(text, 0)
}

func (transaction *promptEditorTransaction) ownerMatchesLocked() bool {
	observed, err := transaction.readOwner()
	if err == nil && observed == transaction.owner {
		return true
	}
	transaction.cancelLocked()
	return false
}

// The editor transport must separately prove that its caller descends from
// this exact provider incarnation. Matching a pane ID from environment alone
// does not authorize capture. Passing that verified owner is mandatory here.
func (transaction *promptEditorTransaction) capture(caller PromptOwnerBinding, text []byte) error {
	transaction.mu.Lock()
	defer transaction.mu.Unlock()
	if transaction.state != "armed" || caller != transaction.owner {
		return errors.New("prompt editor capture refused")
	}
	if !validPromptEditorText(text) {
		return errors.New("prompt editor draft is invalid or too large")
	}
	if !transaction.ownerMatchesLocked() {
		return errors.New("prompt editor owner changed")
	}
	transaction.draft = bytes.Clone(text)
	transaction.digest = sha256.Sum256(text)
	transaction.state = "captured"
	close(transaction.captured)
	return nil
}

func (transaction *promptEditorTransaction) snapshot() ([]byte, [32]byte, error) {
	transaction.mu.Lock()
	defer transaction.mu.Unlock()
	if transaction.state != "captured" || !transaction.ownerMatchesLocked() {
		return nil, [32]byte{}, errors.New("prompt editor draft unavailable")
	}
	return bytes.Clone(transaction.draft), transaction.digest, nil
}

// The captured digest binds edits to the actual draft read by the provider's
// editor, including spaces, hard line breaks and expanded pasted text.
func (transaction *promptEditorTransaction) commit(expected [32]byte, text []byte) error {
	transaction.mu.Lock()
	defer transaction.mu.Unlock()
	if transaction.state != "captured" || expected != transaction.digest {
		return errors.New("prompt editor draft changed")
	}
	if !validPromptEditorText(text) {
		return errors.New("prompt editor replacement is invalid or too large")
	}
	if !transaction.ownerMatchesLocked() {
		return errors.New("prompt editor owner changed")
	}
	transaction.result = promptEditorResult{Apply: true, Text: bytes.Clone(text)}
	transaction.state = "committed"
	close(transaction.done)
	return nil
}

func (transaction *promptEditorTransaction) cancelLocked() {
	if transaction.state == "cancelled" || transaction.state == "delivered" {
		return
	}
	completed := transaction.state == "committed"
	transaction.state = "cancelled"
	transaction.result = promptEditorResult{}
	if transaction.appliedState == "" {
		transaction.appliedState = "cancelled"
		close(transaction.appliedDone)
	}
	if !completed {
		close(transaction.done)
	}
}

func (transaction *promptEditorTransaction) cancel() {
	transaction.mu.Lock()
	defer transaction.mu.Unlock()
	transaction.cancelLocked()
}

// Await the completion channel outside the transaction lock. No polling or
// editor-file mutation is needed while waiting for an explicit decision.
func (transaction *promptEditorTransaction) completion() <-chan struct{} { return transaction.done }

func (transaction *promptEditorTransaction) completedResult() (promptEditorResult, error) {
	transaction.mu.Lock()
	defer transaction.mu.Unlock()
	if transaction.state != "committed" && transaction.state != "cancelled" {
		return promptEditorResult{}, errors.New("prompt editor decision pending")
	}
	if transaction.state == "committed" && !transaction.ownerMatchesLocked() {
		return promptEditorResult{}, errors.New("prompt editor owner changed before delivery")
	}
	result := promptEditorResult{Apply: transaction.result.Apply, Text: bytes.Clone(transaction.result.Text)}
	transaction.state = "delivered"
	return result, nil
}

func (transaction *promptEditorTransaction) recordApplication(caller PromptOwnerBinding, digest [32]byte, success bool) error {
	transaction.mu.Lock()
	defer transaction.mu.Unlock()
	if transaction.state != "delivered" || !transaction.result.Apply || caller != transaction.owner || transaction.appliedState != "" {
		return errors.New("prompt editor application receipt refused")
	}
	if !success {
		transaction.appliedState = "failed"
		close(transaction.appliedDone)
		return nil
	}
	if digest != sha256.Sum256(transaction.result.Text) {
		return errors.New("prompt editor application digest changed")
	}
	if !transaction.ownerMatchesLocked() {
		transaction.appliedState = "failed"
		close(transaction.appliedDone)
		return errors.New("prompt editor owner changed before application receipt")
	}
	transaction.appliedDigest = digest
	transaction.appliedState = "applied"
	close(transaction.appliedDone)
	return nil
}

func (transaction *promptEditorTransaction) applicationReceipt() (string, [32]byte) {
	transaction.mu.Lock()
	defer transaction.mu.Unlock()
	if transaction.appliedState == "applied" && !transaction.ownerMatchesLocked() {
		return "unavailable", [32]byte{}
	}
	return transaction.appliedState, transaction.appliedDigest
}

package daemon

import "testing"

func TestViewportMailboxKeepsAtomicCommitAheadOfAnimationResize(t *testing.T) {
	mailbox := make(chan viewportOperation, 1)
	commit := viewportOperation{generation: 7, cols: 120, rows: 40, commit: true}
	enqueueViewportOperation(mailbox, commit)
	enqueueViewportOperation(mailbox, viewportOperation{cols: 121, rows: 40})

	if got := <-mailbox; got != commit {
		t.Fatalf("ordinary resize displaced pending commit: %#v", got)
	}
}

func TestViewportMailboxCoalescesToNewestCommit(t *testing.T) {
	mailbox := make(chan viewportOperation, 1)
	enqueueViewportOperation(mailbox, viewportOperation{cols: 90, rows: 30})
	latest := viewportOperation{generation: 9, cols: 140, rows: 50, commit: true}
	enqueueViewportOperation(mailbox, latest)

	if got := <-mailbox; got != latest {
		t.Fatalf("new commit did not replace pending resize: %#v", got)
	}
}

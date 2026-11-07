package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"
)

// A pane's reply to a Claude desktop session enters through ExecuteCommunication,
// the path relay-mcp's `relayd communication` takes. It must not take the
// communication lock and then ask for it again: flock on a second descriptor of
// the same file blocks this process on itself, and on dandy-07 every reply hung
// until relay-mcp's 60 s deadline killed relayd, while every other message on
// the host waited behind the held lock. The spy refuses a nested exclusive lock
// at once instead of blocking, so the red run fails fast rather than hanging.
func TestDesktopReplyThroughExecuteCommunicationTakesTheLockOnce(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	root := communicationRoot()
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	node := currentCommunicationNodeID()
	pane := "767dc718-6476-4d81-8f96-5875f4bd8ed7"
	session := "7194df15-5298-4ba5-bef3-193a96d90a53"
	token := "pane-reply-token"
	hash := sha256.Sum256([]byte(token))
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{Callers: []communicationCaller{{ID: "receiver", Label: "Pane", TokenHash: hex.EncodeToString(hash[:])}}}); err != nil {
		t.Fatal(err)
	}
	linkID := hex.EncodeToString(hash[:])
	now := time.Now().UTC()
	link := CommunicationRemoteLink{Version: 1, ID: linkID, NodeID: node, PeerNodeID: "eded2300c9785f87", LocalPaneID: pane, PeerPaneID: session,
		RouteID: "work-route", RouteRevision: 1, PeerCertificateSHA256: linkID,
		LocalConversation:  communicationPinnedConversation{Provider: "claude", SessionID: "e2dc1ae4-321b-4f39-b111-9264ef0af3c5"},
		PeerConversation:   communicationPinnedConversation{Provider: "claude", SessionID: session},
		AllowedPeerCallers: []string{"desktop-" + session}, PeerRevision: 1, Revision: 1, CreatedAt: now, UpdatedAt: now}
	if err := communicationAtomic(filepath.Join(root, "remote-link-"+linkID+".json"), link); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	held, nested := 0, 0
	saved := communicationFlock
	communicationFlock = func(fd int, how int) error {
		mu.Lock()
		defer mu.Unlock()
		switch how &^ syscall.LOCK_NB {
		case syscall.LOCK_EX:
			if held > 0 {
				nested++
				return syscall.EDEADLK
			}
			held++
		case syscall.LOCK_UN:
			if held > 0 {
				held--
			}
		}
		return saved(fd, how)
	}
	t.Cleanup(func() { communicationFlock = saved })

	_, _ = ExecuteCommunication(CommunicationRequest{Operation: "send", SourcePaneID: pane, ActorPaneID: pane, actorVerified: true,
		PaneID: session, MessageID: "5d1c2e8a-7f3b-4b9e-9a61-2c0e4f7d8b13", Text: "beacon-2150", ClientToken: token})
	if nested != 0 {
		t.Fatalf("desktop reply asked for the communication lock while holding it (%d nested requests)", nested)
	}
	if held != 0 {
		t.Fatalf("communication lock left held: %d", held)
	}
}

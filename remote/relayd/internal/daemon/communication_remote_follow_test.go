package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// followPane is the pane on node-b (dandy-07 in the live case) as node-b's
// kernel observation sees it: a process that can change conversation.
type followPane struct {
	session string
	pid     int
	start   string
	calls   atomic.Int32
}

func (p *followPane) hooks() communicationGroupNative {
	return communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: "claude", SessionID: p.session, PID: p.pid, Start: p.start,
			Endpoint: map[string]any{"transport": "fixture"}}
	}, send: func(string, map[string]any) (map[string]any, error) {
		p.calls.Add(1)
		return map[string]any{"status": "accepted", "acknowledgement": "provider_accepted"}, nil
	}}
}

func followFixture(t *testing.T) (scopedNodes, *followPane) {
	t.Helper()
	f, _ := hostChannelLinked(t)
	token := sha256.Sum256([]byte(replyToken))
	if err := communicationAtomic(communicationPolicyPath(f.b), communicationPolicy{Callers: []communicationCaller{{ID: "receiver", Label: "Pane", TokenHash: hex.EncodeToString(token[:])}}}); err != nil {
		t.Fatal(err)
	}
	// The established pair pins the pane's conversation as the fixture saw it.
	return f, &followPane{session: "target-conversation", pid: 4242, start: "linux:100"}
}

// paneSends queues a pane-to-desktop message on node-b and returns the result.
func paneSends(t *testing.T, f scopedNodes, pane *followPane, id string) (map[string]any, error) {
	t.Helper()
	reply := CommunicationRequest{Operation: "send", SourcePaneID: testGroupB, PaneID: desktopAlias, MessageID: id,
		Text: "from the pane", ClientToken: replyToken, ActorPaneID: testGroupB, actorVerified: true}
	got, linked, err := communicationSendToDesktop(f.b, "node-b", reply, pane.hooks())
	if !linked {
		t.Fatal("the pane's pair was not selected", got, err)
	}
	return got, err
}

// carry moves every queued message from one node to the other, as the Relay
// app's carrier does, and returns the settle results.
func carry(t *testing.T, f scopedNodes, pane *followPane, fromB bool) []map[string]any {
	t.Helper()
	if fromB {
		return hostChannelCarry(t, f.b, "node-b", pane.hooks(), f.a, "node-a", f.hooksA)
	}
	return hostChannelCarry(t, f.a, "node-a", f.hooksA, f.b, "node-b", pane.hooks())
}

func desktopSends(t *testing.T, f scopedNodes, id string) {
	t.Helper()
	hostChannelSend(t, f, id)
}

func linkOn(t *testing.T, root, node string) CommunicationRemoteLink {
	t.Helper()
	paths, _ := globRemoteLinks(root)
	if len(paths) != 1 {
		t.Fatalf("%s has %d remote links", node, len(paths))
	}
	var link CommunicationRemoteLink
	if err := communicationRead(paths[0], &link); err != nil {
		t.Fatal(err)
	}
	return link
}

func settledStatus(t *testing.T, settled []map[string]any) string {
	t.Helper()
	if len(settled) != 1 {
		t.Fatalf("settled %d messages: %v", len(settled), settled)
	}
	status, _ := settled[0]["status"].(string)
	return status
}

// The live failure of 2026-11-08: the pane on dandy-07 ran /clear and the
// pair with the desktop session stopped in both directions. Now the pane's
// next message follows (its host pins the new conversation and tells the
// peer), the desktop host learns it, and the desktop's next message reaches
// the new conversation, after which nothing old is accepted as current.
func TestCrossHostPairFollowsAPaneThatClearsAndSendsFirst(t *testing.T) {
	f, pane := followFixture(t)
	if _, err := paneSends(t, f, pane, "f1f1f1f1-f1f1-4f1f-8f1f-f1f1f1f1f1f1"); err != nil {
		t.Fatal(err)
	}
	if got := settledStatus(t, carry(t, f, pane, true)); got == "" || strings.Contains(got, "not") {
		t.Fatal("the first reply was not delivered", got)
	}
	if b := linkOn(t, f.b, "node-b"); b.LocalPID != 4242 || b.LocalStart != "linux:100" {
		t.Fatal("first use did not pin the pane's process", b.LocalPID, b.LocalStart)
	}
	pane.session = "cleared-conversation"
	if _, err := paneSends(t, f, pane, "f2f2f2f2-f2f2-4f2f-8f2f-f2f2f2f2f2f2"); err != nil {
		t.Fatal("the pane's message after /clear was refused", err)
	}
	b := linkOn(t, f.b, "node-b")
	if b.LocalConversation.SessionID != "cleared-conversation" || len(b.LocalFollowedFrom) != 1 || b.LocalFollowedFrom[0].SessionID != "target-conversation" {
		t.Fatalf("node-b link %+v", b)
	}
	if got := settledStatus(t, carry(t, f, pane, true)); got == "" || strings.Contains(got, "not") {
		t.Fatal("the reply after /clear was not delivered", got)
	}
	a := linkOn(t, f.a, "node-a")
	if a.PeerConversation.SessionID != "cleared-conversation" || len(a.PeerFollowedFrom) != 1 {
		t.Fatalf("node-a did not learn the followed conversation: %+v", a)
	}
	before := pane.calls.Load()
	desktopSends(t, f, "f3f3f3f3-f3f3-4f3f-8f3f-f3f3f3f3f3f3")
	if got := settledStatus(t, carry(t, f, pane, false)); got == "" || strings.Contains(got, "not") || pane.calls.Load() != before+1 {
		t.Fatal("the desktop's message to the cleared pane was not delivered", got)
	}
	if b := linkOn(t, f.b, "node-b"); len(b.LocalFollowedFrom) != 0 {
		t.Fatal("node-b kept the old conversation after the peer named the new one", b.LocalFollowedFrom)
	}
	// Revisions never moved, so neither side waited for the other.
	if a, b := linkOn(t, f.a, "node-a"), linkOn(t, f.b, "node-b"); a.Revision != b.PeerRevision || b.Revision != a.PeerRevision {
		t.Fatal("follow changed the reviewed revisions", a.Revision, a.PeerRevision, b.Revision, b.PeerRevision)
	}
}

// The other order: the desktop writes first, still naming the pre-/clear
// conversation. The pane's host follows its own pane and delivers to the new
// conversation; the pane's reply then teaches the desktop host.
func TestCrossHostPairFollowsAPaneThatClearsAndReceivesFirst(t *testing.T) {
	f, pane := followFixture(t)
	desktopSends(t, f, "e1e1e1e1-e1e1-4e1e-8e1e-e1e1e1e1e1e1")
	if got := settledStatus(t, carry(t, f, pane, false)); got == "" || strings.Contains(got, "not") {
		t.Fatal("first message", got)
	}
	pane.session = "cleared-conversation"
	before := pane.calls.Load()
	desktopSends(t, f, "e2e2e2e2-e2e2-4e2e-8e2e-e2e2e2e2e2e2")
	if got := settledStatus(t, carry(t, f, pane, false)); got == "" || strings.Contains(got, "not") || pane.calls.Load() != before+1 {
		t.Fatal("a message to the pre-/clear conversation was not delivered to the cleared pane", got)
	}
	if b := linkOn(t, f.b, "node-b"); b.LocalConversation.SessionID != "cleared-conversation" {
		t.Fatalf("node-b did not follow its pane: %+v", b)
	}
	if _, err := paneSends(t, f, pane, "e3e3e3e3-e3e3-4e3e-8e3e-e3e3e3e3e3e3"); err != nil {
		t.Fatal(err)
	}
	carry(t, f, pane, true)
	if a := linkOn(t, f.a, "node-a"); a.PeerConversation.SessionID != "cleared-conversation" {
		t.Fatalf("node-a did not learn: %+v", a)
	}
}

// A new process in the pane is not the same partner: nothing is delivered or
// sent, and the refusal says the pair must be saved again.
func TestCrossHostPairDoesNotFollowANewProcess(t *testing.T) {
	f, pane := followFixture(t)
	if _, err := paneSends(t, f, pane, "d1d1d1d1-d1d1-4d1d-8d1d-d1d1d1d1d1d1"); err != nil {
		t.Fatal(err)
	}
	carry(t, f, pane, true)
	pane.session, pane.pid, pane.start = "other-conversation", 5151, "linux:200"
	if _, err := paneSends(t, f, pane, "d2d2d2d2-d2d2-4d2d-8d2d-d2d2d2d2d2d2"); err == nil || !strings.Contains(err.Error(), "relink needed") {
		t.Fatal("a new process was followed on send", err)
	}
	before := pane.calls.Load()
	desktopSends(t, f, "d3d3d3d3-d3d3-4d3d-8d3d-d3d3d3d3d3d3")
	claim, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "work_native_claim", MessageID: "d3d3d3d3-d3d3-4d3d-8d3d-d3d3d3d3d3d3"})
	if err != nil {
		t.Fatal(err)
	}
	_, err = hostChannelOp(f.b, "node-b", pane.hooks(), CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: claim["work_envelope"].(string)})
	if err == nil || !strings.Contains(err.Error(), "relink needed") || pane.calls.Load() != before {
		t.Fatal("a message reached a new process", err)
	}
	if b := linkOn(t, f.b, "node-b"); b.LocalConversation.SessionID != "target-conversation" || b.LocalPID != 4242 {
		t.Fatalf("a refused follow changed the pin: %+v", b)
	}
}

// A message the pane sent before /clear and the carrier delivers after a
// newer one is still accepted, and it does not move the pin back.
func TestCrossHostPairAcceptsALateMessageFromBeforeTheClear(t *testing.T) {
	f, pane := followFixture(t)
	if _, err := paneSends(t, f, pane, "c1c1c1c1-c1c1-4c1c-8c1c-c1c1c1c1c1c1"); err != nil {
		t.Fatal(err)
	}
	pane.session = "cleared-conversation"
	if _, err := paneSends(t, f, pane, "c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2"); err != nil {
		t.Fatal(err)
	}
	deliver := func(id string) map[string]any {
		claim, err := hostChannelOp(f.b, "node-b", pane.hooks(), CommunicationRequest{Operation: "work_native_claim", MessageID: id})
		if err != nil {
			t.Fatal("claim", id, err)
		}
		delivered, err := hostChannelOp(f.a, "node-a", f.hooksA, CommunicationRequest{Operation: "deliver_signed_work", WorkEnvelope: claim["work_envelope"].(string)})
		if err != nil {
			t.Fatal("deliver", id, err)
		}
		settled, err := hostChannelOp(f.b, "node-b", pane.hooks(), CommunicationRequest{Operation: "work_native_settle", MessageID: id, WorkReply: delivered["work_reply"].(string)})
		if err != nil {
			t.Fatal("settle", id, err)
		}
		return settled
	}
	if got := deliver("c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2"); strings.Contains(got["status"].(string), "not") {
		t.Fatal("newer", got)
	}
	if got := deliver("c1c1c1c1-c1c1-4c1c-8c1c-c1c1c1c1c1c1"); strings.Contains(got["status"].(string), "not") {
		t.Fatal("the late message from before /clear was refused", got)
	}
	if a := linkOn(t, f.a, "node-a"); a.PeerConversation.SessionID != "cleared-conversation" {
		t.Fatal("a late message moved the pin back", a.PeerConversation)
	}
}

// The receiver moves the pin only from the conversation it already has, and
// the followed-from list is inside the message fingerprint.
func TestFollowedFromIsBoundAndOnlyFromThePinnedConversation(t *testing.T) {
	pin := func(s string) communicationPinnedConversation {
		return communicationPinnedConversation{Provider: "claude", SessionID: s}
	}
	link := CommunicationRemoteLink{PeerConversation: pin("pinned")}
	message := communicationRemoteMessage{SourceConversation: pin("new"), SourceFollowedFrom: []communicationPinnedConversation{pin("pinned")}}
	if !remoteAcceptsSource(link, message) {
		t.Fatal("a follow from the pinned conversation was refused")
	}
	message.SourceFollowedFrom = []communicationPinnedConversation{pin("someone-else")}
	if remoteAcceptsSource(link, message) {
		t.Fatal("a follow from another conversation was accepted")
	}
	message.SourceFollowedFrom = nil
	if remoteAcceptsSource(link, message) {
		t.Fatal("a changed conversation without a follow was accepted")
	}
	codex := message
	codex.SourceConversation = communicationPinnedConversation{Provider: "codex", SessionID: "new"}
	codex.SourceFollowedFrom = []communicationPinnedConversation{pin("pinned")}
	if remoteAcceptsSource(link, codex) {
		t.Fatal("a follow across providers was accepted")
	}
	a := communicationRemoteMessage{SourceConversation: pin("new"), SourceFollowedFrom: []communicationPinnedConversation{pin("pinned")}}
	b := a
	b.SourceFollowedFrom = []communicationPinnedConversation{pin("other")}
	if remoteMessageFingerprint(a) == remoteMessageFingerprint(b) {
		t.Fatal("the followed-from list is not covered by the fingerprint")
	}
	if validFollowedFrom(make([]communicationPinnedConversation, remoteFollowLimit+1), pin("x")) {
		t.Fatal("an unbounded followed-from list is valid")
	}
}

func globRemoteLinks(root string) ([]string, error) {
	return filepath.Glob(filepath.Join(root, "remote-link-*.json"))
}

// A link saved before process pins were kept (the live dandy-07 link) follows
// a /clear only when one of the host's saved pane pairs recorded the old
// conversation in exactly the live process. A record of an earlier process
// that once resumed the same conversation is not evidence.
func TestLegacyLinkFollowsOnlyWithARecordOfTheLiveProcess(t *testing.T) {
	root := t.TempDir()
	pane := "767dc718-6476-4d81-8f96-5875f4bd8ed7"
	old := communicationPinnedConversation{Provider: "claude", SessionID: "e2dc1ae4-321b-4f39-b111-9264ef0af3c5"}
	link := CommunicationRemoteLink{ID: "x", LocalPaneID: pane, LocalConversation: old}
	live := communicationMember{PaneID: pane, Provider: "claude", SessionID: "ea871a3f-879c-4e1f-9539-2f99a25b2c0a", PID: 3968237, Start: "linux:40852365",
		Endpoint: map[string]any{"transport": "fixture"}}
	record := func(name string, pid int, start string) {
		pair := communicationLink{Version: 1, ID: name, Members: []communicationMember{{PaneID: pane, Provider: "claude", SessionID: old.SessionID, PID: pid, Start: start}}}
		if err := communicationAtomic(filepath.Join(root, "link-"+name+".json"), pair); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := remoteLinkFollowLocal(root, link, live); err == nil || !strings.Contains(err.Error(), "relink needed") {
		t.Fatal("a legacy link followed without evidence", err)
	}
	record("earlier", 2648214, "linux:6368696")
	if _, _, err := remoteLinkFollowLocal(root, link, live); err == nil {
		t.Fatal("a record of an earlier process was taken as evidence")
	}
	record("live", 3968237, "linux:40852365")
	followed, moved, err := remoteLinkFollowLocal(root, link, live)
	if err != nil || !moved || followed.LocalConversation.SessionID != live.SessionID || followed.LocalPID != 3968237 ||
		len(followed.LocalFollowedFrom) != 1 || followed.LocalFollowedFrom[0] != old {
		t.Fatalf("legacy link with a record of the live process: %+v moved=%v err=%v", followed, moved, err)
	}
}

// A remote link records the pane root on use and follows an agent restarted
// under it; a different root is refused.
func TestRemoteLinkFollowsARestartUnderItsPaneRoot(t *testing.T) {
	root := t.TempDir()
	account := map[int]string{10: "/h/.claude-team", 11: "/h/.claude-team", 12: "/h/.claude-personal"}
	previous := communicationAgentAccount
	communicationAgentAccount = func(pid int, _ string) string { return account[pid] }
	t.Cleanup(func() { communicationAgentAccount = previous })
	pin := communicationPinnedConversation{Provider: "claude", SessionID: "old-session"}
	link := CommunicationRemoteLink{ID: "x", LocalPaneID: "p", LocalConversation: pin}
	live := func(session string, pid int, rootPID int) communicationMember {
		return communicationMember{PaneID: "p", Provider: "claude", SessionID: session, PID: pid, Start: "linux:" + session,
			Endpoint: map[string]any{"transport": "fixture", "rootPID": float64(rootPID), "rootStart": "linux:1"}}
	}
	link, moved, err := remoteLinkFollowLocal(root, link, live("old-session", 10, 7))
	if err != nil || !moved || link.LocalRootPID != 7 || link.LocalRootStart != "linux:1" || link.LocalAccount != "/h/.claude-team" {
		t.Fatalf("first use did not record the pane root: %+v err=%v", link, err)
	}
	if _, _, err := remoteLinkFollowLocal(root, link, live("new-session", 11, 8)); err == nil {
		t.Fatal("a restart under another pane root was followed")
	}
	if _, _, err := remoteLinkFollowLocal(root, link, live("new-session", 12, 7)); err == nil {
		t.Fatal("a restart under another account was followed")
	}
	link, moved, err = remoteLinkFollowLocal(root, link, live("new-session", 11, 7))
	if err != nil || !moved || link.LocalConversation.SessionID != "new-session" || link.LocalPID != 11 || len(link.LocalFollowedFrom) != 1 {
		t.Fatalf("restart under the same root: %+v err=%v", link, err)
	}
}

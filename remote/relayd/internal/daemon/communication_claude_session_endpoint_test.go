package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

// desktopAlias is the Claude desktop session's ID, used as its endpoint ID.
const desktopAlias = "7194df15-5298-4ba5-bef3-193a96d90a53"

type claudeSessionCalls struct {
	session atomic.Int32
	pane    atomic.Int32
	notice  atomic.Int32
	targets []nativemsg.Target
	packets []map[string]any
}

// claudeSessionEnv isolates the communication root and the pane worker
// state, and replaces both native adapters. live=false makes the session
// adapter report the session as unavailable.
func claudeSessionEnv(t *testing.T, live *atomic.Bool) (string, string, *claudeSessionCalls) {
	t.Helper()
	state, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_STATE_HOME", state)
	root := communicationRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	account := filepath.Join(state, "claude-account")
	calls := &claudeSessionCalls{}
	savedSession := communicationClaudeSessionRun
	communicationClaudeSessionRun = func(_ context.Context, _ nativemsg.Host, target nativemsg.Target, request []byte) map[string]any {
		calls.session.Add(1)
		calls.targets = append(calls.targets, target)
		var packet map[string]any
		_ = json.Unmarshal(request, &packet)
		calls.packets = append(calls.packets, packet)
		if !live.Load() || target.Claude == nil {
			return map[string]any{"status": "unavailable", "error": "No unique live Claude desktop session publishes this session"}
		}
		if packet["operation"] == "discover" {
			return map[string]any{"endpoint": map[string]any{"provider": "claude", "sessionID": target.Claude.SessionID,
				"transport": "native_peer_socket", "socketPath": "/tmp/cc-socks/56065.sock", "pid": 56065}}
		}
		return map[string]any{"status": "written_to_socket", "acknowledgement": "not_implied", "transport": "native_peer_socket"}
	}
	t.Cleanup(func() { communicationClaudeSessionRun = savedSession })
	useNativeRun(t, func(context.Context, nativemsg.Host, string, []byte) map[string]any {
		calls.pane.Add(1)
		return map[string]any{"status": "accepted_by_provider"}
	})
	savedNotice := PeerDeliveryNotice
	PeerDeliveryNotice = func(string, []byte) error { calls.notice.Add(1); return nil }
	t.Cleanup(func() { PeerDeliveryNotice = savedNotice })
	return root, account, calls
}

func registerDesktop(t *testing.T, root, account string) communicationClaudeSessionEndpoint {
	t.Helper()
	got, err := communicationClaudeSessionOperation(root, CommunicationRequest{Operation: "route_claude_session_set",
		TargetSessionID: strings.ToUpper(desktopAlias), ClaudeAccountRoot: account}, time.Now)
	if err != nil || got["status"] != "registered" {
		t.Fatal("register", got, err)
	}
	return got["claude_session"].(communicationClaudeSessionEndpoint)
}

func TestClaudeSessionEndpointRegistrationIsOwnerOnlyAndLive(t *testing.T) {
	live := &atomic.Bool{}
	live.Store(true)
	root, account, calls := claudeSessionEnv(t, live)
	set := func(r CommunicationRequest) (map[string]any, error) {
		r.Operation = "route_claude_session_set"
		return communicationClaudeSessionOperation(root, r, time.Now)
	}
	base := CommunicationRequest{TargetSessionID: desktopAlias, ClaudeAccountRoot: account}
	for name, r := range map[string]CommunicationRequest{
		"provider credential": {TargetSessionID: desktopAlias, ClaudeAccountRoot: account, ClientToken: "token"},
		"caller pane":         {TargetSessionID: desktopAlias, ClaudeAccountRoot: account, ActorPaneID: testGroupA},
		"invalid session":     {TargetSessionID: "claude-desktop-sapropels-handoff-81d26f", ClaudeAccountRoot: account},
		"relative account":    {TargetSessionID: desktopAlias, ClaudeAccountRoot: "claude-account"},
		"root account":        {TargetSessionID: desktopAlias, ClaudeAccountRoot: "/"},
	} {
		if _, err := set(r); err == nil {
			t.Fatalf("%s: registered", name)
		}
	}
	// The owner gate also holds through the route dispatcher.
	if _, err := communicationRouteOperation(root, "node-a", CommunicationRequest{Operation: "route_claude_session_set",
		TargetSessionID: desktopAlias, ClaudeAccountRoot: account, ClientToken: "token"}); err == nil {
		t.Fatal("provider credential registered through the route dispatcher")
	}
	if _, err := communicationAuthorize(root, CommunicationRequest{Operation: "route_claude_session_set", ActorPaneID: testGroupA}); err == nil {
		t.Fatal("caller pane authorized for owner administration")
	}
	live.Store(false)
	if _, err := set(base); err == nil || !strings.Contains(err.Error(), "not live") {
		t.Fatal("dead session registered", err)
	}
	if _, err := os.Stat(claudeSessionEndpointPath(root, desktopAlias)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("refused registration wrote a record", err)
	}
	live.Store(true)
	// A pane already using the ID wins; the session is not registered.
	stateDir := NewServer().stateDir
	os.MkdirAll(stateDir, 0o700)
	os.WriteFile(filepath.Join(stateDir, desktopAlias+".json"), []byte("{}"), 0o600)
	if _, err := set(base); err == nil || !strings.Contains(err.Error(), "pane already uses") {
		t.Fatal("pane ID registered as a Claude session", err)
	}
	os.Remove(filepath.Join(stateDir, desktopAlias+".json"))
	e := registerDesktop(t, root, account)
	if e.ID != desktopAlias || e.SessionID != desktopAlias || e.AccountRoot != account {
		t.Fatalf("%+v", e)
	}
	if got, err := set(base); err != nil || got["status"] != "unchanged" {
		t.Fatal("re-registration", got, err)
	}
	if _, err := set(CommunicationRequest{TargetSessionID: desktopAlias, ClaudeAccountRoot: account + "-other"}); err == nil {
		t.Fatal("registration moved to another account directory")
	}
	if got, err := communicationClaudeSessionOperation(root, CommunicationRequest{Operation: "route_claude_session_list"}, time.Now); err != nil ||
		len(got["claude_sessions"].([]communicationClaudeSessionEndpoint)) != 1 {
		t.Fatal("list", got, err)
	}
	if calls.pane.Load() != 0 {
		t.Fatal("registration touched a pane adapter")
	}
}

func TestClaudeSessionEndpointDispatchesToTheSessionOnly(t *testing.T) {
	live := &atomic.Bool{}
	live.Store(true)
	root, account, calls := claudeSessionEnv(t, live)
	registerDesktop(t, root, account)
	calls.session.Store(0)
	member := communicationObserve(desktopAlias)
	if member.Unavailable != "" || member.Provider != "claude" || member.SessionID != desktopAlias || member.Endpoint == nil {
		t.Fatalf("observe %+v", member)
	}
	got, err := communicationNative(desktopAlias, map[string]any{"operation": "send", "text": "hello", "messageID": testGroupID})
	if err != nil || got["status"] != "written_to_socket" {
		t.Fatal(got, err)
	}
	last := calls.targets[len(calls.targets)-1]
	if calls.session.Load() != 2 || calls.pane.Load() != 0 || calls.notice.Load() != 0 ||
		last.Kind != "claude_session" || last.Claude.AccountRoot != account || last.Claude.SessionID != desktopAlias {
		t.Fatalf("session=%d pane=%d notice=%d target=%+v", calls.session.Load(), calls.pane.Load(), calls.notice.Load(), last)
	}
	// Another ID stays a pane.
	if _, err := communicationNative(testGroupA, map[string]any{"operation": "send", "text": "hi", "messageID": testGroupID}); err != nil || calls.pane.Load() != 1 || calls.session.Load() != 2 || calls.notice.Load() != 1 {
		t.Fatal("unregistered ID did not stay a pane", err)
	}
	// A pane that later appears under the same ID makes it ambiguous: refused.
	stateDir := NewServer().stateDir
	os.MkdirAll(stateDir, 0o700)
	os.WriteFile(filepath.Join(stateDir, desktopAlias+".json"), []byte("{}"), 0o600)
	if _, err := communicationNative(desktopAlias, map[string]any{"operation": "send", "text": "x"}); err == nil || calls.session.Load() != 2 || calls.pane.Load() != 1 {
		t.Fatal("ambiguous ID delivered", err)
	}
	os.Remove(filepath.Join(stateDir, desktopAlias+".json"))
	// A dead session is unavailable, never a pane.
	live.Store(false)
	if member := communicationObserve(desktopAlias); member.Unavailable == "" || member.Endpoint != nil || calls.pane.Load() != 1 {
		t.Fatalf("dead session observed %+v", member)
	}
	live.Store(true)
	// A record whose session differs from its ID is invalid, not followed.
	var e communicationClaudeSessionEndpoint
	communicationRead(claudeSessionEndpointPath(root, desktopAlias), &e)
	e.SessionID = testGroupB
	communicationAtomic(claudeSessionEndpointPath(root, desktopAlias), e)
	before := calls.session.Load()
	if _, err := communicationNative(desktopAlias, map[string]any{"operation": "send", "text": "x"}); err == nil || calls.session.Load() != before || calls.pane.Load() != 1 {
		t.Fatal("swapped record followed", err)
	}
	// Retired: the ID is a pane ID again.
	e.SessionID = desktopAlias
	communicationAtomic(claudeSessionEndpointPath(root, desktopAlias), e)
	if _, err := communicationClaudeSessionOperation(root, CommunicationRequest{Operation: "route_claude_session_retire", TargetSessionID: desktopAlias}, time.Now); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationNative(desktopAlias, map[string]any{"operation": "send", "text": "x"}); err != nil || calls.pane.Load() != 2 || calls.session.Load() != before {
		t.Fatal("retired session still dispatched", err)
	}
}

func TestClaudeSessionActorNeedsARegistrationAndYieldsToPanes(t *testing.T) {
	live := &atomic.Bool{}
	live.Store(true)
	root, account, _ := claudeSessionEnv(t, live)
	paneErr := errors.New("no unique live pane owns this client")
	pane := func(owned bool) func(int) (CommunicationActor, error) {
		return func(pid int) (CommunicationActor, error) {
			if owned {
				return CommunicationActor{Version: 1, PaneID: testGroupA, ClientPID: pid, Source: "foreground_worker_kernel_ancestry"}, nil
			}
			return CommunicationActor{}, paneErr
		}
	}
	session := func(root string) func(int) (ClaudeSessionActor, error) {
		return func(pid int) (ClaudeSessionActor, error) {
			return ClaudeSessionActor{Version: 1, SessionID: desktopAlias, AccountRoot: root, PID: 56065, ClientPID: pid, ClientStart: "s", Source: claudeDesktopSessionSource}, nil
		}
	}
	noSession := func(int) (ClaudeSessionActor, error) {
		return ClaudeSessionActor{}, errors.New("no Claude desktop session owns this client")
	}
	if _, err := readCommunicationActorOrClaudeSession(root, 56149, pane(false), session(account)); err != paneErr {
		t.Fatal("unregistered desktop session became an actor", err)
	}
	registerDesktop(t, root, account)
	actor, err := readCommunicationActorOrClaudeSession(root, 56149, pane(false), session(account))
	if err != nil || actor.PaneID != desktopAlias || actor.Source != claudeDesktopSessionSource || actor.ClientPID != 56149 {
		t.Fatal(actor, err)
	}
	if actor, err := readCommunicationActorOrClaudeSession(root, 56149, pane(true), session(account)); err != nil || actor.PaneID != testGroupA {
		t.Fatal("pane owner did not take precedence", actor, err)
	}
	if _, err := readCommunicationActorOrClaudeSession(root, 56149, pane(false), session(account+"-other")); err != paneErr {
		t.Fatal("session of another account directory became the actor", err)
	}
	if _, err := readCommunicationActorOrClaudeSession(root, 54851, pane(false), noSession); err != paneErr {
		t.Fatal("client without a Claude session became an actor", err)
	}
	// The registered ID is the only sender this client may name.
	for _, source := range []string{"767dc718-6476-4d81-8f96-5875f4bd8ed7", testGroupB} {
		r := CommunicationRequest{Operation: "send", ActorPaneID: desktopAlias, SourcePaneID: source, ClientToken: "t"}
		if _, err := communicationAuthorize(root, r); err == nil || !strings.Contains(err.Error(), "own pane") {
			t.Fatal("desktop session sent as", source, err)
		}
		if communicationSourceVerified(CommunicationRequest{ActorPaneID: desktopAlias, SourcePaneID: source, actorVerified: true}) {
			t.Fatal("claimed source verified", source)
		}
	}
	if !communicationSourceVerified(CommunicationRequest{ActorPaneID: desktopAlias, SourcePaneID: strings.ToUpper(desktopAlias), actorVerified: true}) {
		t.Fatal("own session ID not verified")
	}
	if _, err := communicationAuthorize(root, CommunicationRequest{Operation: "send", ActorPaneID: desktopAlias, SourcePaneID: desktopAlias}); err == nil {
		t.Fatal("desktop session sent without a registered credential")
	}
	// Retiring the endpoint removes the actor.
	communicationClaudeSessionOperation(root, CommunicationRequest{Operation: "route_claude_session_retire", TargetSessionID: desktopAlias}, time.Now)
	if _, err := readCommunicationActorOrClaudeSession(root, 56149, pane(false), session(account)); err != paneErr {
		t.Fatal("retired endpoint still an actor", err)
	}
}

// The desktop session pairs with a pane on another host (4fbb on dandy) over
// the existing remote-link path, in both directions, with production
// observe/send hooks on the session's host.
func TestClaudeSessionEndpointRemoteLinkBothDirections(t *testing.T) {
	live := &atomic.Bool{}
	live.Store(true)
	_, account, calls := claudeSessionEnv(t, live)
	registerDesktop(t, communicationRoot(), account)
	a, b, r, _, paneCalls := remoteSendFixture(t, false)
	desktopHooks := communicationGroupNative{observe: communicationObserve, send: communicationNative}
	// Re-pin node-a's side to the desktop session: local endpoint = its ID.
	peer := communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"}
	link, err := readRemoteLink(a, "node-a", r.LinkID)
	if err != nil {
		t.Fatal(err)
	}
	desktopLink := CommunicationRemoteLink{PeerNodeID: "node-b", LocalPaneID: desktopAlias, PeerPaneID: testGroupB, RouteID: link.RouteID, RouteRevision: link.RouteRevision,
		PeerCertificateSHA256: link.PeerCertificateSHA256, LocalConversation: communicationPinnedConversation{Provider: "claude", SessionID: desktopAlias},
		PeerConversation: peer, PeerRevision: 1, AllowedPeerCallers: []string{"receiver"}}
	result, err := communicationRemoteLinkSet(a, "node-a", CommunicationRequest{Operation: "route_link_set", RemoteLink: &desktopLink}, desktopHooks)
	if err != nil {
		t.Fatal("link the desktop session to the remote pane", err)
	}
	desktopLink = result["link"].(CommunicationRemoteLink)
	// A pin to another session is refused at link time.
	wrong := desktopLink
	wrong.ID, wrong.Revision, wrong.LocalPaneID = "", 0, desktopAlias
	wrong.LocalConversation = communicationPinnedConversation{Provider: "claude", SessionID: testGroupA}
	if _, err := communicationRemoteLinkSet(a, "node-a", CommunicationRequest{Operation: "route_link_set", RemoteLink: &wrong}, desktopHooks); err == nil {
		t.Fatal("desktop session linked under another session's pin")
	}
	// The peer host (node-b) pins the reciprocal pair: its pane and the
	// desktop session, by session ID.
	peerA, _ := filepath.Glob(filepath.Join(b, "remote-link-*.json"))
	var existingB CommunicationRemoteLink
	if len(peerA) != 1 || communicationRead(peerA[0], &existingB) != nil {
		t.Fatal("peer fixture link", peerA)
	}
	bhooks := communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: peer.Provider, SessionID: peer.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}}
	reciprocal := CommunicationRemoteLink{PeerNodeID: "node-a", LocalPaneID: testGroupB, PeerPaneID: desktopAlias, RouteID: existingB.RouteID, RouteRevision: existingB.RouteRevision,
		PeerCertificateSHA256: existingB.PeerCertificateSHA256, LocalConversation: peer, PeerConversation: desktopLink.LocalConversation,
		PeerRevision: desktopLink.Revision, AllowedPeerCallers: []string{"sender"}}
	if _, err := communicationRemoteLinkSet(b, "node-b", CommunicationRequest{Operation: "route_link_set", RemoteLink: &reciprocal}, bhooks); err != nil {
		t.Fatal("reciprocal link", err)
	}
	t.Run("desktop to remote pane", func(t *testing.T) {
		before := paneCalls.Load()
		send := CommunicationRequest{Operation: "remote_send", LinkID: desktopLink.ID, SourcePaneID: desktopAlias, PaneID: testGroupB, PeerNodeID: "node-b",
			MessageID: "44444444-4444-4444-8444-444444444444", ExpectedRemoteLinkRevision: desktopLink.Revision, Text: "DiSCo version please",
			ClientToken: remoteSenderToken, ActorPaneID: desktopAlias}
		got, err := communicationSendRemote(a, "node-a", send, desktopHooks)
		if err != nil || got["status"] != "accepted" || paneCalls.Load() != before+1 {
			t.Fatal("desktop message not delivered to the remote pane", got, err)
		}
		if _, err := communicationSendRemote(a, "node-a", send, desktopHooks); err != nil || paneCalls.Load() != before+1 {
			t.Fatal("resent", err)
		}
		// The desktop session cannot send as another pane on this link.
		impostor := send
		impostor.MessageID, impostor.SourcePaneID, impostor.ActorPaneID = "77777777-7777-4777-8777-777777777777", "767dc718-6476-4d81-8f96-5875f4bd8ed7", "767dc718-6476-4d81-8f96-5875f4bd8ed7"
		if _, err := communicationSendRemote(a, "node-a", impostor, desktopHooks); err == nil || paneCalls.Load() != before+1 {
			t.Fatal("sent under another pane on the desktop link", err)
		}
		// A dead session cannot send: its pinned conversation is unavailable.
		live.Store(false)
		dead := send
		dead.MessageID = "88888888-8888-4888-8888-888888888888"
		if _, err := communicationSendRemote(a, "node-a", dead, desktopHooks); err == nil || paneCalls.Load() != before+1 {
			t.Fatal("dead session sent", err)
		}
		live.Store(true)
	})
	t.Run("remote pane to desktop", func(t *testing.T) {
		before := calls.session.Load()
		message := communicationRemoteMessage{Version: 1, Operation: "send", LinkID: desktopLink.ID, SourceLinkRevision: desktopLink.PeerRevision, TargetLinkRevision: desktopLink.Revision,
			SourceNodeID: "node-b", TargetNodeID: "node-a", SourcePaneID: testGroupB, TargetPaneID: desktopAlias, CallerID: "receiver",
			SourceConversation: peer, TargetConversation: desktopLink.LocalConversation, MessageID: "55555555-5555-4555-8555-555555555555", Text: "DiSCo 1.0.0, command attached"}
		message.Fingerprint = remoteMessageFingerprint(message)
		got, err := communicationReceiveRemote(context.Background(), a, "node-a", desktopLink.PeerCertificateSHA256, message, desktopHooks)
		if err != nil || calls.session.Load() <= before || calls.pane.Load() != 0 {
			t.Fatal("reply not delivered to the desktop session", got, err, calls.session.Load(), calls.pane.Load())
		}
		packet := calls.packets[len(calls.packets)-1]
		if packet["operation"] != "send" || packet["text"] != message.Text || calls.targets[len(calls.targets)-1].Claude.SessionID != desktopAlias {
			t.Fatal("wrong delivery", packet)
		}
		// The same message again is answered from the receipt, not redelivered.
		after := calls.session.Load()
		if _, err := communicationReceiveRemote(context.Background(), a, "node-a", desktopLink.PeerCertificateSHA256, message, desktopHooks); err != nil || calls.session.Load() != after {
			t.Fatal("duplicate delivered", err)
		}
		// A dead session is never replaced by a pane delivery.
		live.Store(false)
		dead := message
		dead.MessageID = "66666666-6666-4666-8666-666666666666"
		dead.Fingerprint = remoteMessageFingerprint(dead)
		if got, _ := communicationReceiveRemote(context.Background(), a, "node-a", desktopLink.PeerCertificateSHA256, dead, desktopHooks); got["status"] == "accepted" || calls.pane.Load() != 0 {
			t.Fatal("dead session delivered", got)
		}
		live.Store(true)
	})
}

// Typed (Work) relationships never admit a Claude session endpoint, so the
// Work-only paths that treat a non-pane endpoint as Work cannot receive one.
func TestTypedEndpointsRejectClaudeSessionKind(t *testing.T) {
	e := communicationEndpoint{NodeID: "node-a", Kind: "claude_session", Provider: "claude", SessionID: desktopAlias}
	if e.valid() || e.logicalKey() != "" {
		t.Fatal("typed endpoint admitted a Claude session")
	}
	pane := communicationEndpoint{NodeID: "node-b", Kind: "pane", PaneID: testGroupB, Provider: "codex", SessionID: testGroupA}
	link := communicationTypedRemoteLink{Version: 2, Local: e, Peer: pane}
	if validTypedRemoteLink(link, "node-a") {
		t.Fatal("typed link admitted a Claude session")
	}
}

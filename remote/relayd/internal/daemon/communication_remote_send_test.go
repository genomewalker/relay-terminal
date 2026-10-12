package daemon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const remoteSenderToken = "isolated-fixture-sender-credential"

func remoteSendFixture(t *testing.T, dropReply bool) (string, string, CommunicationRequest, communicationGroupNative, *atomic.Int32) {
	return remoteSendFixtureWithReplyHook(t, dropReply, nil)
}

func remoteSendFixtureWithReplyHook(t *testing.T, dropReply bool, afterReceive func()) (string, string, CommunicationRequest, communicationGroupNative, *atomic.Int32) {
	t.Helper()
	a, acert := peerFixture(t, "node-a")
	b, bcert := peerFixture(t, "node-b")
	ac, err := peerCertificate(acert, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	bc, err := peerCertificate(bcert, "node-b")
	if err != nil {
		t.Fatal(err)
	}
	localA := communicationPinnedConversation{Provider: "codex", SessionID: "source-conversation"}
	localB := communicationPinnedConversation{Provider: "claude", SessionID: "target-conversation"}
	calls := &atomic.Int32{}
	bhooks := communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: localB.Provider, SessionID: localB.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}, send: func(string, map[string]any) (map[string]any, error) {
		calls.Add(1)
		return map[string]any{"status": "accepted", "acknowledgement": "provider_accepted"}, nil
	}}
	handler := peerHandler(b, "node-b", bhooks)
	if dropReply {
		base := handler
		handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			data, _ := io.ReadAll(r.Body)
			r.Body = io.NopCloser(bytes.NewReader(data))
			var message communicationRemoteMessage
			_ = json.Unmarshal(data, &message)
			if message.Operation == "send" {
				recorder := httptest.NewRecorder()
				base.ServeHTTP(recorder, r)
				if afterReceive != nil {
					afterReceive()
				}
				connection, _, err := w.(http.Hijacker).Hijack()
				if err != nil {
					t.Error(err)
					return
				}
				_ = connection.Close()
				return
			}
			base.ServeHTTP(w, r)
		})
	}
	server := httptest.NewUnstartedServer(handler)
	server.TLS, err = peerServerTLS(b, "node-b")
	if err != nil {
		t.Fatal(err)
	}
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	t.Cleanup(server.Close)
	enrollPeer(t, a, "node-a", "node-b", strings.TrimPrefix(server.URL, "https://"), bcert)
	enrollPeer(t, b, "node-b", "node-a", "127.0.0.1:1", acert)
	digest := sha256.Sum256([]byte(remoteSenderToken))
	if err := communicationAtomic(communicationPolicyPath(a), communicationPolicy{Callers: []communicationCaller{{ID: "sender", Label: "Fixture", TokenHash: hex.EncodeToString(digest[:])}}}); err != nil {
		t.Fatal(err)
	}
	blink := CommunicationRemoteLink{PeerNodeID: "node-a", LocalPaneID: testGroupB, PeerPaneID: testGroupA, RouteID: "route", RouteRevision: 1,
		PeerCertificateSHA256: peerFingerprint(ac), LocalConversation: localB, PeerConversation: localA, PeerRevision: 1, AllowedPeerCallers: []string{"sender"}}
	if _, err := communicationRemoteLinkSet(b, "node-b", CommunicationRequest{Operation: "route_link_set", RemoteLink: &blink}, bhooks); err != nil {
		t.Fatal(err)
	}
	ahooks := communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: localA.Provider, SessionID: localA.SessionID, Endpoint: map[string]any{"transport": "fixture"}}
	}}
	alink := CommunicationRemoteLink{PeerNodeID: "node-b", LocalPaneID: testGroupA, PeerPaneID: testGroupB, RouteID: "route", RouteRevision: 1,
		PeerCertificateSHA256: peerFingerprint(bc), LocalConversation: localA, PeerConversation: localB, PeerRevision: 1, AllowedPeerCallers: []string{"receiver"}}
	result, err := communicationRemoteLinkSet(a, "node-a", CommunicationRequest{Operation: "route_link_set", RemoteLink: &alink}, ahooks)
	if err != nil {
		t.Fatal(err)
	}
	alink = result["link"].(CommunicationRemoteLink)
	r := CommunicationRequest{Operation: "remote_send", LinkID: alink.ID, SourcePaneID: testGroupA, PaneID: testGroupB, PeerNodeID: "node-b",
		MessageID: testGroupID, ExpectedRemoteLinkRevision: 1, Text: "private fixture collaborator input", ClientToken: remoteSenderToken, ActorPaneID: testGroupA}
	return a, b, r, ahooks, calls
}

func TestCommunicationRemoteSendMutualTLSAndIdempotentReceipts(t *testing.T) {
	a, b, r, hooks, calls := remoteSendFixture(t, false)
	result, err := communicationSendRemote(a, "node-a", r, hooks)
	if err != nil || result["status"] != "accepted" || result["peer_authentication"] != "mutual_tls_pinned_node" || result["replay_permitted"] != false || calls.Load() != 1 {
		t.Fatal(result, err, calls.Load())
	}
	if _, err := communicationSendRemote(a, "node-a", r, hooks); err != nil || calls.Load() != 1 {
		t.Fatal("outbound duplicate replayed", err)
	}
	for _, path := range []string{remoteOutboundPath(a, r.MessageID), remoteReceiptPath(b, "node-a", r.MessageID)} {
		data, err := os.ReadFile(path)
		if err != nil || strings.Contains(string(data), r.Text) || strings.Contains(string(data), remoteSenderToken) {
			t.Fatal("text or credential persisted", err)
		}
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatal("private receipt mode", err)
		}
	}
	r.Text = "different payload"
	if _, err := communicationSendRemote(a, "node-a", r, hooks); err == nil || calls.Load() != 1 {
		t.Fatal("outbound message conflict accepted")
	}
}

func TestCommunicationRemoteLostReplyRecoversWithoutResending(t *testing.T) {
	a, _, r, hooks, calls := remoteSendFixture(t, true)
	result, err := communicationSendRemote(a, "node-a", r, hooks)
	if err != nil || result["status"] != "outcome_unknown" || result["replay_permitted"] != false || calls.Load() != 1 {
		t.Fatal("lost reply not retained as unknown", result, err)
	}
	if _, err := communicationSendRemote(a, "node-a", r, hooks); err != nil || calls.Load() != 1 {
		t.Fatal("retry re-delivered lost reply", err)
	}
	r.Operation, r.Text = "remote_receipt", ""
	result, err = communicationSendRemote(a, "node-a", r, hooks)
	if err != nil || result["status"] != "accepted" || result["peer_authentication"] != "mutual_tls_pinned_node" || calls.Load() != 1 {
		t.Fatal("durable receipt recovery failed", result, err)
	}
}

func TestCommunicationRemoteSenderScopePauseAndChangedConversation(t *testing.T) {
	for _, kind := range []string{"actor", "pause", "source_pin", "pair_revision", "peer_node", "other_caller"} {
		t.Run(kind, func(t *testing.T) {
			a, _, r, hooks, calls := remoteSendFixture(t, false)
			switch kind {
			case "actor":
				r.ActorPaneID = testGroupB
			case "pause":
				var policy communicationPolicy
				if err := communicationRead(communicationPolicyPath(a), &policy); err != nil {
					t.Fatal(err)
				}
				policy.Callers[0].Paused = true
				if err := communicationAtomic(communicationPolicyPath(a), policy); err != nil {
					t.Fatal(err)
				}
			case "source_pin":
				hooks.observe = func(pane string) communicationMember {
					return communicationMember{PaneID: pane, Provider: "codex", SessionID: "other-conversation", Endpoint: map[string]any{}}
				}
			case "pair_revision":
				r.ExpectedRemoteLinkRevision = 2
			case "peer_node":
				r.PeerNodeID = "other-peer"
			case "other_caller":
				r.ClientToken = "unregistered-credential"
			}
			if _, err := communicationSendRemote(a, "node-a", r, hooks); err == nil || calls.Load() != 0 {
				t.Fatal("unauthorized outgoing message submitted", kind)
			}
		})
	}
}

func TestCommunicationRemoteSourceClaimFailureNeverResumesDispatch(t *testing.T) {
	a, _, r, hooks, calls := remoteSendFixture(t, false)
	journal := filepath.Join(a, "events.jsonl")
	if err := os.Rename(journal, journal+".retained"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(journal, 0700); err != nil {
		t.Fatal(err)
	}
	result, err := communicationSendRemote(a, "node-a", r, hooks)
	if err == nil || result["status"] != "outcome_unknown" || calls.Load() != 0 {
		t.Fatal("dispatch occurred after claim journal failure", result, err)
	}
	if err := os.Remove(journal); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(journal+".retained", journal); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationSendRemote(a, "node-a", r, hooks); err != nil || calls.Load() != 0 {
		t.Fatal("partial source claim resumed", err)
	}
	r.Operation, r.Text = "remote_receipt", ""
	result, err = communicationSendRemote(a, "node-a", r, hooks)
	if err != nil || result["status"] != "unknown" || calls.Load() != 0 {
		t.Fatal("receipt query triggered delivery", result, err)
	}
}

func TestCommunicationRemoteMaximumEscapedJSONMessage(t *testing.T) {
	a, _, r, hooks, calls := remoteSendFixture(t, false)
	r.Text = strings.Repeat("\x00", 16384)
	result, err := communicationSendRemote(a, "node-a", r, hooks)
	if err != nil || result["status"] != "accepted" || calls.Load() != 1 {
		t.Fatal("valid maximum encoded body rejected", result, err)
	}
}

func TestCommunicationRemoteLostSendReplyCannotDowngradeRecoveredOutcome(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	releaseReply := func() { releaseOnce.Do(func() { close(release) }) }
	a, _, r, hooks, calls := remoteSendFixtureWithReplyHook(t, true, func() { close(entered); <-release })
	t.Cleanup(releaseReply)
	type reply struct {
		result map[string]any
		err    error
	}
	done := make(chan reply, 1)
	go func() { result, err := communicationSendRemote(a, "node-a", r, hooks); done <- reply{result, err} }()
	select {
	case <-entered:
	case value := <-done:
		t.Fatal("send failed before fixture acknowledgement", value.err)
	case <-time.After(10 * time.Second):
		t.Fatal("fixture acknowledgement timeout")
	}
	query := r
	query.Operation, query.Text = "remote_receipt", ""
	result, err := communicationSendRemote(a, "node-a", query, hooks)
	releaseReply()
	value := <-done
	if err != nil || result["status"] != "accepted" || value.err != nil || value.result["status"] != "accepted" || calls.Load() != 1 {
		t.Fatal("late failed send downgraded committed recovery", result, err, value.result, value.err)
	}
}

func TestCommunicationRemoteRecipientClaimFailureNeverReplaysNative(t *testing.T) {
	a, b, r, hooks, calls := remoteSendFixture(t, false)
	journal := filepath.Join(b, "events.jsonl")
	if err := os.Rename(journal, journal+".retained"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(journal, 0700); err != nil {
		t.Fatal(err)
	}
	result, err := communicationSendRemote(a, "node-a", r, hooks)
	if err != nil || result["status"] != "outcome_unknown" || calls.Load() != 0 {
		t.Fatal("native started after failed recipient claim journal", result, err)
	}
	if err := os.Remove(journal); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(journal+".retained", journal); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationSendRemote(a, "node-a", r, hooks); err != nil || calls.Load() != 0 {
		t.Fatal("sender resumed dispatch", err)
	}
	r.Operation, r.Text = "remote_receipt", ""
	result, err = communicationSendRemote(a, "node-a", r, hooks)
	if err != nil || result["status"] != "outcome_unknown" || calls.Load() != 0 {
		t.Fatal("receipt recovery replayed failed recipient claim", result, err)
	}
}

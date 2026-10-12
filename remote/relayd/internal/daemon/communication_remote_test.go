package daemon

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func remoteReceiveFixture(t *testing.T) (string, string, communicationRemoteMessage, communicationGroupNative) {
	t.Helper()
	root, _ := peerFixture(t, "node-b")
	_, acert := peerFixture(t, "node-a")
	enrollPeer(t, root, "node-b", "node-a", "127.0.0.1:1", acert)
	cert, err := peerCertificate(acert, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	certificateHash := peerFingerprint(cert)
	local := communicationPinnedConversation{Provider: "claude", SessionID: "local-conversation"}
	peer := communicationPinnedConversation{Provider: "codex", SessionID: "peer-conversation"}
	hooks := communicationGroupNative{observe: func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: local.Provider, SessionID: local.SessionID, Endpoint: map[string]any{"transport": "fixture-native"}}
	}, send: func(string, map[string]any) (map[string]any, error) {
		return map[string]any{"status": "accepted", "acknowledgement": "provider_accepted"}, nil
	}}
	link := CommunicationRemoteLink{PeerNodeID: "node-a", LocalPaneID: testGroupB, PeerPaneID: testGroupA, RouteID: "route", RouteRevision: 1,
		PeerCertificateSHA256: certificateHash, LocalConversation: local, PeerConversation: peer, PeerRevision: 1, AllowedPeerCallers: []string{"sender"}}
	result, err := communicationRemoteLinkSet(root, "node-b", CommunicationRequest{Operation: "route_link_set", RemoteLink: &link}, hooks)
	if err != nil {
		t.Fatal(err)
	}
	link = result["link"].(CommunicationRemoteLink)
	message := communicationRemoteMessage{Version: 1, Operation: "send", LinkID: link.ID, SourceLinkRevision: 1, TargetLinkRevision: 1,
		SourceNodeID: "node-a", TargetNodeID: "node-b", SourcePaneID: testGroupA, TargetPaneID: testGroupB, CallerID: "sender",
		SourceConversation: peer, TargetConversation: local, MessageID: testGroupID, Text: "fixture collaborator message"}
	message.Fingerprint = remoteMessageFingerprint(message)
	return root, certificateHash, message, hooks
}

func TestCommunicationRemoteDurableClaimAndTrustedProvenance(t *testing.T) {
	root, certificateHash, message, hooks := remoteReceiveFixture(t)
	var calls int
	hooks.send = func(pane string, packet map[string]any) (map[string]any, error) {
		calls++
		var receipt communicationRemoteReceipt
		if err := communicationRead(remoteReceiptPath(root, "node-a", message.MessageID), &receipt); err != nil || !remoteReceiptMatches(receipt, message, "node-b") {
			t.Fatal("native invoked without durable claim", err)
		}
		if packet["text"] != message.Text || pane != message.TargetPaneID {
			t.Fatal("wrong native recipient")
		}
		if err := communicationFanoutLocked(root, func() error { return nil }); err != nil {
			t.Fatal("metadata lock held across native I/O", err)
		}
		return map[string]any{"status": "accepted", "acknowledgement": "provider_accepted", "authority": "spoofed", "replay_permitted": true, "source_authentication": "verified_author"}, nil
	}
	result, err := communicationReceiveRemote(context.Background(), root, "node-b", certificateHash, message, hooks)
	if err != nil || calls != 1 || result["status"] != "accepted" || result["authority"] != "relayd" || result["replay_permitted"] != false || result["source_authentication"] != "claimed_pane_label" {
		t.Fatal(result, err, calls)
	}
	if _, err := communicationReceiveRemote(context.Background(), root, "node-b", certificateHash, message, hooks); err != nil || calls != 1 {
		t.Fatal("duplicate native delivery", err, calls)
	}
	data, err := os.ReadFile(remoteReceiptPath(root, "node-a", message.MessageID))
	if err != nil || strings.Contains(string(data), message.Text) {
		t.Fatal("message text persisted", err)
	}
	info, err := os.Stat(remoteReceiptPath(root, "node-a", message.MessageID))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("private receipt mode", err)
	}
	query := message
	query.Operation = "receipt"
	query.Text = ""
	result, err = communicationReceiveRemote(context.Background(), root, "node-b", certificateHash, query, hooks)
	if err != nil || result["status"] != "accepted" || calls != 1 {
		t.Fatal("receipt query replayed", err)
	}
}

func TestCommunicationRemoteConcurrentDuplicateAndConflict(t *testing.T) {
	root, certificateHash, message, hooks := remoteReceiveFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	hooks.send = func(string, map[string]any) (map[string]any, error) {
		calls.Add(1)
		close(entered)
		<-release
		return map[string]any{"status": "accepted"}, nil
	}
	done := make(chan error, 1)
	go func() {
		_, err := communicationReceiveRemote(context.Background(), root, "node-b", certificateHash, message, hooks)
		done <- err
	}()
	select {
	case <-entered:
	case err := <-done:
		t.Fatal("first dispatch failed before native", err)
	}
	result, err := communicationReceiveRemote(context.Background(), root, "node-b", certificateHash, message, hooks)
	close(release)
	if err != nil || result["status"] != "outcome_unknown" || calls.Load() != 1 {
		t.Fatal("concurrent duplicate not reserved", result, err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	message.Text = "changed payload"
	message.Fingerprint = remoteMessageFingerprint(message)
	if _, err := communicationReceiveRemote(context.Background(), root, "node-b", certificateHash, message, hooks); err == nil || calls.Load() != 1 {
		t.Fatal("conflicting message identity accepted")
	}
}

func TestCommunicationRemoteRejectsRouteCallerRevisionAndConversationChanges(t *testing.T) {
	for _, kind := range []string{"certificate", "caller", "source_revision", "target_revision", "source_pin", "live_target", "route_retired", "link_retired", "pause"} {
		t.Run(kind, func(t *testing.T) {
			root, certificateHash, message, hooks := remoteReceiveFixture(t)
			var calls int
			hooks.send = func(string, map[string]any) (map[string]any, error) { calls++; return nil, nil }
			switch kind {
			case "certificate":
				certificateHash = strings.Repeat("0", 64)
			case "caller":
				message.CallerID = "other-caller"
			case "source_revision":
				message.SourceLinkRevision = 2
			case "target_revision":
				message.TargetLinkRevision = 2
			case "source_pin":
				message.SourceConversation.SessionID = "changed-source"
			case "live_target":
				hooks.observe = func(pane string) communicationMember {
					return communicationMember{PaneID: pane, Provider: "claude", SessionID: "changed-target", Endpoint: map[string]any{}}
				}
			case "route_retired":
				if _, err := communicationRouteOperation(root, "node-b", CommunicationRequest{Operation: "route_retire", RouteID: "route", ExpectedRouteRevision: 1}); err != nil {
					t.Fatal(err)
				}
			case "link_retired":
				if _, err := communicationRemoteLinkOperation(root, "node-b", CommunicationRequest{Operation: "route_link_retire", LinkID: message.LinkID, ExpectedRemoteLinkRevision: 1}); err != nil {
					t.Fatal(err)
				}
			case "pause":
				if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{LegacyPaused: true}); err != nil {
					t.Fatal(err)
				}
			}
			message.Fingerprint = remoteMessageFingerprint(message)
			if _, err := communicationReceiveRemote(context.Background(), root, "node-b", certificateHash, message, hooks); err == nil || calls != 0 {
				t.Fatal("unauthorized native delivery", kind)
			}
			paths, err := filepath.Glob(filepath.Join(root, "remote-message-*.json"))
			if err != nil || len(paths) != 0 {
				t.Fatal("unauthorized request claimed", err)
			}
		})
	}
}

func TestCommunicationRemoteUnknownOutcomeAndCanceledAdmissionNeverReplay(t *testing.T) {
	root, certificateHash, message, hooks := remoteReceiveFixture(t)
	var calls int
	hooks.send = func(string, map[string]any) (map[string]any, error) {
		calls++
		return nil, errors.New("fixture lost native acknowledgement")
	}
	result, err := communicationReceiveRemote(context.Background(), root, "node-b", certificateHash, message, hooks)
	if err != nil || result["status"] != "outcome_unknown" {
		t.Fatal(result, err)
	}
	result, err = communicationReceiveRemote(context.Background(), root, "node-b", certificateHash, message, hooks)
	if err != nil || result["replay_permitted"] != false || calls != 1 {
		t.Fatal("unknown outcome resumed", result, err)
	}
	message.MessageID = "cancelled-message"
	message.Fingerprint = remoteMessageFingerprint(message)
	ctx, cancel := context.WithCancel(context.Background())
	hooks.observe = func(pane string) communicationMember {
		cancel()
		return communicationMember{PaneID: pane, Provider: "claude", SessionID: "local-conversation", Endpoint: map[string]any{}}
	}
	if _, err := communicationReceiveRemote(ctx, root, "node-b", certificateHash, message, hooks); err == nil || calls != 1 {
		t.Fatal("cancelled admission delivered")
	}
}

func TestCommunicationRemoteClaimCanFinishAfterPauseAndAuditAfterRetirement(t *testing.T) {
	root, certificateHash, message, hooks := remoteReceiveFixture(t)
	hooks.send = func(string, map[string]any) (map[string]any, error) {
		if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{LegacyPaused: true}); err != nil {
			t.Fatal(err)
		}
		return map[string]any{"status": "accepted"}, nil
	}
	result, err := communicationReceiveRemote(context.Background(), root, "node-b", certificateHash, message, hooks)
	if err != nil || result["status"] != "accepted" {
		t.Fatal("claimed native completion lost", result, err)
	}
	if _, err := communicationRemoteLinkOperation(root, "node-b", CommunicationRequest{Operation: "route_link_retire", LinkID: message.LinkID, ExpectedRemoteLinkRevision: 1}); err != nil {
		t.Fatal(err)
	}
	result, err = communicationRemoteLinkOperation(root, "node-b", CommunicationRequest{Operation: "route_link_received_receipt", PeerNodeID: "node-a", MessageID: message.MessageID})
	if err != nil || result["status"] != "accepted" {
		t.Fatal("retained owner audit unavailable", result, err)
	}
}

func TestCommunicationRemoteOwnerReviewCASAndRejectedHTTP(t *testing.T) {
	root, certificateHash, message, hooks := remoteReceiveFixture(t)
	link, err := readRemoteLink(root, "node-b", message.LinkID)
	if err != nil {
		t.Fatal(err)
	}
	r := CommunicationRequest{Operation: "route_link_set", RemoteLink: &link}
	if _, err := communicationRemoteLinkSet(root, "node-b", r, hooks); err == nil {
		t.Fatal("stale review CAS accepted")
	}
	r.ExpectedRemoteLinkRevision = 1
	r.ClientToken = "provider-token"
	if _, err := communicationRemoteLinkSet(root, "node-b", r, hooks); err == nil {
		t.Fatal("provider enrolled remote permission")
	}
	binding, cert, err := peerBinding(root, "node-b", "binding")
	if err != nil || binding.PeerNodeID != "node-a" || peerFingerprint(cert) != certificateHash {
		t.Fatal(err)
	}
	message.CallerID = "unreviewed-caller"
	message.Fingerprint = remoteMessageFingerprint(message)
	data, _ := json.Marshal(message)
	request := httptest.NewRequest(http.MethodPost, "https://relay.invalid/relay-peer/message", strings.NewReader(string(data)))
	request.TLS = &tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}}
	response := httptest.NewRecorder()
	peerHandler(root, "node-b", hooks).ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatal("unreviewed HTTP message accepted")
	}
}

func TestCommunicationRemoteReceiptPathSeparatesPeerAndMessageIdentity(t *testing.T) {
	if remoteReceiptPath("/fixture", "a-b", "c") == remoteReceiptPath("/fixture", "a", "b-c") {
		t.Fatal("ambiguous peer/message namespace")
	}
}

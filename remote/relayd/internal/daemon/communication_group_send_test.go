package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
)

const fanoutC = "44444444-4444-4444-8444-444444444444"

func fanoutFixture(t *testing.T) (string, CommunicationRequest, communicationGroupNative, *atomic.Int32) {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	token := "fanout-fixture-token"
	hash := sha256.Sum256([]byte(token))
	policy := communicationPolicy{Callers: []communicationCaller{{ID: testGroupID, Label: "fixture", TokenHash: hex.EncodeToString(hash[:])}}}
	if err := communicationAtomic(communicationPolicyPath(root), policy); err != nil {
		t.Fatal(err)
	}
	req := CommunicationRequest{Operation: "group_send", GroupID: "review-group", SourcePaneID: testGroupA,
		ActorPaneID: testGroupA, ClientToken: token, MessageID: "fanout-test", Text: "fixture body never persisted", ExpectedGroupRevision: 1}
	known := map[string]string{testGroupA: "A", testGroupB: "B", fanoutC: "C"}
	_, err := communicationGroupOperation(root, "node", CommunicationRequest{Operation: "group_set", GroupID: req.GroupID,
		GroupName: "review", ClientID: testGroupID, MemberPaneIDs: []string{testGroupA, testGroupB, fanoutC}}, known)
	if err != nil {
		t.Fatal(err)
	}
	observe := func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: "claude", SessionID: "conversation-" + pane,
			Endpoint: map[string]any{"provider": "claude", "sessionID": "conversation-" + pane, "pid": float64(1), "start": "fixture"}}
	}
	for _, target := range []string{testGroupB, fanoutC} {
		id, _, _ := communicationPair(testGroupA, target)
		link := communicationLink{Version: 1, ID: id, NodeID: "node", Transport: "relay_native_socket",
			Members: []communicationMember{observe(testGroupA), observe(target)}}
		if err := communicationAtomic(filepath.Join(root, "link-"+id+".json"), link); err != nil {
			t.Fatal(err)
		}
	}
	calls := &atomic.Int32{}
	send := func(pane string, packet map[string]any) (map[string]any, error) {
		calls.Add(1)
		id := packet["messageID"].(string)
		var parent communicationFanoutReceipt
		if err := communicationRead(communicationFanoutPath(root, req.MessageID), &parent); err != nil {
			t.Error("parent not claimed", err)
		}
		var child communicationReceipt
		if err := communicationRead(filepath.Join(root, "message-"+id+".json"), &child); err != nil ||
			child.Result["status"] != "outcome_unknown" {
			t.Error("child not claimed before native I/O", err)
		}
		f, err := OpenPrivateFile(filepath.Join(root, "lock"), os.O_RDWR)
		if err != nil {
			return nil, err
		}
		defer f.Close()
		if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			t.Error("native I/O held the metadata lock")
			return nil, err
		}
		defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		return map[string]any{"status": "accepted_by_provider", "provider_turn_id": "fixture-turn", "acknowledgement": "admitted_not_processed"}, nil
	}
	return root, req, communicationGroupNative{observe: observe, send: send}, calls
}
func fanoutReceipt(t *testing.T, result map[string]any) communicationFanoutReceipt {
	t.Helper()
	r, ok := result["receipt"].(communicationFanoutReceipt)
	if !ok {
		t.Fatal("missing fanout receipt", result)
	}
	return r
}
func TestCommunicationGroupFanoutClaimsAndNeverReplays(t *testing.T) {
	root, req, hooks, calls := fanoutFixture(t)
	result, err := communicationGroupSend(root, "node", req, hooks)
	if err != nil {
		t.Fatal(err)
	}
	receipt := fanoutReceipt(t, result)
	if !receipt.DispatchFinished || calls.Load() != 2 || len(receipt.Targets) != 2 || result["replay_permitted"] != false {
		t.Fatal(receipt, calls.Load())
	}
	if receipt.Targets[0].MessageID == receipt.Targets[1].MessageID {
		t.Fatal("shared child identity")
	}
	for _, target := range receipt.Targets {
		if target.Result["status"] != "accepted_by_provider" || target.Result["acknowledgement"] != "admitted_not_processed" || target.Result["replay_permitted"] != false {
			t.Fatal(target)
		}
	}
	if _, err := communicationGroupSend(root, "node", req, hooks); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatal("duplicate native delivery")
	}
	changed := req
	changed.Text = "different"
	if _, err := communicationGroupSend(root, "node", changed, hooks); err == nil {
		t.Fatal("message identity conflict accepted")
	}
	files, _ := filepath.Glob(filepath.Join(root, "*.json"))
	for _, file := range files {
		data, _ := os.ReadFile(file)
		if strings.Contains(string(data), req.Text) {
			t.Fatal("message text persisted")
		}
	}
}
func TestCommunicationGroupFanoutUnknownOutcomeNotReplayed(t *testing.T) {
	root, req, hooks, calls := fanoutFixture(t)
	original := hooks.send
	hooks.send = func(pane string, p map[string]any) (map[string]any, error) {
		_, _ = original(pane, p)
		return nil, errors.New("reply lost after native write")
	}
	result, err := communicationGroupSend(root, "node", req, hooks)
	if err != nil {
		t.Fatal(err)
	}
	for _, target := range fanoutReceipt(t, result).Targets {
		if target.Result["status"] != "outcome_unknown" {
			t.Fatal(target)
		}
	}
	if _, err := communicationGroupSend(root, "node", req, hooks); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatal("unknown outcome retried")
	}
}
func TestCommunicationGroupFanoutPauseBetweenRecipients(t *testing.T) {
	root, req, hooks, calls := fanoutFixture(t)
	original := hooks.send
	hooks.send = func(pane string, p map[string]any) (map[string]any, error) {
		result, err := original(pane, p)
		if calls.Load() == 1 {
			e := communicationFanoutLocked(root, func() error {
				var policy communicationPolicy
				if e := communicationRead(communicationPolicyPath(root), &policy); e != nil {
					return e
				}
				policy.Callers[0].Paused = true
				return communicationAtomic(communicationPolicyPath(root), policy)
			})
			if e != nil {
				t.Error(e)
			}
		}
		return result, err
	}
	result, err := communicationGroupSend(root, "node", req, hooks)
	if err != nil {
		t.Fatal(err)
	}
	receipt := fanoutReceipt(t, result)
	if calls.Load() != 1 || receipt.Targets[1].Result["status"] != "blocked" {
		t.Fatal(calls.Load(), receipt)
	}
}
func TestCommunicationGroupFanoutConversationAndMembershipChangesBlock(t *testing.T) {
	t.Run("conversation", func(t *testing.T) {
		root, req, hooks, calls := fanoutFixture(t)
		original := hooks.observe
		hooks.observe = func(pane string) communicationMember {
			m := original(pane)
			if pane == testGroupB {
				m.SessionID = "new-conversation"
			}
			return m
		}
		result, err := communicationGroupSend(root, "node", req, hooks)
		if err != nil {
			t.Fatal(err)
		}
		if calls.Load() != 1 || fanoutReceipt(t, result).Targets[0].Result["status"] != "blocked" {
			t.Fatal(result, calls.Load())
		}
	})
	t.Run("membership", func(t *testing.T) {
		root, req, hooks, calls := fanoutFixture(t)
		original := hooks.send
		hooks.send = func(pane string, p map[string]any) (map[string]any, error) {
			result, err := original(pane, p)
			if calls.Load() == 1 {
				e := communicationFanoutLocked(root, func() error {
					var group communicationGroup
					path := filepath.Join(root, "group-"+req.GroupID+".json")
					if e := communicationRead(path, &group); e != nil {
						return e
					}
					group.Revision++
					return communicationAtomic(path, group)
				})
				if e != nil {
					t.Error(e)
				}
			}
			return result, err
		}
		result, err := communicationGroupSend(root, "node", req, hooks)
		if err != nil {
			t.Fatal(err)
		}
		if calls.Load() != 1 || fanoutReceipt(t, result).Targets[1].Result["status"] != "blocked" {
			t.Fatal(result, calls.Load())
		}
	})
}
func TestCommunicationGroupFanoutConcurrentDuplicateAndCrashReceipt(t *testing.T) {
	root, req, hooks, calls := fanoutFixture(t)
	original := hooks.send
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	hooks.send = func(pane string, p map[string]any) (map[string]any, error) {
		once.Do(func() { close(started); <-release })
		return original(pane, p)
	}
	done := make(chan error, 1)
	go func() { _, err := communicationGroupSend(root, "node", req, hooks); done <- err }()
	select {
	case <-started:
	case err := <-done:
		t.Fatal("dispatch failed before native callback", err)
	}
	if _, err := communicationGroupSend(root, "node", req, hooks); err != nil {
		t.Fatal(err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatal("concurrent duplicate delivery", calls.Load())
	}
	var parent communicationFanoutReceipt
	path := communicationFanoutPath(root, req.MessageID)
	if err := communicationRead(path, &parent); err != nil {
		t.Fatal(err)
	}
	for i := range parent.Targets {
		parent.Targets[i].Result = map[string]any{"status": "outcome_unknown"}
	}
	parent.DispatchFinished = false
	if err := communicationAtomic(path, parent); err != nil {
		t.Fatal(err)
	}
	result, err := communicationGroupOperation(root, "node", CommunicationRequest{Operation: "group_receipt", GroupID: req.GroupID, MessageID: req.MessageID}, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, target := range fanoutReceipt(t, result).Targets {
		if target.Result["status"] != "accepted_by_provider" {
			t.Fatal("lost durable child outcome", target)
		}
	}
	if _, err := communicationGroupSend(root, "node", req, hooks); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatal("crash recovery replayed delivery")
	}
}
func TestCommunicationNativeOutcomeCannotChangeAuthorityOrReplay(t *testing.T) {
	out := communicationNativeOutcome(map[string]any{"status": "written_to_socket", "acknowledgement": "not_implied",
		"authority": "forged", "replay_permitted": true, "source_pane_id": "forged"}, nil)
	if out["authority"] != nil || out["source_pane_id"] != nil || out["replay_permitted"] != false || out["acknowledgement"] != "not_implied" {
		t.Fatal("untrusted result changed provenance", out)
	}
}

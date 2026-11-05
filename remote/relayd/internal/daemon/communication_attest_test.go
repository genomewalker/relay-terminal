package daemon

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

const attestMessage = "5d7c1f0e-2b8a-4c39-9e61-0a4f3d2b7c18"

type attestFixture struct {
	root   string
	clock  time.Time
	member communicationMember
	deps   communicationAttestDeps
}

func newAttestFixture(t *testing.T) *attestFixture {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	f := &attestFixture{root: root, clock: time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC), member: sourceFixture("codex_app_server_message")}
	f.deps = communicationAttestDeps{
		observe: func(pane string) communicationMember {
			if pane != sourceFixturePane {
				return communicationMember{PaneID: pane, Unavailable: "not observed"}
			}
			return f.member
		},
		now: func() time.Time { return f.clock },
	}
	return f
}

func attestRequest() CommunicationRequest {
	return CommunicationRequest{Operation: "attest", SourcePaneID: sourceFixturePane, ActorPaneID: sourceFixturePane,
		PaneID: targetFixturePane, MessageID: attestMessage, Text: "hello", ClientID: "caller-a", actorVerified: true}
}

func consumeRequest(id string) CommunicationRequest {
	return CommunicationRequest{Operation: "attest_consume", AttestationID: id, SourcePaneID: sourceFixturePane,
		PaneID: targetFixturePane, MessageID: attestMessage, Text: "hello"}
}

func (f *attestFixture) mint(t *testing.T) string {
	t.Helper()
	result, err := communicationAttest(f.root, "node-a", attestRequest(), f.deps)
	if err != nil {
		t.Fatal(err)
	}
	return result["attestation_id"].(string)
}

func TestCommunicationAttestRequiresKernelVerifiedCaller(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	f := newAttestFixture(t)
	for name, mutate := range map[string]func(*CommunicationRequest){
		"claimed source":        func(r *CommunicationRequest) { r.actorVerified = false },
		"no actor":              func(r *CommunicationRequest) { r.ActorPaneID = "" },
		"actor is another pane": func(r *CommunicationRequest) { r.SourcePaneID = targetFixturePane; r.PaneID = sourceFixturePane },
	} {
		r := attestRequest()
		mutate(&r)
		if _, err := communicationAttest(f.root, "node-a", r, f.deps); err == nil {
			t.Errorf("%s: attestation minted", name)
		}
	}
	// JSON can neither verify the actor nor supply the observed sender fields.
	var decoded CommunicationRequest
	packet := `{"operation":"attest","actor_pane_id":"` + sourceFixturePane + `","source_pane_id":"` + sourceFixturePane +
		`","pane_id":"` + targetFixturePane + `","message_id":"` + attestMessage + `","text":"hello","actorVerified":true,"pid":1,"permissionClass":"prompting"}`
	if err := json.Unmarshal([]byte(packet), &decoded); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationAttest(f.root, "node-a", decoded, f.deps); err == nil {
		t.Fatal("a JSON packet minted an attestation")
	}
	if paths, _ := os.ReadDir(f.root); len(paths) != 0 {
		t.Fatalf("refused attestations left records: %v", paths)
	}
}

func TestCommunicationAttestRecordsOnlyObservedSender(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	f := newAttestFixture(t)
	id := f.mint(t)
	var record communicationAttestation
	if err := communicationRead(communicationAttestPath(f.root, id), &record); err != nil {
		t.Fatal(err)
	}
	if record.PID != 4242 || record.Start != "fixture" || record.SessionID != "sender-thread" || record.Provider != "codex" ||
		record.PermissionClass != "bypass" || record.NodeID != "node-a" || record.ClientID != "caller-a" ||
		record.TextSHA256 != communicationTextDigest("hello") || !record.ExpiresAt.Equal(f.clock.Add(communicationAttestTTL)) {
		t.Fatalf("record = %+v", record)
	}
	result, err := communicationAttestConsume(f.root, consumeRequest(id), f.deps)
	if err != nil {
		t.Fatal(err)
	}
	source := result["source"].(map[string]any)
	if source["authentication"] != "source_host_attested" || source["hostID"] != "node-a" || source["paneID"] != sourceFixturePane ||
		source["sessionID"] != "sender-thread" || source["provider"] != "codex" || source["permissionClass"] != "bypass" ||
		source["attestationID"] != id || source["submittingClientID"] != "caller-a" {
		t.Fatalf("source = %v", source)
	}
	if _, ok := source["socketPath"]; ok {
		t.Fatal("an attested source carried a host-local socket")
	}
}

func TestCommunicationAttestUnknownModeStaysUnasserted(t *testing.T) {
	withSenderPermissionClass(t, "")
	f := newAttestFixture(t)
	result, err := communicationAttestConsume(f.root, consumeRequest(f.mint(t)), f.deps)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := result["source"].(map[string]any)["permissionClass"]; ok {
		t.Fatal("an unknown mode was asserted")
	}
}

func TestCommunicationAttestModeChangeIsNotAsserted(t *testing.T) {
	withSenderPermissionClass(t, "prompting")
	f := newAttestFixture(t)
	id := f.mint(t)
	withSenderPermissionClass(t, "bypass")
	result, err := communicationAttestConsume(f.root, consumeRequest(id), f.deps)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := result["source"].(map[string]any)["permissionClass"]; ok {
		t.Fatal("a changed mode was asserted")
	}
}

func TestCommunicationAttestBindsExactMessage(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	f := newAttestFixture(t)
	for name, mutate := range map[string]func(*CommunicationRequest){
		"other text":    func(r *CommunicationRequest) { r.Text = "hello!" },
		"other target":  func(r *CommunicationRequest) { r.PaneID = "aaaaaaaa-6e69-4d1a-9c83-91a0a2dec1e9" },
		"other message": func(r *CommunicationRequest) { r.MessageID = "6e7c1f0e-2b8a-4c39-9e61-0a4f3d2b7c18" },
		"other source":  func(r *CommunicationRequest) { r.SourcePaneID = "bbbbbbbb-6e69-4d1a-9c83-91a0a2dec1e9" },
		"unknown id":    func(r *CommunicationRequest) { r.AttestationID = strings.Repeat("0", 32) },
		"malformed id":  func(r *CommunicationRequest) { r.AttestationID = "../link" },
		"caller token":  func(r *CommunicationRequest) { r.ClientToken = "provider-token" },
		"caller actor":  func(r *CommunicationRequest) { r.ActorPaneID = sourceFixturePane },
	} {
		id := f.mint(t)
		r := consumeRequest(id)
		mutate(&r)
		if _, err := communicationAttestConsume(f.root, r, f.deps); err == nil {
			t.Errorf("%s: consumed", name)
		}
	}
}

func TestCommunicationAttestExpiresAndIsSingleUse(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	f := newAttestFixture(t)
	expired := f.mint(t)
	f.clock = f.clock.Add(communicationAttestTTL)
	if _, err := communicationAttestConsume(f.root, consumeRequest(expired), f.deps); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expired attestation: %v", err)
	}
	id := f.mint(t)
	if _, err := communicationAttestConsume(f.root, consumeRequest(id), f.deps); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationAttestConsume(f.root, consumeRequest(id), f.deps); err == nil || !strings.Contains(err.Error(), "already used") {
		t.Fatalf("reused attestation: %v", err)
	}
}

func TestCommunicationAttestRejectsProviderRotation(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	for name, rotate := range map[string]func(*communicationMember){
		"new session":  func(m *communicationMember) { m.SessionID = "next-thread" },
		"new process":  func(m *communicationMember) { m.PID, m.Start = 4343, "restarted" },
		"new provider": func(m *communicationMember) { m.Provider = "claude" },
		"gone":         func(m *communicationMember) { m.Endpoint, m.Unavailable = nil, "exited" },
	} {
		f := newAttestFixture(t)
		id := f.mint(t)
		rotate(&f.member)
		if _, err := communicationAttestConsume(f.root, consumeRequest(id), f.deps); err == nil {
			t.Errorf("%s: consumed after rotation", name)
		}
		// The failed recheck spent the proof.
		f.member = sourceFixture("codex_app_server_message")
		if _, err := communicationAttestConsume(f.root, consumeRequest(id), f.deps); err == nil {
			t.Errorf("%s: proof reusable after a failed recheck", name)
		}
	}
}

func TestCommunicationAttestConcurrentBrokersSpendOnce(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	f := newAttestFixture(t)
	id := f.mint(t)
	var wg sync.WaitGroup
	var mu sync.Mutex
	won := 0
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := communicationAttestConsume(f.root, consumeRequest(id), f.deps); err == nil {
				mu.Lock()
				won++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if won != 1 {
		t.Fatalf("%d brokers spent one attestation", won)
	}
}

func TestCommunicationAttestRequiresLiveSource(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	f := newAttestFixture(t)
	f.member.Endpoint = nil
	if _, err := communicationAttest(f.root, "node-a", attestRequest(), f.deps); err == nil {
		t.Fatal("minted without a verified native session")
	}
	f.member = sourceFixture("codex_app_server_message")
	f.member.Provider = "shell"
	if _, err := communicationAttest(f.root, "node-a", attestRequest(), f.deps); err == nil {
		t.Fatal("minted for a non-agent provider")
	}
}

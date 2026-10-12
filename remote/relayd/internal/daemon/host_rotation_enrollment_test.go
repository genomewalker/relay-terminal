package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestHostRotationNativeDirectoryUsesSessionMetadata(t *testing.T) {
	for _, source := range []string{
		`{"type":"session_meta","payload":{"id":"fixture-session","cwd":"/native/project","source":"cli"}}` + "\n",
		`{"type":"session_meta","payload":{"id":"fixture-session","cwd":"/native/project","thread_source":"user"}}` + "\n",
	} {
		cwd, err := parseHostRotationNativeDirectory(context.Background(), strings.NewReader(source), "codex", "fixture-session")
		if err != nil || cwd != "/native/project" {
			t.Fatalf("native -C directory was lost: %q %v", cwd, err)
		}
	}
	claude := strings.ReplaceAll(rotationClaudeFixtureRow("user", "u", "", "public", nil), "/fixture", "/native/project") +
		rotationClaudeFixtureRow("assistant", "side", "", "ignored", map[string]any{"isSidechain": true, "cwd": "/other", "sessionId": "other"}) +
		strings.ReplaceAll(rotationClaudeFixtureRow("assistant", "a", "u", "public", nil), "/fixture", "/native/project")
	cwd, err := parseHostRotationNativeDirectory(context.Background(), strings.NewReader(claude), "claude", "fixture-session")
	if err != nil || cwd != "/native/project" {
		t.Fatalf("root Claude directory was lost: %q %v", cwd, err)
	}
}

func TestHostRotationNativeDirectoryRefusesMixedOrAmbiguousIdentity(t *testing.T) {
	base := `{"type":"session_meta","payload":{"id":"fixture-session","cwd":"/native/project","source":"cli"}}` + "\n"
	for name, source := range map[string]string{
		"other_session":   strings.Replace(base, "fixture-session", "another", 1),
		"relative":        strings.Replace(base, "/native/project", "relative", 1),
		"missing":         strings.Replace(base, `"cwd":"/native/project",`, "", 1),
		"duplicate_key":   strings.Replace(base, `"cwd":"/native/project"`, `"cwd":"/shell","cwd":"/native/project"`, 1),
		"second_metadata": base + base,
		"nested":          strings.Replace(base, `"source":"cli"`, `"source":{"subagent":{}}`, 1),
		"early_message":   `{"type":"response_item","payload":{}}` + "\n" + base,
		"bad_record":      base + "{",
		"large_line":      base + strings.Repeat("x", rotationSourceLineLimit+1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parseHostRotationNativeDirectory(context.Background(), strings.NewReader(source), "codex", "fixture-session"); err == nil {
				t.Fatal("ambiguous directory accepted")
			}
		})
	}
	claude := rotationClaudeFixtureRow("user", "u", "", "public", nil) +
		rotationClaudeFixtureRow("assistant", "a", "u", "public", map[string]any{"cwd": "/changed"})
	if _, err := parseHostRotationNativeDirectory(context.Background(), strings.NewReader(claude), "claude", "fixture-session"); err == nil {
		t.Fatal("mixed Claude directories accepted")
	}
	if _, err := parseHostRotationNativeDirectory(context.Background(), strings.NewReader(""), "codex", "fixture-session"); err == nil {
		t.Fatal("missing metadata accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := parseHostRotationNativeDirectory(ctx, strings.NewReader(base), "codex", "fixture-session"); !errors.Is(err, context.Canceled) {
		t.Fatal("cancelled discovery continued", err)
	}
}

func TestHostRotationNativeDirectoryRetainsFileIdentity(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	directory := filepath.Join(home, ".codex", "sessions")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "fixture.jsonl")
	source := []byte(`{"type":"session_meta","payload":{"id":"fixture-session","cwd":"/native/project","source":"cli"}}` + "\n")
	if err := os.WriteFile(path, source, 0600); err != nil {
		t.Fatal(err)
	}
	binding := AgentBindingRecord{Version: 1, SessionID: "fixture-session", TranscriptPath: path, Revision: "native-revision",
		Producer: agentProducer{PaneID: "fixture-pane", Provider: "codex", ProcessID: 101, ProcessStart: 102}}
	candidate, err := readHostRotationNativeDirectory(context.Background(), binding)
	if err != nil || candidate.CWD != "/native/project" {
		t.Fatal(candidate.CWD, err)
	}
	if err := os.WriteFile(path, append(source, []byte(`{"type":"event_msg","payload":{}}`+"\n")...), 0600); err != nil {
		t.Fatal(err)
	}
	if candidate.verifyFile() == nil {
		t.Fatal("changed transcript retained discovery")
	}
	if err := os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if _, err := readHostRotationNativeDirectory(context.Background(), binding); err == nil {
		t.Fatal("shared transcript accepted")
	}
}

func TestHostRotationNativeCandidateMatchesExactEnrollment(t *testing.T) {
	candidate := hostRotationNativeCandidate{Version: 1, State: "ready", CWD: "/native/project", Binding: AgentBindingRecord{
		Version: 1, SessionID: "fixture-session", TranscriptPath: "/source.jsonl", Revision: "revision",
		Producer: agentProducer{PaneID: "fixture-pane", Provider: "codex", ProcessID: 101, ProcessStart: ^uint64(0)}}}
	request := hostRotationRequest{SessionID: "fixture-session", Client: "codex", CWD: "/native/project", AgentPID: 101, AgentStart: ^uint64(0)}
	if !candidate.matches(request, "fixture-pane") {
		t.Fatal("native candidate did not match")
	}
	for name, change := range map[string]func(*hostRotationRequest){
		"cwd":      func(r *hostRotationRequest) { r.CWD = "/shell" },
		"session":  func(r *hostRotationRequest) { r.SessionID = "other" },
		"provider": func(r *hostRotationRequest) { r.Client = "claude" },
		"pid":      func(r *hostRotationRequest) { r.AgentPID++ },
		"start":    func(r *hostRotationRequest) { r.AgentStart-- },
	} {
		t.Run(name, func(t *testing.T) {
			bad := request
			change(&bad)
			if candidate.matches(bad, "fixture-pane") {
				t.Fatal("different enrollment accepted")
			}
		})
	}
	if candidate.matches(request, "another-pane") {
		t.Fatal("candidate accepted a different pane")
	}
}

func TestHostRotationHumanInputRevisionRejectsReplayedInput(t *testing.T) {
	sink, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer sink.Close()
	session := &Session{pty: sink, inputSequences: map[[16]byte]uint64{}}
	if err := session.input([]byte("human")); err != nil {
		t.Fatal(err)
	}
	if session.humanInputRevision != 1 {
		t.Fatal("ordinary human input did not invalidate discovery")
	}
	client := [16]byte{1}
	if err := session.acknowledgedInput(client, 1, []byte("next")); err != nil {
		t.Fatal(err)
	}
	if err := session.acknowledgedInput(client, 1, []byte("replay")); err != nil {
		t.Fatal(err)
	}
	if session.humanInputRevision != 2 {
		t.Fatal("acknowledged input replay advanced revision")
	}
}

func TestHostRotationEnrollmentDoesNotBlockOrOverrideHumanInput(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "relay-enroll-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	listener, err := net.Listen("unix", filepath.Join(root, "test.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	sink, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer sink.Close()
	supervisor := newHostRotationSupervisor(filepath.Join(root, "rotation", "state.json"), func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
		return nil, errors.New("unused")
	})
	defer supervisor.close()
	session := &Session{pty: sink, hostRotation: supervisor}
	if !session.acquireControl("controller") {
		t.Fatal("control unavailable")
	}
	started, release, served := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	releaseDiscovery := func() { releaseOnce.Do(func() { close(release) }) }
	defer releaseDiscovery()
	readCandidate := func(context.Context, string) (hostRotationNativeCandidate, error) {
		close(started)
		<-release
		return hostRotationNativeCandidate{Version: 1, State: "ready", CWD: "/native/project", Binding: AgentBindingRecord{
			Version: 1, SessionID: "fixture-session", TranscriptPath: "/unused.jsonl", Revision: "revision",
			Producer: agentProducer{PaneID: "fixture-pane", Provider: "codex", ProcessID: 101, ProcessStart: 102}}}, nil
	}
	go func() {
		defer close(served)
		c, err := listener.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		frame, err := protocol.ReadFrame(c)
		if err != nil {
			return
		}
		var hello protocol.HelloPayload
		if protocol.DecodeJSON(frame, &hello) != nil {
			return
		}
		serveHostRotationRequestWithServices(c, protocol.NewWriter(c), hello, session, WorkerConfig{SessionID: "fixture-pane"}, hostRotationRPCServices{readCandidate: readCandidate})
	}()
	client, err := net.DialTimeout("unix", listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(3 * time.Second))
	request, _ := json.Marshal(hostRotationRequest{Version: 1, Operation: "enroll", ID: strings.Repeat("a", 32),
		SessionID: "fixture-session", Client: "codex", CWD: "/native/project", AgentPID: 101, AgentStart: 102})
	frame, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{ClientID: "controller", HostRotation: request})
	if err := protocol.NewWriter(client).Write(frame); err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("discovery did not start")
	}
	inputDone := make(chan error, 1)
	go func() { inputDone <- session.input([]byte("human draft")) }()
	select {
	case err := <-inputDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		releaseDiscovery()
		t.Fatal("discovery blocked human input")
	}
	releaseDiscovery()
	frame, err = protocol.ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	var response struct {
		State   string `json:"state"`
		Message string `json:"message"`
	}
	if protocol.DecodeJSON(frame, &response) != nil || response.State != "refused" || !strings.Contains(response.Message, "human input") {
		t.Fatalf("human takeover overwritten: %+v", response)
	}
	<-served
	if supervisor.snapshot().Enabled {
		t.Fatal("human-owned session enrolled")
	}
}

package main

import (
	"errors"
	"github.com/relay-terminal/relayd/internal/daemon"
	"testing"
)

func TestAgentBindingNativeDiagnosticRouting(t *testing.T) {
	for _, nativeOnly := range []bool{false, true} {
		verifiedCalls, nativeCalls := 0, 0
		verified := func(pane string) (daemon.AgentBindingRecord, error) {
			verifiedCalls++
			return daemon.AgentBindingRecord{Source: "stored"}, nil
		}
		native := func(pane string) (daemon.AgentBindingRecord, error) {
			nativeCalls++
			if pane != "pane" {
				t.Fatal(pane)
			}
			return daemon.AgentBindingRecord{Source: "native"}, nil
		}
		args := []string{"pane"}
		if nativeOnly {
			args = []string{"--native", "pane"}
		}
		record, err := readAgentBindingArgs(args, verified, native)
		if err != nil {
			t.Fatal(err)
		}
		if nativeOnly && (nativeCalls != 1 || verifiedCalls != 0 || record.Source != "native") {
			t.Fatal("native diagnostic used stored record")
		}
		if !nativeOnly && (verifiedCalls != 1 || nativeCalls != 0 || record.Source != "stored") {
			t.Fatal("default route changed")
		}
	}
}

func TestAgentBindingNativeDiagnosticRejectsMalformedArguments(t *testing.T) {
	reader := func(string) (daemon.AgentBindingRecord, error) {
		t.Fatal("reader invoked for malformed arguments")
		return daemon.AgentBindingRecord{}, nil
	}
	for _, args := range [][]string{nil, {"--native"}, {"--native", ""}, {"--native", "--native"}, {"pane", "--native"}, {"--other", "pane"}, {"--native", "pane", "extra"}} {
		if _, err := readAgentBindingArgs(args, reader, reader); err == nil {
			t.Fatalf("accepted %q", args)
		}
	}
}

func TestAgentBindingNativeDiagnosticDoesNotFallback(t *testing.T) {
	want := errors.New("native unavailable")
	stored := func(string) (daemon.AgentBindingRecord, error) {
		t.Fatal("native failure fell back to stored binding")
		return daemon.AgentBindingRecord{}, nil
	}
	native := func(string) (daemon.AgentBindingRecord, error) { return daemon.AgentBindingRecord{}, want }
	if _, err := readAgentBindingArgs([]string{"--native", "pane"}, stored, native); !errors.Is(err, want) {
		t.Fatal(err)
	}
}

func TestAgentBindingTargetSessionUsesOnlyTheTargetReader(t *testing.T) {
	original := readTargetAgentBinding
	defer func() { readTargetAgentBinding = original }()
	calls := 0
	readTargetAgentBinding = func(pane, session string) (daemon.AgentBindingRecord, error) {
		calls++
		if pane != "pane" || session != "5577ee9d-5e02-4ca8-b208-74360e3f65d1" {
			t.Fatal(pane, session)
		}
		return daemon.AgentBindingRecord{Source: "native_pane_job_kernel_owner", SessionID: session}, nil
	}
	other := func(string) (daemon.AgentBindingRecord, error) {
		t.Fatal("a target session fell back to the pane binding")
		return daemon.AgentBindingRecord{}, nil
	}
	record, err := readAgentBindingArgs([]string{"pane", "--session", "5577ee9d-5e02-4ca8-b208-74360e3f65d1"}, other, other)
	if err != nil || calls != 1 || record.Source != "native_pane_job_kernel_owner" {
		t.Fatal(record, err)
	}
	want := errors.New("target unavailable")
	readTargetAgentBinding = func(string, string) (daemon.AgentBindingRecord, error) { return daemon.AgentBindingRecord{}, want }
	if _, err := readAgentBindingArgs([]string{"pane", "--session", "5577ee9d-5e02-4ca8-b208-74360e3f65d1"}, other, other); !errors.Is(err, want) {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"pane", "--session"}, {"pane", "--session", ""}, {"--session", "pane", "id"}, {"--native", "--session", "id"}} {
		if _, err := readAgentBindingArgs(args, other, other); err == nil {
			t.Fatalf("accepted %q", args)
		}
	}
}

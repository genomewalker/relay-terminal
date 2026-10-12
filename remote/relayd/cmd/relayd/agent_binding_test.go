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

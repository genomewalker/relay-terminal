package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type nativeFixtureReply struct {
	Out    string
	Error  string
	Exit   int
	Record bool
}

type nativeFixtureConfig struct {
	Pane       string
	ClientPID  int
	Source     string
	ActorFails bool
	Wire       string
	Default    nativeFixtureReply
	Operations map[string]nativeFixtureReply
}

// The test binary supplies all fixture behavior. The small shell entry point
// only selects a private config and execs the same Go binary.
func init() {
	path := os.Getenv("RELAY_MCP_GO_FIXTURE")
	if path == "" {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprint(os.Stderr, err)
		os.Exit(90)
	}
	var config nativeFixtureConfig
	if json.Unmarshal(data, &config) != nil {
		os.Exit(91)
	}
	if len(os.Args) > 1 && os.Args[1] == "communication-actor" {
		if config.ActorFails {
			fmt.Fprint(os.Stderr, "no unique live pane owns this client")
			os.Exit(1)
		}
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"version": 1, "pane_id": config.Pane, "client_pid": config.ClientPID, "client_start": "current", "source": config.Source})
		os.Exit(0)
	}
	data, err = io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
	if err != nil {
		os.Exit(92)
	}
	var packet map[string]any
	if json.Unmarshal(data, &packet) != nil {
		os.Exit(93)
	}
	reply := config.Default
	if op, ok := packet["operation"].(string); ok {
		if override, found := config.Operations[op]; found {
			reply = override
		}
	}
	if reply.Record {
		if err := os.WriteFile(config.Wire, data, 0600); err != nil {
			fmt.Fprint(os.Stderr, err)
			os.Exit(94)
		}
	}
	fmt.Fprint(os.Stdout, reply.Out)
	fmt.Fprint(os.Stderr, reply.Error)
	os.Exit(reply.Exit)
}

func nativeMCPFixture(t *testing.T, config nativeFixtureConfig) string {
	t.Helper()
	if config.Source == "" {
		config.Source = "foreground_worker_kernel_ancestry"
	}
	if config.ClientPID == 0 {
		config.ClientPID = os.Getpid()
	}
	path := filepath.Join(t.TempDir(), "helper")
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".json", data, 0600); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }
	script := "#!/bin/sh\nRELAY_MCP_GO_FIXTURE=" + quote(path+".json") + " exec " + quote(executable) + " \"$@\"\n"
	if err := os.WriteFile(path, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	return path
}

func nativeFixtureWithoutActor(t *testing.T, helper string) string {
	t.Helper()
	data, err := os.ReadFile(helper + ".json")
	if err != nil {
		t.Fatal(err)
	}
	var config nativeFixtureConfig
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	config.ActorFails = true
	return nativeMCPFixture(t, config)
}

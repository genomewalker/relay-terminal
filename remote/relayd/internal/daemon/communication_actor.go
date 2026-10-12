package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
)

type CommunicationActor struct {
	Version     int    `json:"version"`
	PaneID      string `json:"pane_id"`
	ClientPID   int    `json:"client_pid"`
	ClientStart string `json:"client_start"`
	Source      string `json:"source"`
}

func communicationPaneForAncestry(chain []int) (string, error) {
	server := NewServer()
	paths, err := filepath.Glob(filepath.Join(server.stateDir, "*.json"))
	if err != nil || len(paths) > 4096 {
		return "", errors.New("pane worker inventory unavailable or exceeds limit")
	}
	panes := []string{}
	for _, path := range paths {
		pane := filepath.Base(path[:len(path)-len(".json")])
		if !validSessionID.MatchString(pane) {
			continue
		}
		manifest, err := loadManifest(path)
		if err == nil && manifest.SessionID == pane && validateWorkerIdentity(manifest) == nil &&
			harnessChainContains(chain, manifest.ShellPID) {
			panes = append(panes, pane)
		}
	}
	if len(panes) != 1 {
		return "", errors.New("no unique live pane owns this client")
	}
	return panes[0], nil
}

func nativeClaudePublicationKind(path string) string {
	if nativeClaudeMetadataObject(filepath.Dir(path), true) != nil || nativeClaudeMetadataObject(path, false) != nil {
		return ""
	}
	f, err := os.OpenFile(path, os.O_RDONLY, 0)
	if err != nil {
		return ""
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 65537))
	var row struct {
		Kind string `json:"kind"`
	}
	if err != nil || len(data) > 65536 || json.Unmarshal(data, &row) != nil {
		return ""
	}
	return row.Kind
}

// Observe the caller's logical native pane. A shared Claude daemon inherits its
// bootstrap pane environment, which cannot identify every parked conversation.
// This report supplies routing metadata; it grants no execution or trust.
func ReadCommunicationActor(clientPID int) (CommunicationActor, error) {
	var empty CommunicationActor
	if clientPID <= 1 {
		return empty, errors.New("invalid communication client")
	}
	start, err := processStartIdentity(clientPID)
	if err != nil {
		return empty, err
	}
	chain, err := networkAncestors(clientPID, start)
	if err != nil {
		return empty, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return empty, err
	}
	pane, source := "", "foreground_worker_kernel_ancestry"
	for _, pid := range chain {
		path := filepath.Join(home, ".claude", "sessions", strconv.Itoa(pid)+".json")
		if nativeClaudePublicationKind(path) != "bg" {
			continue
		}
		bgStart, err := processStartIdentity(pid)
		if err != nil {
			return empty, err
		}
		bg, _, _, err := readNativeClaudeRegistrationKind(path, pid, bgStart, "bg")
		if err != nil || !nativeClaudeJobID.MatchString(bg.JobID) {
			return empty, errors.New("native background client publication unavailable")
		}
		fronts, err := nativeClaudePublications(home, "interactive", bg.JobID)
		if err != nil || len(fronts) != 1 {
			return empty, errors.New("native background client has no unique parked foreground")
		}
		front := fronts[0].record
		frontChain, err := networkAncestors(front.PID, front.ProcessStart)
		if err != nil {
			return empty, err
		}
		pane, err = communicationPaneForAncestry(frontChain)
		if err != nil {
			return empty, err
		}
		binding, err := ReadNativeClaudeBinding(pane)
		if err != nil || binding.Source != "native_parked_job_kernel_owner" || binding.NativePeer == nil ||
			binding.NativePeer.PID != pid || binding.NativePeer.ProcessStart != bgStart ||
			binding.NativePeer.JobID != bg.JobID || binding.SessionID != bg.SessionID {
			return empty, errors.New("native background client attachment changed")
		}
		source = binding.Source
		break
	}
	if pane == "" {
		pane, err = communicationPaneForAncestry(chain)
		if err != nil {
			return empty, err
		}
		server := NewServer()
		manifest, err := loadManifest(server.manifestPath(pane))
		if err != nil {
			return empty, err
		}
		provider, pid := nativeBindingFrontend(manifest.ShellPID)
		if (provider != "claude" && provider != "codex") || !harnessChainContains(chain, pid) {
			return empty, errors.New("client is not owned by the pane's foreground harness")
		}
		if _, err := NativeAgentIncarnation(pane, pid, provider); err != nil {
			return empty, err
		}
	}
	after, err := processStartIdentity(clientPID)
	if err != nil || after != start {
		return empty, fmt.Errorf("communication client changed during observation")
	}
	return CommunicationActor{Version: 1, PaneID: pane, ClientPID: clientPID, ClientStart: start, Source: source}, nil
}

func reconcileCommunicationActor(r CommunicationRequest, actor CommunicationActor, bootstrap string) (CommunicationRequest, error) {
	if r.ActorPaneID == actor.PaneID {
		return r, nil
	}
	if actor.Source != "native_parked_job_kernel_owner" || bootstrap == "" ||
		r.ActorPaneID != bootstrap || (r.SourcePaneID != "" && r.SourcePaneID != bootstrap) {
		return r, errors.New("communication sender does not match the native caller pane")
	}
	// Older MCP processes inherited the common daemon's bootstrap environment.
	// Correct only that proven alias, before authorization, fingerprints or writes.
	r.ActorPaneID = actor.PaneID
	if r.SourcePaneID != "" {
		r.SourcePaneID = actor.PaneID
	}
	return r, nil
}

func ReconcileCommunicationActor(r CommunicationRequest, clientPID int) (CommunicationRequest, error) {
	if r.ActorPaneID == "" {
		return r, nil
	}
	actor, err := ReadCommunicationActor(clientPID)
	if err != nil {
		return r, err
	}
	bootstrap := ""
	if actor.Source == "native_parked_job_kernel_owner" && actor.PaneID != r.ActorPaneID {
		chain, err := networkAncestors(clientPID, actor.ClientStart)
		if err != nil {
			return r, err
		}
		bootstrap, err = communicationPaneForAncestry(chain)
		if err != nil {
			return r, err
		}
	}
	return reconcileCommunicationActor(r, actor, bootstrap)
}

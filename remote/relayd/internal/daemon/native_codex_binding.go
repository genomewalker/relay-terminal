package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/relay-terminal/relayd/internal/codexsession"
)

var errNativeRuntimeUnsupported = errors.New("native Codex runtime kernel discovery is unavailable on this platform")

type NativeCodexEndpoint struct {
	FrontendSocket string `json:"frontend_socket"`
	DaemonSocket   string `json:"daemon_socket"`
	Socket         string `json:"socket"`
	Origin         string `json:"origin"`
	DaemonPID      int    `json:"daemon_pid"`
	DaemonStart    uint64 `json:"daemon_start"`
	Device         uint64 `json:"device"`
	Inode          uint64 `json:"inode"`
}

// ReadNativeCodexBinding observes the existing frontend and daemon. It never
// writes a binding file, resumes a thread, or changes a retained worker.
func ReadNativeCodexBinding(pane string) (AgentBindingRecord, error) {
	var empty AgentBindingRecord
	if !validSessionID.MatchString(pane) {
		return empty, errors.New("invalid pane")
	}
	proxy, proxyErr := readStockCodexProxyBinding(pane)
	if proxyErr == nil {
		return proxy, nil
	}
	if !errors.Is(proxyErr, errNoStockCodexProxy) {
		return empty, proxyErr
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane || validateWorkerIdentity(manifest) != nil {
		return empty, errors.New("native worker unavailable")
	}
	provider, pid := nativeBindingFrontend(manifest.ShellPID)
	if provider != "codex" || pid <= 1 {
		return empty, errors.New("no unique original Codex frontend")
	}
	start, err := NativeAgentIncarnation(pane, pid, "codex")
	if err != nil {
		return empty, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	before, err := nativeCodexEndpoint(ctx, pid)
	if err != nil {
		local, localErr := nativeCodexOpenTranscriptBinding(pane, pid, start)
		if localErr == nil {
			return local, nil
		}
		return empty, fmt.Errorf("%w; transcript binding unavailable: %v", err, localErr)
	}
	connection, err := (&net.Dialer{}).DialContext(ctx, "unix", before.Socket)
	if err != nil {
		return empty, err
	}
	defer connection.Close()
	uid, peer, err := PeerCredentials(connection)
	if err != nil || uid != os.Getuid() || peer != before.DaemonPID {
		return empty, errors.New("native daemon peer identity mismatch")
	}
	if current, e := processStartTime(peer); e != nil || current != before.DaemonStart {
		return empty, errors.New("native daemon incarnation changed")
	}
	runtime, err := codexsession.ObserveRuntime(ctx, connection, before.Origin)
	if err != nil {
		return empty, err
	}
	override := processAccountOverride(pid, "codex")
	if !validSessionID.MatchString(runtime.ThreadID) || validateAccountTranscript(runtime.TranscriptPath, "codex", override) != nil {
		return empty, errors.New("native transcript binding invalid")
	}
	after, err := nativeCodexEndpoint(ctx, pid)
	if err != nil || before != after {
		return empty, errors.New("native endpoint changed during observation")
	}
	currentProvider, currentPID := nativeBindingFrontend(manifest.ShellPID)
	if currentProvider != "codex" || currentPID != pid {
		return empty, errors.New("native frontend selection changed")
	}
	current, err := NativeAgentIncarnation(pane, pid, "codex")
	if err != nil || current != start || validateWorkerIdentity(manifest) != nil {
		return empty, errors.New("native frontend changed during observation")
	}
	// The revision identifies an association, not its observation timestamp.
	revisionData, _ := json.Marshal(struct {
		Pane     string
		Frontend int
		Start    uint64
		Endpoint NativeCodexEndpoint
		Thread   string
		Path     string
	}{pane, pid, start, before, runtime.ThreadID, runtime.TranscriptPath})
	sum := sha256.Sum256(revisionData)
	return AgentBindingRecord{
		Version: 1, Producer: agentProducer{PaneID: pane, Provider: "codex", ProcessID: pid, ProcessStart: start, ConfigDir: override},
		SessionID: runtime.ThreadID, TranscriptPath: runtime.TranscriptPath, ObservedAt: time.Now().UTC(),
		Lifecycle: "unknown", Revision: hex.EncodeToString(sum[:]), Source: "native_runtime_mcp_origin", NativeEndpoint: &before,
	}, nil
}

// nativeBindingFrontend requires a unique top-level provider on every platform.
func nativeBindingFrontend(shell int) (string, int) {
	processes := descendantAgentProcesses(shell)
	if len(processes) == 0 || len(processes) > 512 {
		return "", 0
	}
	processes = nativeFrontendProcesses(processes, nativeCodexLauncherChild)
	roots := []int{}
	for pid := range processes {
		start, err := processStartIdentity(pid)
		if err != nil {
			return "", 0
		}
		chain, err := networkAncestors(pid, start)
		if err != nil || len(chain) > 64 {
			return "", 0
		}
		belongs, nested := false, false
		for index, parent := range chain {
			if parent == shell {
				belongs = true
				break
			}
			if index > 0 && processes[parent] != "" {
				nested = true
			}
		}
		if !belongs {
			return "", 0
		}
		if !nested {
			roots = append(roots, pid)
		}
	}
	if len(roots) > 1 {
		// A resumed conversation can leave the previous frontend suspended
		// (job control) under the same shell. Only the terminal's foreground
		// process group receives the pane's input, so it is the frontend.
		roots = foregroundFrontendRoots(roots, harnessProcessGroup, harnessForegroundGroup)
	}
	if len(roots) != 1 {
		return "", 0
	}
	return processes[roots[0]], roots[0]
}

// foregroundFrontendRoots keeps the roots whose process group is the
// controlling terminal's foreground group. Stopped or background jobs are
// never that group; any lookup failure keeps nothing, so ambiguity refuses.
func foregroundFrontendRoots(roots []int, group, foreground func(int) (int, error)) []int {
	kept := []int{}
	for _, pid := range roots {
		processGroup, groupErr := group(pid)
		foregroundGroup, foregroundErr := foreground(pid)
		if groupErr != nil || foregroundErr != nil {
			return nil
		}
		if processGroup > 0 && processGroup == foregroundGroup {
			kept = append(kept, pid)
		}
	}
	return kept
}

// nativeFrontendProcesses removes an identified stock Node launcher only when
// its unique direct native CLI child is independently verified by the kernel.
// Native providers and nested agents retain the original ancestry checks.
func nativeFrontendProcesses(processes map[int]string, launcherChild func(int, map[int]string) int) map[int]string {
	result := make(map[int]string, len(processes))
	for pid, provider := range processes {
		result[pid] = provider
	}
	for pid, provider := range processes {
		if provider == "codex" {
			child := launcherChild(pid, processes)
			if child > 1 && child != pid && processes[child] == "codex" {
				delete(result, pid)
			}
		}
	}
	return result
}

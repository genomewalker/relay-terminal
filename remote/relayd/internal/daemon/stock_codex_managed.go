package daemon

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

func StockCodexLauncherStart() (uint64, error) { return processStartTime(os.Getpid()) }

// The launcher remains the original frontend PID across exec. This child owns
// one private backend and proxy; it never adopts another app server or thread.
func ServeManagedStockCodexBackend(ctx context.Context, pane string, parent int, parentStart uint64,
	executable string, environment []string, permissions agentlaunch.CodexPermissions, ready io.Writer) error {
	if !validSessionID.MatchString(pane) || parent <= 1 || parentStart == 0 || !filepath.IsAbs(executable) {
		return errors.New("invalid managed Codex launch")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane || codexProxyManifest(server, manifest) != nil {
		return errors.New("managed Codex worker unavailable")
	}
	start, err := processStartTime(parent)
	if err != nil || start != parentStart {
		return errors.New("managed Codex launcher changed")
	}
	identity, err := processStartIdentity(parent)
	if err != nil {
		return err
	}
	chain, err := networkAncestors(parent, identity)
	if err != nil {
		return err
	}
	insideShell, insideWorker := false, false
	for _, pid := range chain {
		insideShell = insideShell || pid == manifest.ShellPID
		insideWorker = insideWorker || pid == manifest.WorkerPID
	}
	if !insideShell || !insideWorker {
		return errors.New("managed Codex launcher is outside its pane")
	}

	root := filepath.Join("/tmp", fmt.Sprintf("relay-codex-managed-%d", os.Getuid()))
	if err := EnsurePrivateRuntimeDir(root); err != nil {
		return err
	}
	directory, err := os.MkdirTemp(root, "backend-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "server.sock")
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	backend := exec.CommandContext(ctx, executable, managedCodexBackendArguments(socket, permissions)...)
	backend.Env = environment
	backend.Stdin, backend.Stdout, backend.Stderr = nil, io.Discard, io.Discard
	if err := backend.Start(); err != nil {
		return errors.New("managed Codex app server did not start")
	}
	backendDone := make(chan error, 1)
	go func() { backendDone <- backend.Wait() }()
	defer func() {
		cancel()
		_ = backend.Process.Kill()
		select {
		case <-backendDone:
		case <-time.After(3 * time.Second):
		}
	}()

	// Bind readiness to the child actually listening, including an official
	// Node launcher whose native app-server process is its descendant.
	deadline := time.NewTimer(20 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(25 * time.Millisecond)
	defer tick.Stop()
	backendPID, backendStart := 0, uint64(0)
	for backendPID == 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return errors.New("managed Codex app server was not ready")
		case <-backendDone:
			return errors.New("managed Codex app server exited before readiness")
		case <-tick.C:
			conn, dialErr := net.DialTimeout("unix", socket, 50*time.Millisecond)
			if dialErr != nil {
				continue
			}
			uid, pid, peerErr := PeerCredentials(conn)
			conn.Close()
			if peerErr != nil || uid != os.Getuid() {
				return errors.New("managed Codex backend owner changed")
			}
			peerIdentity, peerErr := processStartIdentity(pid)
			if peerErr != nil {
				return peerErr
			}
			ancestry, peerErr := networkAncestors(pid, peerIdentity)
			owned := false
			for _, ancestor := range ancestry {
				owned = owned || ancestor == backend.Process.Pid
			}
			if peerErr != nil || !owned {
				return errors.New("managed Codex backend left its launch")
			}
			// Official Codex publishes the requested Unix path as an alias to
			// its private canonical socket. The peer above must first prove it
			// is our own launched backend; pin the canonical inode thereafter.
			canonical, err := filepath.EvalSymlinks(socket)
			if err != nil {
				return errors.New("managed Codex backend alias changed")
			}
			if err := privateManagedCodexBackendSocket(canonical); err != nil {
				return err
			}
			socket = canonical
			backendPID = pid
			backendStart, err = processStartTime(pid)
			if err != nil {
				return err
			}
		}
	}
	go func() {
		watch := time.NewTicker(time.Second)
		defer watch.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-watch.C:
				current, err := processStartTime(parent)
				if err != nil || current != parentStart {
					cancel()
					return
				}
			}
		}
	}()
	var resumePermissions *agentlaunch.CodexPermissions
	if len(permissions.AppServerArguments()) > 0 {
		resumePermissions = &permissions
	}
	return ServeStockCodexProxy(ctx, CodexProxyOptions{Pane: pane, BackendSocket: socket,
		BackendPID: backendPID, BackendStart: backendStart, TrackPrimary: true, ExitWithFrontend: true,
		ResumePermissions: resumePermissions}, ready)
}

func privateManagedCodexBackendSocket(path string) error {
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return errors.New("managed Codex backend socket unavailable")
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() {
		return errors.New("managed Codex backend socket owner changed")
	}
	if err := os.Chmod(path, 0600); err != nil {
		return err
	}
	_, _, err = codexProxySocketIdentity(path)
	return err
}

// Saved permissions are config overrides on this private app server, which
// serves only this pane's resumed thread.
func managedCodexBackendArguments(socket string, permissions agentlaunch.CodexPermissions) []string {
	return append([]string{"app-server", "--listen", "unix://" + socket}, permissions.AppServerArguments()...)
}

package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// Runtime implementations are native; independent captured reference outputs
// replace the old equality check between duplicate interpreter source copies.
func checkHealthNativeResources(root string) error {
	for path, expected := range map[string]string{
		"remote/relayd/internal/daemon/testdata/host_pane_health_probe/linux-reference.json":      "5691eb6e1a5bf21647050bab4125ae7b8107ea73d2c9e98f789a20d001185bd5",
		"remote/relayd/internal/daemon/testdata/host_pane_health_probe/reference.json":            "0c8340042b720f3e95f1917809cefdd9c9462c80cd507ea2de3267a9e02b5539",
		"remote/relayd/internal/daemon/testdata/host_pane_health_probe/linux-live-reference.json": "b8df78daddd5464d14ee09803bee204bc8d01f5c95c2b9e5685c1a4171f56dc7",
	} {
		data, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			return err
		}
		if fmt.Sprintf("%x", sha256.Sum256(data)) != expected {
			return fmt.Errorf("primary health reference drift: %s", path)
		}
	}
	return filepath.WalkDir(filepath.Join(root, "Sources", "Relay", "Resources"), func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		name := strings.ToLower(entry.Name())
		if name == "__pycache__" || strings.HasSuffix(name, ".py") || strings.HasSuffix(name, ".pyc") || strings.HasSuffix(name, ".pyo") {
			return fmt.Errorf("stale interpreter health resource: %s", path)
		}
		return nil
	})
}

func TestHostPaneHealthOracleResourcesMatchCanonicalSource(t *testing.T) {
	if err := checkHealthNativeResources(filepath.Join("..", "..", "..", "..")); err != nil {
		t.Fatal(err)
	}
}

func TestHostPaneHealthNativeResourceCheckRejectsDriftAndStalePayloads(t *testing.T) {
	source := filepath.Join("..", "..", "..", "..")
	root := t.TempDir()
	for _, path := range []string{"remote/relayd/internal/daemon/testdata/host_pane_health_probe/linux-reference.json", "remote/relayd/internal/daemon/testdata/host_pane_health_probe/reference.json", "remote/relayd/internal/daemon/testdata/host_pane_health_probe/linux-live-reference.json"} {
		data, err := os.ReadFile(filepath.Join(source, path))
		if err != nil {
			t.Fatal(err)
		}
		destination := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(destination, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	resources := filepath.Join(root, "Sources", "Relay", "Resources")
	if err := os.MkdirAll(resources, 0700); err != nil {
		t.Fatal(err)
	}
	if err := checkHealthNativeResources(root); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"old.py", "OLD.PYC", "old.pyo", "__pycache__"} {
		path := filepath.Join(resources, name)
		if err := os.WriteFile(path, []byte("stale"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := checkHealthNativeResources(root); err == nil {
			t.Fatalf("accepted stale payload %s", name)
		}
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(root, "remote/relayd/internal/daemon/testdata/host_pane_health_probe/reference.json")
	if err := os.WriteFile(path, []byte("[]"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := checkHealthNativeResources(root); err == nil {
		t.Fatal("accepted changed primary reference")
	}
}

func TestHostPaneHealthControllerRejectsCommandsAmbiguityAndDuplicatePanes(t *testing.T) {
	valid := `{"v":1,"operation":"pane_health_controller","operation_id":"11111111111111111111111111111111","action":"configure","host_id":"owned-host","owner_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","enabled":true,"haiku_enabled":false,"panes":["11111111-2222-4333-8444-555555555555"]}`
	if _, err := validHostPaneHealthControllerRequest([]byte(valid)); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		strings.Replace(valid, `"enabled":true`, `"enabled":true,"enabled":false`, 1),
		strings.Replace(valid, `"enabled":true`, `"enabled":true,"command":"/exit"`, 1),
		strings.Replace(valid, `"action":"configure"`, `"action":"send_input"`, 1),
		strings.Replace(valid, `"11111111-2222-4333-8444-555555555555"]`, `"11111111-2222-4333-8444-555555555555","11111111-2222-4333-8444-555555555555"]`, 1),
	} {
		if _, err := validHostPaneHealthControllerRequest([]byte(bad)); err == nil {
			t.Fatalf("unsafe controller request accepted: %.100s", bad)
		}
	}
}

func TestHostPaneHealthRPCCancellationDoesNotWaitForItsReadDeadline(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "relay-hh-cancel-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "test.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	started := make(chan struct{})
	serverDone := make(chan error, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			serverDone <- err
			return
		}
		defer connection.Close()
		_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
		if _, err := protocol.ReadFrame(connection); err != nil {
			serverDone <- err
			return
		}
		ready, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready", Capabilities: []string{hostPaneHealthCapability}})
		if err := protocol.NewWriter(connection).Write(ready); err != nil {
			serverDone <- err
			return
		}
		if _, err := protocol.ReadFrame(connection); err != nil {
			serverDone <- err
			return
		}
		close(started)
		_, err = protocol.ReadFrame(connection)
		serverDone <- err
	}()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	finished := make(chan error, 1)
	go func() {
		_, err := hostPaneHealthControllerRPC(ctx, socket, []byte(`{"action":"status"}`))
		finished <- err
	}()
	select {
	case <-started:
	case err := <-serverDone:
		t.Fatal("server could not admit the request", err)
	case <-time.After(3 * time.Second):
		t.Fatal("request was not admitted")
	}
	cancel()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatal("cancelled RPC did not preserve cancellation", err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled RPC waited for its 30-second socket deadline")
	}
	if err := <-serverDone; err == nil {
		t.Fatal("cancellation did not close the socket")
	}
}

func TestHostPaneHealthAdapterOutlivesClientButStopsWithSupervisor(t *testing.T) {
	lifetime, stop := context.WithCancel(context.Background())
	defer stop()
	s := newHostPaneHealthSupervisor(t.TempDir(), "unused")
	s.lifetime = lifetime
	started := make(chan context.Context, 1)
	adapterDone := make(chan struct{})
	s.command = func(ctx context.Context, operation string, request any) (json.RawMessage, error) {
		started <- ctx
		<-ctx.Done()
		close(adapterDone)
		return nil, ctx.Err()
	}
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	served := make(chan struct{})
	go func() { s.serve(server); close(served) }()
	if _, err := protocol.ReadFrame(client); err != nil {
		t.Fatal(err)
	}
	request := []byte(`{"v":1,"operation":"pane_health_controller","operation_id":"11111111111111111111111111111111","action":"status"}`)
	if err := protocol.NewWriter(client).Write(protocol.Frame{Type: protocol.HostRequest, Payload: request}); err != nil {
		t.Fatal(err)
	}
	var adapter context.Context
	select {
	case adapter = <-started:
	case <-time.After(time.Second):
		t.Fatal("adapter did not start")
	}
	_ = client.Close()
	if adapter.Err() != nil {
		t.Fatal("client disconnect cancelled durable processing", adapter.Err())
	}
	stop()
	select {
	case <-adapterDone:
	case <-time.After(time.Second):
		t.Fatal("supervisor shutdown did not cancel its adapter")
	}
	select {
	case <-served:
	case <-time.After(time.Second):
		t.Fatal("supervisor shutdown left an RPC serving goroutine")
	}
}

func TestHostPaneHealthOldSupervisorCannotReceiveAConfigurationOrCreateAWorker(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "relay-hh-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "old.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan error, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer connection.Close()
		frame, err := protocol.ReadFrame(connection)
		if err != nil {
			done <- err
			return
		}
		var hello protocol.HelloPayload
		if protocol.DecodeJSON(frame, &hello) != nil || !hello.Probe || hello.SessionID != "host-health-controller" {
			done <- os.ErrInvalid
			return
		}
		ready, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready", Capabilities: []string{"agent_binding_v1"}})
		if err := protocol.NewWriter(connection).Write(ready); err != nil {
			done <- err
			return
		}
		_ = connection.SetReadDeadline(time.Now().Add(time.Second))
		_, err = protocol.ReadFrame(connection)
		if err == nil {
			done <- os.ErrInvalid
			return
		}
		done <- nil
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if _, err := hostPaneHealthControllerRPC(ctx, socket, []byte(`{"action":"configure"}`)); err == nil || !strings.Contains(err.Error(), "does not support") {
		t.Fatal("old supervisor was treated as supporting health ownership", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestHostPaneHealthActorKeepsRunningAfterItsConfiguringClientDisconnects(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := newHostPaneHealthSupervisor(t.TempDir(), "unused")
	var configured atomic.Bool
	started := make(chan struct{}, 1)
	nativeCheck := make(chan struct{}, 1)
	s.command = func(ctx context.Context, operation string, request any) (json.RawMessage, error) {
		if operation == "configure" {
			configured.Store(true)
			return json.RawMessage(`{"v":1,"status":"controller_status","wake_controller":true}`), nil
		}
		if configured.Load() {
			nativeCheck <- struct{}{}
		} else {
			started <- struct{}{}
		}
		return json.RawMessage(`{"v":1,"next_check_seconds":-1}`), nil
	}
	stopped := make(chan struct{})
	go func() { s.run(ctx); close(stopped) }()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("host actor did not start")
	}
	server, client := net.Pipe()
	served := make(chan struct{})
	go func() { defer server.Close(); s.serve(server); close(served) }()
	if _, err := protocol.ReadFrame(client); err != nil {
		t.Fatal(err)
	}
	request := []byte(`{"v":1,"operation":"pane_health_controller","operation_id":"11111111111111111111111111111111","action":"configure","host_id":"owned-host","owner_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","enabled":true,"haiku_enabled":false,"panes":["11111111-2222-4333-8444-555555555555"]}`)
	if err := protocol.NewWriter(client).Write(protocol.Frame{Type: protocol.HostRequest, Payload: request}); err != nil {
		t.Fatal(err)
	}
	if _, err := protocol.ReadFrame(client); err != nil {
		t.Fatal(err)
	}
	client.Close()
	<-served
	select {
	case <-nativeCheck:
	case <-time.After(3 * time.Second):
		t.Fatal("host check depended on the configuring connection")
	}
	cancel()
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Fatal("host actor did not stop with its supervisor")
	}
}

func TestHostPaneHealthNativeAdapterUsesBoundedPipesAndPrivateDurableConfiguration(t *testing.T) {
	root := filepath.Join(t.TempDir(), "workers")
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	s := newHostPaneHealthSupervisor(root, executable)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	request := map[string]any{"v": 1, "operation": "configure", "operation_id": strings.Repeat("1", 32), "host_id": "owned-host",
		"owner_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "enabled": false, "haiku_enabled": false,
		"panes": []string{"11111111-2222-4333-8444-555555555555"}}
	for _, operation := range []string{"configure", "tick", "status"} {
		value := any(map[string]any{})
		if operation == "configure" {
			value = request
		}
		data, err := s.execute(ctx, operation, value)
		if err != nil {
			t.Fatal(operation, err)
		}
		var result struct {
			Status        string `json:"status"`
			Controller    string `json:"controller"`
			PID           int    `json:"supervisor_pid"`
			Configuration struct {
				Enabled bool   `json:"enabled"`
				Owner   string `json:"owner_id"`
			} `json:"configuration"`
		}
		if json.Unmarshal(data, &result) != nil || result.Status != "controller_status" || result.Controller != "relayd" ||
			result.PID != os.Getpid() || result.Configuration.Enabled || result.Configuration.Owner != request["owner_id"] {
			t.Fatalf("invalid native controller %s response: %.500s", operation, data)
		}
	}
	info, err := os.Lstat(filepath.Join(root, "pane-health-controller", "configuration.json"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("configuration not private", err)
	}
}

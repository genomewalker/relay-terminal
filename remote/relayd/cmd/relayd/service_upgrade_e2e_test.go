package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// TestServiceE2EFakeHTTP is the declared service the end-to-end test runs as
// a host job. Run directly it does nothing.
func TestServiceE2EFakeHTTP(t *testing.T) {
	address := os.Getenv("RELAY_E2E_SERVICE_ADDR")
	if address == "" {
		return
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM)
	listener, err := net.Listen("tcp", address)
	if err != nil {
		os.Exit(3)
	}
	if file, err := os.OpenFile(os.Getenv("RELAY_E2E_SERVICE_LOG"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
		fmt.Fprintf(file, "start %d\n", os.Getpid())
		file.Close()
	}
	go http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusUnauthorized) }))
	<-signals
	os.Exit(0)
}

func e2eHostCall(t *testing.T, socket string, request map[string]any) map[string]any {
	t.Helper()
	connection, err := net.DialTimeout("unix", socket, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(10 * time.Second))
	writer := protocol.NewWriter(connection)
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: 1, NodeMux: true})
	frame, _ := protocol.JSONFrame(protocol.HostRequest, request)
	if writer.Write(hello) != nil || writer.Write(frame) != nil {
		t.Fatal("host request not sent")
	}
	for {
		reply, err := protocol.ReadFrame(connection)
		if err != nil {
			t.Fatal(err)
		}
		if reply.Type != protocol.HostResponse {
			continue
		}
		var response map[string]any
		if json.Unmarshal(reply.Payload, &response) != nil || response["request_id"] != request["request_id"] {
			continue
		}
		return response
	}
}

func e2eJobState(t *testing.T, socket, jobID string) string {
	t.Helper()
	response := e2eHostCall(t, socket, map[string]any{"request_id": "e2e-status-" + strconv.FormatInt(time.Now().UnixNano(), 10), "operation": "status", "job_id": jobID})
	result, _ := response["result"].(map[string]any)
	job, _ := result["job"].(map[string]any)
	state, _ := job["state"].(string)
	return state
}

func e2eHealthy(port int) bool {
	client := &http.Client{Timeout: time.Second}
	response, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/health", port))
	if err != nil {
		return false
	}
	response.Body.Close()
	return response.StatusCode == http.StatusUnauthorized
}

// An old supervisor, a declared relay_exec service and the new relayd's
// upgrade-supervisor: --plan changes nothing, an undeclared job defers the
// upgrade by name, and once it is gone the service is stopped, the
// supervisor replaced and the service relaunched as svc-api-g1 and healthy.
func TestUpgradeSupervisorRelaunchesDeclaredService(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("relayd requires Unix sockets")
	}
	temporary := t.TempDir()
	oldBinary, newBinary := filepath.Join(temporary, "relayd-old"), filepath.Join(temporary, "relayd-new")
	buildTestRelayd(t, oldBinary, "0.5.1")
	buildTestRelayd(t, newBinary, "0.5.2")
	runtimeDir := newTestRuntime(t, "relay-svc-", temporary)
	stateHome := filepath.Join(temporary, "state")
	home := filepath.Join(temporary, "home")
	work := filepath.Join(temporary, "work")
	for _, directory := range []string{home, work} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	environment := append(os.Environ(), "XDG_RUNTIME_DIR="+runtimeDir, "XDG_STATE_HOME="+stateHome, "HOME="+home)
	socket := filepath.Join(runtimeDir, "relayd.sock")
	serviceLog := filepath.Join(temporary, "service.log")
	oldSupervisor, oldLog := startTestSupervisor(t, oldBinary, socket, environment)
	var newSupervisor int
	t.Cleanup(func() {
		if file, err := os.Open(serviceLog); err == nil {
			scanner := bufio.NewScanner(file)
			for scanner.Scan() {
				var pid int
				if _, err := fmt.Sscanf(scanner.Text(), "start %d", &pid); err == nil && pid > 1 {
					_ = syscall.Kill(-pid, syscall.SIGKILL)
				}
			}
			file.Close()
		}
		stopTestPID(newSupervisor)
		stopTestPID(oldSupervisor.Process.Pid)
	})
	relayd := func(arguments ...string) (string, error) {
		command := exec.Command(newBinary, arguments...)
		command.Env = environment
		output, err := command.CombinedOutput()
		return string(output), err
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	argv := []string{os.Args[0], "-test.run=^TestServiceE2EFakeHTTP$"}
	env := map[string]string{"RELAY_E2E_SERVICE_ADDR": fmt.Sprintf("127.0.0.1:%d", port), "RELAY_E2E_SERVICE_LOG": serviceLog, "RELAY_E2E_SECRET": "s3cr3t-e2e"}
	started := e2eHostCall(t, socket, map[string]any{"request_id": "e2e-exec-api", "operation": "exec", "job_id": "api-r1", "argv": argv, "cwd": work, "env": env})
	if started["error"] != nil {
		t.Fatalf("exec: %v", started["error"])
	}
	deadline := time.Now().Add(15 * time.Second)
	for !e2eHealthy(port) {
		if time.Now().After(deadline) {
			t.Fatalf("service never answered; supervisor log: %s", oldLog.String())
		}
		time.Sleep(100 * time.Millisecond)
	}

	declare := []string{"service", "declare", "api", "--job", "api-r1", "--cwd", work,
		"--health-tcp", strconv.Itoa(port), "--health-http-path", "/health", "--health-accept", "401,403,404", "--startup-grace", "20s"}
	for key, value := range env {
		declare = append(declare, "--env", key+"="+value)
	}
	declare = append(declare, "--")
	declare = append(declare, argv...)
	if output, err := relayd(declare...); err != nil || strings.Contains(output, "s3cr3t") {
		t.Fatalf("declare: %v\n%s", err, output)
	}

	output, err := relayd("upgrade-supervisor", "--plan", "--socket", socket, "--legacy-socket", "")
	if err != nil || !strings.Contains(output, "stop then relaunch: api (job api-r1") || !strings.Contains(output, "nothing was stopped") {
		t.Fatalf("plan: %v\n%s", err, output)
	}
	if e2eJobState(t, socket, "api-r1") != "running" {
		t.Fatal("--plan stopped the service")
	}

	blocker := e2eHostCall(t, socket, map[string]any{"request_id": "e2e-exec-notebook", "operation": "exec", "job_id": "notebook-r1", "argv": []string{"/bin/sleep", "60"}, "cwd": work})
	if blocker["error"] != nil {
		t.Fatalf("exec notebook: %v", blocker["error"])
	}
	output, err = relayd("upgrade-supervisor", "--socket", socket, "--legacy-socket", "")
	if err == nil || !strings.Contains(output, "notebook-r1 (pid ") || !strings.Contains(output, "nothing was stopped") {
		t.Fatalf("undeclared job did not defer by name: %v\n%s", err, output)
	}
	if e2eJobState(t, socket, "api-r1") != "running" || !e2eHealthy(port) {
		t.Fatal("a deferred upgrade disturbed the declared service")
	}
	e2eHostCall(t, socket, map[string]any{"request_id": "e2e-cancel-notebook", "operation": "cancel", "job_id": "notebook-r1"})
	for e2eJobState(t, socket, "notebook-r1") == "running" {
		time.Sleep(50 * time.Millisecond)
	}

	output, err = relayd("upgrade-supervisor", "--socket", socket, "--legacy-socket", "")
	if err != nil {
		t.Fatalf("upgrade: %v\n%s\nold supervisor log: %s", err, output, oldLog.String())
	}
	_, _ = oldSupervisor.Process.Wait()
	t.Logf("upgrade output:\n%s", output)
	if !strings.Contains(output, "upgraded to 0.5.2") || !strings.Contains(output, "svc-api-g1") || !strings.Contains(output, "healthy") ||
		strings.Contains(output, "s3cr3t") || strings.Contains(output, "test.run") {
		t.Fatalf("upgrade output:\n%s", output)
	}
	live, err := inspectSupervisorAt(t, newBinary, socket, environment)
	if err != nil {
		t.Fatal(err)
	}
	newSupervisor = live.PeerPID
	if live.Status.Version != "0.5.2" || newSupervisor == oldSupervisor.Process.Pid {
		t.Fatalf("supervisor = %+v", live.Status)
	}
	if e2eJobState(t, socket, "svc-api-g1") != "running" || !e2eHealthy(port) {
		t.Fatal("relaunched service is not running and healthy")
	}
	list, err := relayd("service", "list")
	if err != nil || !strings.Contains(list, "svc-api-g1") || !strings.Contains(list, "running") {
		t.Fatalf("list: %v\n%s", err, list)
	}
	logData, _ := os.ReadFile(serviceLog)
	if starts := strings.Count(string(logData), "start "); starts != 2 {
		t.Fatalf("service started %d times:\n%s", starts, logData)
	}
}

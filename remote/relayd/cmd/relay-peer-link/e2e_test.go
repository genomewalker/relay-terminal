package main

// Process-level successors of scripts/test-peer-link.py, test-peer-reconnect.py
// and fixtures/peer-worker.py. All registries, SSH transport and workers are
// disposable; no provider or real SSH connection is used.
import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func TestPeerWorkerFixture(t *testing.T) {
	if os.Getenv("RELAY_PEER_WORKER_FIXTURE") != "1" {
		return
	}
	name, home := os.Getenv("RELAY_FIXTURE_NAME"), os.Getenv("RELAY_FIXTURE_HOME")
	home, err := filepath.EvalSymlinks(home)
	if err != nil || (!strings.HasPrefix(home, "/tmp/") && !strings.HasPrefix(home, "/private/tmp/")) {
		os.Exit(2)
	}
	registry := filepath.Join(home, ".claude", "sessions")
	if os.MkdirAll(registry, 0700) != nil {
		os.Exit(2)
	}
	path := filepath.Join(home, "worker.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		os.Exit(2)
	}
	defer listener.Close()
	_ = os.Chmod(path, 0600)
	secretBytes := make([]byte, 16)
	if _, err := rand.Read(secretBytes); err != nil {
		os.Exit(2)
	}
	secret := hex.EncodeToString(secretBytes)
	pid := os.Getpid()
	cmd := exec.Command("/bin/ps", "-p", strconv.Itoa(pid), "-o", "lstart=")
	cmd.Env = append(os.Environ(), "TZ=UTC", "LC_ALL=C")
	start, err := cmd.Output()
	if err != nil {
		os.Exit(2)
	}
	record := map[string]any{"pid": pid, "name": "codex-" + name, "sessionId": name, "cwd": home, "procStart": strings.TrimSpace(string(start)), "messagingSocketPath": path}
	// Linux's kernel start counter is the protocol identity on that platform.
	if data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid)); err == nil {
		fields := strings.Fields(string(data)[strings.LastIndex(string(data), ")")+1:])
		record["procStart"] = fields[19]
	}
	write := func(path string, value any) {
		data, e := json.Marshal(value)
		if e != nil || os.WriteFile(path, data, 0600) != nil {
			os.Exit(2)
		}
	}
	keyPath := func(pid int, path string) string {
		return filepath.Join(registry, fmt.Sprintf("%d.%x.key", pid, sha256.Sum256([]byte(path))))
	}
	write(filepath.Join(registry, strconv.Itoa(pid)+".json"), record)
	write(keyPath(pid, path), map[string]string{"peerToken": secret})
	var output sync.Mutex
	emit := func(v any) { output.Lock(); defer output.Unlock(); _ = json.NewEncoder(os.Stdout).Encode(v) }
	go func() {
		for {
			connection, e := listener.Accept()
			if e != nil {
				return
			}
			func() {
				defer connection.Close()
				_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
				r := bufio.NewReaderSize(connection, 65537)
				a, e := r.ReadSlice('\n')
				if e != nil || len(a) > 65537 {
					return
				}
				var auth map[string]any
				if json.Unmarshal(a, &auth) != nil || auth["type"] != "auth" || auth["token"] != secret {
					return
				}
				data, e := r.ReadSlice('\n')
				if e != nil || len(data) > 65537 {
					return
				}
				sender, content, ok := peerFixtureEnvelope(data)
				if ok {
					emit(map[string]string{"sender": sender, "content": content})
				}
			}()
		}
	}()
	peers := func() []map[string]any {
		var result []map[string]any
		files, _ := filepath.Glob(filepath.Join(registry, "*.json"))
		for _, file := range files {
			data, e := os.ReadFile(file)
			if e != nil {
				continue
			}
			var v map[string]any
			if json.Unmarshal(data, &v) != nil {
				continue
			}
			n, ok := v["pid"].(float64)
			if !ok || int(n) == pid || syscall.Kill(int(n), 0) != nil {
				continue
			}
			p, ok := v["messagingSocketPath"].(string)
			if !ok {
				continue
			}
			if _, e := os.Stat(p); e != nil {
				continue
			}
			result = append(result, v)
		}
		return result
	}
	emit(map[string]bool{"ready": true})
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var request struct{ ID, Op, Recipient, Content string }
		if json.Unmarshal(scanner.Bytes(), &request) != nil {
			os.Exit(2)
		}
		reply := map[string]any{"id": request.ID}
		available := peers()
		if request.Op == "list" {
			reply["result"] = available
		} else if request.Op == "send" {
			reply["error"] = "peer unavailable"
			for _, target := range available {
				if target["name"] != request.Recipient {
					continue
				}
				targetPath := target["messagingSocketPath"].(string)
				data, e := os.ReadFile(keyPath(int(target["pid"].(float64)), targetPath))
				if e != nil {
					continue
				}
				var key map[string]string
				if json.Unmarshal(data, &key) != nil {
					continue
				}
				c, e := net.DialTimeout("unix", targetPath, 5*time.Second)
				if e != nil {
					continue
				}
				_ = c.SetDeadline(time.Now().Add(5 * time.Second))
				frames := []any{map[string]string{"type": "auth", "token": key["peerToken"]}, map[string]any{"type": "user", "msg_id": fmt.Sprint(time.Now().UnixNano()), "from": "uds:" + path, "message": map[string]string{"role": "user", "content": request.Content}}}
				e = nil
				for _, frame := range frames {
					if err := json.NewEncoder(c).Encode(frame); err != nil {
						e = err
						break
					}
				}
				c.Close()
				if e == nil {
					delete(reply, "error")
					reply["result"] = "sent"
				}
				break
			}
		} else {
			reply["error"] = "unknown operation"
		}
		emit(reply)
	}
	os.Exit(0)
}

func TestPeerSSHFixture(t *testing.T) {
	if os.Getenv("RELAY_PEER_SSH_FIXTURE") != "1" {
		return
	}
	if err := os.WriteFile(os.Getenv("RELAY_FIXTURE_PID_FILE"), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
		os.Exit(2)
	}
	var args []string
	if json.Unmarshal([]byte(os.Getenv("RELAY_FIXTURE_REMOTE_ARGS")), &args) != nil || len(args) == 0 {
		os.Exit(2)
	}
	if syscall.Exec(args[0], args, os.Environ()) != nil {
		os.Exit(2)
	}
}

type peerE2EProcess struct {
	cmd    *exec.Cmd
	in     io.WriteCloser
	lines  chan []byte
	done   chan error
	stderr bytes.Buffer
}

func peerE2EStart(t *testing.T, args []string, env []string, input io.Reader, output io.Writer) *peerE2EProcess {
	t.Helper()
	p := &peerE2EProcess{cmd: exec.Command(args[0], args[1:]...), lines: make(chan []byte, 128), done: make(chan error, 1)}
	p.cmd.Env = append(os.Environ(), env...)
	p.cmd.Stderr = &p.stderr
	if input == nil {
		var e error
		p.in, e = p.cmd.StdinPipe()
		if e != nil {
			t.Fatal(e)
		}
	} else {
		p.cmd.Stdin = input
	}
	if output == nil {
		out, e := p.cmd.StdoutPipe()
		if e != nil {
			t.Fatal(e)
		}
		go func() {
			s := bufio.NewScanner(out)
			s.Buffer(make([]byte, 4096), 1<<20)
			for s.Scan() {
				p.lines <- append([]byte(nil), s.Bytes()...)
			}
			close(p.lines)
		}()
	} else {
		p.cmd.Stdout = output
	}
	if e := p.cmd.Start(); e != nil {
		t.Fatal(e)
	}
	go func() { p.done <- p.cmd.Wait() }()
	t.Cleanup(func() {
		select {
		case <-p.done:
			return
		default:
		}
		_ = p.cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-p.done:
		case <-time.After(10 * time.Second):
			_ = p.cmd.Process.Kill()
			t.Errorf("fixture did not stop: %s", p.stderr.String())
		}
	})
	return p
}
func (p *peerE2EProcess) read(t *testing.T) map[string]any {
	t.Helper()
	select {
	case data, ok := <-p.lines:
		if !ok {
			t.Fatalf("process exited: %s", p.stderr.String())
		}
		var v map[string]any
		if json.Unmarshal(data, &v) != nil {
			t.Fatalf("bad fixture JSON %q", data)
		}
		return v
	case <-time.After(10 * time.Second):
		t.Fatalf("response timeout: %s", p.stderr.String())
	}
	return nil
}
func (p *peerE2EProcess) send(t *testing.T, op, recipient, content string) {
	t.Helper()
	if err := json.NewEncoder(p.in).Encode(map[string]string{"id": "request", "op": op, "recipient": recipient, "content": content}); err != nil {
		t.Fatal(err)
	}
}
func (p *peerE2EProcess) stop(t *testing.T) {
	t.Helper()
	_ = p.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-p.done:
		p.done <- nil
	case <-time.After(10 * time.Second):
		t.Fatalf("process did not stop: %s", p.stderr.String())
	}
}
func peerE2EFixture(t *testing.T) (string, string, []*peerE2EProcess) {
	t.Helper()
	root, e := os.MkdirTemp("/tmp", "relay-peer-go-")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	binary := filepath.Join(root, "relay-peer-link")
	build := exec.Command("go", "build", "-o", binary, ".")
	if out, e := build.CombinedOutput(); e != nil {
		t.Fatalf("build: %v %s", e, out)
	}
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	var workers []*peerE2EProcess
	for _, name := range []string{"a", "b"} {
		home := filepath.Join(root, name)
		if e := os.Mkdir(home, 0700); e != nil {
			t.Fatal(e)
		}
		p := peerE2EStart(t, []string{exe, "-test.run=^TestPeerWorkerFixture$"}, []string{"RELAY_PEER_WORKER_FIXTURE=1", "RELAY_FIXTURE_HOME=" + home, "RELAY_FIXTURE_NAME=" + name}, nil, nil)
		ready := p.read(t)
		if len(ready) != 1 || ready["ready"] != true {
			t.Fatal("worker not ready")
		}
		workers = append(workers, p)
	}
	return root, binary, workers
}
func peerE2EWait(t *testing.T, p *peerE2EProcess, check func() bool, timeout time.Duration) {
	t.Helper()
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		if check() {
			return
		}
		select {
		case err := <-p.done:
			p.done <- err
			t.Fatalf("supervisor exited: %v %s", err, p.stderr.String())
		case <-deadline.C:
			t.Fatal("link did not register/recover")
		case <-ticker.C:
		}
	}
}
func TestPeerLinkOriginalBidirectionalProcessContract(t *testing.T) {
	root, binary, workers := peerE2EFixture(t)
	fds, e := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if e != nil {
		t.Fatal(e)
	}
	streams := []*os.File{os.NewFile(uintptr(fds[0]), "a"), os.NewFile(uintptr(fds[1]), "b")}
	var links []*peerE2EProcess
	for i, name := range []string{"a", "b"} {
		p := peerE2EStart(t, []string{binary, "--serve", "--home", filepath.Join(root, name), "--name", "codex-" + name, "--session", name, "--pid", strconv.Itoa(workers[i].cmd.Process.Pid), "--label", name}, nil, streams[i], streams[i])
		links = append(links, p)
	}
	for _, s := range streams {
		s.Close()
	}
	a, b := workers[0], workers[1]
	peerE2EWait(t, links[0], func() bool {
		a.send(t, "list", "", "")
		list, _ := a.read(t)["result"].([]any)
		for _, v := range list {
			if v.(map[string]any)["name"] == "b--codex-b" {
				return true
			}
		}
		return false
	}, 10*time.Second)
	for i := 0; i < 20; i++ {
		request, reply := fmt.Sprintf("request-%d", i), fmt.Sprintf("reply-%d", i)
		a.send(t, "send", "b--codex-b", request)
		if a.read(t)["result"] != "sent" {
			t.Fatal("request not sent")
		}
		msg := b.read(t)
		if msg["sender"] != "a--codex-a" || msg["content"] != request {
			t.Fatalf("request attribution/content: %v", msg)
		}
		b.send(t, "send", msg["sender"].(string), reply)
		if b.read(t)["result"] != "sent" {
			t.Fatal("reply not sent")
		}
		msg = a.read(t)
		if msg["sender"] != "b--codex-b" || msg["content"] != reply {
			t.Fatalf("reply attribution/content: %v", msg)
		}
	}
	links[0].stop(t)
	links[1].stop(t)
	a.send(t, "list", "", "")
	if list, _ := a.read(t)["result"].([]any); len(list) != 0 {
		t.Fatal("offline proxy remained discoverable")
	}
	a.send(t, "send", "b--codex-b", "must not queue")
	if _, ok := a.read(t)["error"]; !ok {
		t.Fatal("offline send accepted")
	}
}
func TestPeerReconnectOriginalNoReplayProcessContract(t *testing.T) {
	root, binary, w := peerE2EFixture(t)
	a, b := w[0], w[1]
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	remote := []string{binary, "--serve", "--home", filepath.Join(root, "b"), "--name", "codex-b", "--session", "b", "--pid", strconv.Itoa(b.cmd.Process.Pid), "--label", "remote", "--expected-name", "local--codex-a", "--expected-session", "a"}
	args, _ := json.Marshal(remote)
	pidPath := filepath.Join(root, "remote.pid")
	ssh := filepath.Join(root, "ssh")
	script := "#!/bin/sh\nexec '" + strings.ReplaceAll(exe, "'", "'\\''") + "' -test.run='^TestPeerSSHFixture$'\n"
	if e := os.WriteFile(ssh, []byte(script), 0700); e != nil {
		t.Fatal(e)
	}
	link := peerE2EStart(t, []string{binary, "--home", filepath.Join(root, "a"), "--name", "codex-a", "--session", "a", "--pid", strconv.Itoa(a.cmd.Process.Pid), "--label", "local", "--host", "test-host", "--remote-name", "codex-b", "--remote-session", "b", "--remote-pid", strconv.Itoa(b.cmd.Process.Pid), "--remote-label", "remote", "--retries", "2"}, []string{"PATH=" + root + ":" + os.Getenv("PATH"), "RELAY_PEER_SSH_FIXTURE=1", "RELAY_FIXTURE_REMOTE_ARGS=" + string(args), "RELAY_FIXTURE_PID_FILE=" + pidPath}, nil, nil)
	status := filepath.Join(root, "a", ".local/state/relay/peer-network", strconv.Itoa(link.cmd.Process.Pid)+".json")
	waitOnline := func(attempt int) {
		peerE2EWait(t, link, func() bool {
			data, e := os.ReadFile(status)
			if e != nil {
				return false
			}
			var v statusFile
			return json.Unmarshal(data, &v) == nil && v.State == "online" && v.Attempt == attempt
		}, 15*time.Second)
	}
	waitOnline(0)
	a.send(t, "send", "remote--codex-b", "before")
	if a.read(t)["result"] != "sent" || b.read(t)["content"] != "before" {
		t.Fatal("pre-reconnect send failed")
	}
	data, e := os.ReadFile(pidPath)
	if e != nil {
		t.Fatal(e)
	}
	old, e := strconv.Atoi(string(data))
	if e != nil {
		t.Fatal(e)
	}
	if e := syscall.Kill(old, syscall.SIGTERM); e != nil {
		t.Fatal(e)
	}
	waitOnline(1)
	data, e = os.ReadFile(pidPath)
	if e != nil || string(data) == strconv.Itoa(old) {
		t.Fatal("remote helper incarnation did not change")
	}
	select {
	case msg := <-b.lines:
		t.Fatalf("replayed old message: %s", msg)
	case <-time.After(200 * time.Millisecond):
	}
	a.send(t, "send", "remote--codex-b", "after")
	if a.read(t)["result"] != "sent" {
		t.Fatal("post-reconnect send failed")
	}
	msg := b.read(t)
	if msg["content"] != "after" || msg["sender"] != "local--codex-a" {
		t.Fatalf("post-reconnect attribution: %v", msg)
	}
	b.send(t, "send", msg["sender"].(string), "recovered")
	if b.read(t)["result"] != "sent" || a.read(t)["content"] != "recovered" {
		t.Fatal("bidirectional reconnect failed")
	}
	link.stop(t)
	data, e = os.ReadFile(status)
	var v statusFile
	if e != nil || json.Unmarshal(data, &v) != nil || v.State != "stopped" {
		t.Fatalf("stopped status missing: %s %v", data, e)
	}
}

func peerFixtureEnvelope(data []byte) (string, string, bool) {
	if len(data) > 65537 {
		return "", "", false
	}
	var message struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal(data, &message) != nil {
		return "", "", false
	}
	match := regexp.MustCompile(`(?s)^<cross-session-message[^>]*from-name="([^"]+)"[^>]*>\n(.*)\n</cross-session-message>$`).FindStringSubmatch(message.Message.Content)
	if match == nil {
		return "", "", false
	}
	return match[1], match[2], true
}

func FuzzPeerWorkerEnvelope(f *testing.F) {
	oversized, _ := json.Marshal(map[string]any{"message": map[string]string{"content": "<cross-session-message from-name=\"fixture\">\n" + strings.Repeat("x", 65538) + "\n</cross-session-message>"}})
	f.Add(oversized)
	f.Add([]byte("hello"))
	f.Add([]byte("\xff\n</cross-session-message>"))
	f.Add([]byte{})
	f.Fuzz(func(t *testing.T, data []byte) {
		sender, body, ok := peerFixtureEnvelope(data)
		if ok {
			if len(data) > 65537 || !json.Valid(data) || sender == "" || len(sender)+len(body) > 65537 {
				t.Fatal("fixture envelope escaped bounds")
			}
			trimmed := bytes.TrimSpace(data)
			if len(trimmed) > 0 {
				if _, _, accepted := peerFixtureEnvelope(trimmed[:len(trimmed)-1]); accepted {
					t.Fatal("accepted truncated fixture JSON")
				}
			}
		}
		if len(data) > 32768 {
			return
		}
		raw, _ := json.Marshal(map[string]any{"message": map[string]string{"content": "<cross-session-message from-name=\"fixture\">\n" + string(data) + "\n</cross-session-message>"}})
		if len(raw) > 65537 {
			return
		}
		var normalized struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(raw, &normalized) != nil {
			t.Fatal("fixture marshal invalid")
		}
		expected := strings.TrimSuffix(strings.TrimPrefix(normalized.Message.Content, "<cross-session-message from-name=\"fixture\">\n"), "\n</cross-session-message>")
		sender, body, ok = peerFixtureEnvelope(raw)
		if !ok || sender != "fixture" || body != expected {
			t.Fatal("fixture envelope roundtrip changed")
		}
	})
}

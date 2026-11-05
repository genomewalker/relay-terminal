//go:build linux || darwin

package nativemsg

import (
	"bufio"
	"bytes"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// The test binary doubles as the fixtures' fake processes: a fake relayd for
// the Python oracle's `--daemon`, and fake Claude and Codex agents whose
// inboxes record what they receive.
func TestMain(m *testing.M) {
	switch os.Getenv("NATIVEMSG_HELPER") {
	case "daemon":
		os.Exit(fakeDaemon(os.Args[1:]))
	case "agent":
		runAgent(os.Args[1:])
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// fixtureBinding is what `relayd agent-binding` prints for this fixture: the
// file binding[-SESSION].json, served for at most the count in binding.limit.
// A missing file is relayd's exit 1; "CRASH" is a relayd crash.
func fixtureBinding(dir, pane, session string) ([]byte, error) {
	name := "binding.json"
	if session != "" {
		name = "binding-" + session + ".json"
	}
	if limit, err := os.ReadFile(filepath.Join(dir, "binding.limit")); err == nil {
		max, _ := strconv.Atoi(strings.TrimSpace(string(limit)))
		count := 0
		if data, err := os.ReadFile(filepath.Join(dir, "binding.count")); err == nil {
			count, _ = strconv.Atoi(strings.TrimSpace(string(data)))
		}
		count++
		os.WriteFile(filepath.Join(dir, "binding.count"), []byte(strconv.Itoa(count)), 0o600)
		if count > max {
			if _, err := os.Stat(filepath.Join(dir, "binding.after.json")); err == nil {
				name = "binding.after.json"
			} else {
				return nil, fmt.Errorf("binding withdrawn")
			}
		}
	}
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return nil, err
	}
	if string(data) == "CRASH" {
		panic("fixture relayd crash")
	}
	return data, nil
}

// fixtureInboundClass is `relayd peer-inbound-class`: the class in the file
// inbound, or unknown.
func fixtureInboundClass(dir string) string {
	data, _ := os.ReadFile(filepath.Join(dir, "inbound"))
	return strings.TrimSpace(string(data))
}

func fakeDaemon(args []string) int {
	dir := os.Getenv("NATIVEMSG_FIXTURE")
	switch {
	case len(args) >= 2 && args[0] == "agent-binding":
		session := ""
		if len(args) == 4 && args[2] == "--session" {
			session = args[3]
		}
		var data []byte
		var err error
		func() {
			defer func() {
				if recover() != nil {
					os.Exit(2)
				}
			}()
			data, err = fixtureBinding(dir, args[1], session)
		}()
		if err != nil {
			fmt.Fprintln(os.Stderr, "relayd:", err)
			return 1
		}
		os.Stdout.Write(data)
		return 0
	case len(args) == 3 && args[0] == "peer-inbound-class":
		if _, err := strconv.Atoi(args[1]); err != nil {
			return 1
		}
		class := fixtureInboundClass(dir)
		reason := ""
		if class == "" {
			reason = "unknown"
		}
		json.NewEncoder(os.Stdout).Encode(map[string]string{"class": class, "reason": reason})
		return 0
	}
	return 1
}

// codexConfig scripts a fake Codex app-server.
type codexConfig struct {
	Loaded        [][]any        `json:"loaded"`
	Thread        any            `json:"thread"`
	Turn          any            `json:"turn"`
	ServerRequest bool           `json:"serverRequest"`
	Ping          bool           `json:"ping"`
	BadAccept     bool           `json:"badAccept"`
	Status        string         `json:"status"`
	RejectMethod  string         `json:"rejectMethod"`
	Results       map[string]any `json:"results"`
}

func runAgent(args []string) {
	flags := flag.NewFlagSet("agent", flag.ExitOnError)
	socket := flags.String("socket", "", "inbox socket")
	mode := flags.String("mode", "claude", "claude inbox or codex app-server")
	record := flags.String("record", "", "directory recording each connection")
	ready := flags.String("ready", "", "file written when listening")
	config := flags.String("config", "", "codex app-server script")
	zombie := flags.String("zombie-child", "", "start this program and never reap it")
	var opens multiFlag
	flags.Var(&opens, "open", "file held open")
	flags.Parse(args)
	syscall.Umask(0o077)
	var held []*os.File // open for the agent's lifetime
	for _, name := range opens {
		f, err := os.Open(name)
		if err != nil {
			fmt.Fprintln(os.Stderr, "agent:", err)
			os.Exit(3)
		}
		held = append(held, f)
	}
	if *zombie != "" {
		// The child exits at once; this process never waits for it.
		var attr syscall.ProcAttr
		attr.Env = []string{}
		if _, err := syscall.ForkExec(*zombie, []string{*zombie, "-test.run=^$"}, &attr); err != nil {
			os.Exit(4)
		}
	}
	var listener net.Listener
	if *socket != "" {
		var err error
		if listener, err = net.Listen("unix", *socket); err != nil {
			fmt.Fprintln(os.Stderr, "agent:", err)
			os.Exit(5)
		}
	}
	if *ready != "" {
		os.WriteFile(*ready+".tmp", []byte(fmt.Sprintf("%d %d\n", os.Getpid(), os.Getppid())), 0o600)
		os.Rename(*ready+".tmp", *ready)
	}
	parent := os.Getppid()
	go func() {
		// Never outlive the fixture: stop when the parent shell is gone.
		for start := time.Now(); time.Since(start) < 15*time.Minute; time.Sleep(200 * time.Millisecond) {
			if os.Getppid() != parent {
				break
			}
		}
		os.Exit(0)
	}()
	if listener == nil {
		select {}
	}
	var counter int
	var mu sync.Mutex
	for {
		conn, err := listener.Accept()
		if err != nil {
			os.Exit(0)
		}
		mu.Lock()
		counter++
		n := counter
		mu.Unlock()
		go func() {
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(20 * time.Second))
			name := filepath.Join(*record, fmt.Sprintf("%s-%03d", filepath.Base(*socket), n))
			if *mode == "codex" {
				serveCodex(conn, name, *config)
				return
			}
			data, _ := io.ReadAll(conn)
			os.WriteFile(name, data, 0o600)
		}()
	}
}

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

// serveCodex is an independent RFC 6455 server: it requires masked client
// frames and records every text message.
func serveCodex(conn net.Conn, name, configPath string) {
	var config codexConfig
	if data, err := os.ReadFile(configPath); err == nil {
		json.Unmarshal(data, &config)
	}
	var log bytes.Buffer
	defer func() { os.WriteFile(name, log.Bytes(), 0o600) }()
	reader := bufio.NewReader(conn)
	request, err := http.ReadRequest(reader)
	if err != nil {
		fmt.Fprintf(&log, "BAD-REQUEST %v\n", err)
		return
	}
	key := request.Header.Get("Sec-WebSocket-Key")
	fmt.Fprintf(&log, "HANDSHAKE %s %s %s %s\n", request.Method, request.URL, request.Header.Get("Upgrade"), request.Header.Get("Sec-WebSocket-Version"))
	digest := sha1.Sum([]byte(key + websocketGUID))
	accept := base64.StdEncoding.EncodeToString(digest[:])
	if config.BadAccept {
		accept = "x" + accept
	}
	status := config.Status
	if status == "" {
		status = "101 Switching Protocols"
	}
	fmt.Fprintf(conn, "HTTP/1.1 %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", status, accept)
	write := func(opcode byte, payload []byte) {
		frame := []byte{0x80 | opcode}
		switch {
		case len(payload) < 126:
			frame = append(frame, byte(len(payload)))
		case len(payload) < 65536:
			frame = append(frame, 126)
			frame = binary.BigEndian.AppendUint16(frame, uint16(len(payload)))
		default:
			frame = append(frame, 127)
			frame = binary.BigEndian.AppendUint64(frame, uint64(len(payload)))
		}
		conn.Write(append(frame, payload...))
	}
	reply := func(id any, result any) {
		data, _ := json.Marshal(map[string]any{"id": id, "result": result})
		write(1, data)
	}
	for {
		head := make([]byte, 2)
		if _, err := io.ReadFull(reader, head); err != nil {
			return
		}
		if head[1]&0x80 == 0 {
			fmt.Fprintf(&log, "UNMASKED\n")
			return
		}
		length := uint64(head[1] & 127)
		switch length {
		case 126:
			b := make([]byte, 2)
			io.ReadFull(reader, b)
			length = uint64(binary.BigEndian.Uint16(b))
		case 127:
			b := make([]byte, 8)
			io.ReadFull(reader, b)
			length = binary.BigEndian.Uint64(b)
		}
		mask := make([]byte, 4)
		io.ReadFull(reader, mask)
		payload := make([]byte, length)
		if _, err := io.ReadFull(reader, payload); err != nil {
			return
		}
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
		opcode := head[0] & 15
		fmt.Fprintf(&log, "FRAME fin=%d opcode=%d %s\n", head[0]>>7, opcode, payload)
		if opcode != 1 {
			continue
		}
		var message map[string]any
		if json.Unmarshal(payload, &message) != nil {
			continue
		}
		id, method := message["id"], message["method"]
		if id == nil || method == nil {
			continue
		}
		if config.Ping {
			write(9, []byte("ping"))
			write(10, []byte("pong"))
		}
		if config.ServerRequest {
			write(1, []byte(`{"id":"server-1","method":"item/commandExecution/requestApproval","params":{}}`))
			write(1, []byte(`{"method":"thread/started","params":{}}`))
		}
		if method == config.RejectMethod {
			data, _ := json.Marshal(map[string]any{"id": id, "error": map[string]any{"code": 1, "message": "no"}})
			write(1, data)
			continue
		}
		if result, ok := config.Results[method.(string)]; ok {
			reply(id, result)
			continue
		}
		switch method {
		case "initialize":
			reply(id, map[string]any{"userAgent": "fake"})
		case "thread/loaded/list":
			page := 0
			if params, ok := message["params"].(map[string]any); ok {
				if cursor, ok := params["cursor"].(string); ok {
					page, _ = strconv.Atoi(strings.TrimPrefix(cursor, "page-"))
				}
			}
			result := map[string]any{"data": []any{}}
			if page < len(config.Loaded) {
				result["data"] = config.Loaded[page]
			}
			if page+1 < len(config.Loaded) {
				result["nextCursor"] = fmt.Sprintf("page-%d", page+1)
			}
			// A fragmented reply exercises continuation frames.
			data, _ := json.Marshal(map[string]any{"id": id, "result": result})
			half := len(data) / 2
			conn.Write(append([]byte{0x01, byte(half)}, data[:half]...))
			rest := data[half:]
			conn.Write(append([]byte{0x80, byte(len(rest))}, rest...))
		case "thread/read":
			reply(id, map[string]any{"thread": config.Thread})
		case "turn/start":
			reply(id, map[string]any{"turn": config.Turn})
		default:
			data, _ := json.Marshal(map[string]any{"id": id, "error": map[string]any{"code": -32601, "message": "unknown"}})
			write(1, data)
		}
	}
}

// fixture is one pane's live process tree and the files describing it.
type fixture struct {
	t             *testing.T
	dir           string
	pane          string
	env           map[string]string
	bin           string
	pids          map[string]int
	starts        map[string]string
	shell         int
	worker        int
	children      []*os.Process
	referenceCall int
}

// shortTempDir keeps Unix socket paths within sun_path.
func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "n")
	if err != nil {
		t.Fatal(err)
	}
	dir, _ = filepath.EvalSymlinks(dir)
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func TestFixtureSocketPathsDoNotInheritLongTMPDIR(t *testing.T) {
	long := filepath.Join(t.TempDir(), strings.Repeat("ambient-tmp-", 10))
	if err := os.Mkdir(long, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", long)
	dir := shortTempDir(t)
	path := filepath.Join(dir, "codex", "app-server-control", "fixture-native.sock")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("ambient TMPDIR prevented bounded fixture socket: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	dir := shortTempDir(t)
	f := &fixture{t: t, dir: dir, pane: "7d85fd72-64ec-46a4-8591-567bf64f7c93", pids: map[string]int{}, starts: map[string]string{}}
	for _, sub := range []string{"home", "state/relay/workers", "claude/sessions", "claude/projects/p", "codex/sessions/2026",
		"codex/app-server-control", "s", "rec", "fix", "bin"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	f.bin = self
	for _, name := range []string{"claude", "codex", "holder"} {
		if err := os.Symlink(self, filepath.Join(dir, "bin", name)); err != nil {
			t.Fatal(err)
		}
	}
	f.env = map[string]string{"HOME": f.path("home"), "XDG_STATE_HOME": f.path("state")}
	f.checkReferenceCount(t)
	return f
}

func (f *fixture) path(name string) string { return filepath.Join(f.dir, name) }

func (f *fixture) write(name string, value any) {
	f.t.Helper()
	var data []byte
	switch v := value.(type) {
	case string:
		data = []byte(v)
	case []byte:
		data = v
	default:
		data, _ = json.Marshal(v)
	}
	path := f.path(name)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		f.t.Fatal(err)
	}
	os.Chmod(path, 0o600)
}

// agentSpec is one fake agent process started under the pane's shell (or,
// detached, outside the pane).
type agentSpec struct {
	name    string // fixture key
	program string // path executed: bin/claude, bin/codex or a copy
	args    []string
	env     map[string]string
}

// start runs worker -> shell -> agents (and detached agents with their own
// shell). It waits until every agent reports ready.
func (f *fixture) start(agents []agentSpec, detached []agentSpec) {
	f.t.Helper()
	script := func(name string, specs []agentSpec) string {
		var b strings.Builder
		b.WriteString("#!/bin/sh\n")
		for _, spec := range specs {
			for key, value := range spec.env {
				fmt.Fprintf(&b, "%s='%s' ", key, value)
			}
			fmt.Fprintf(&b, "NATIVEMSG_HELPER=agent '%s'", spec.program)
			for _, arg := range append(spec.args, "--ready", f.path("rec/ready-"+spec.name)) {
				fmt.Fprintf(&b, " '%s'", arg)
			}
			b.WriteString(" &\n")
		}
		b.WriteString("wait\n")
		f.write("fix/"+name+".sh", b.String())
		return f.path("fix/" + name + ".sh")
	}
	shell := script("shell", agents)
	f.write("fix/worker.sh", fmt.Sprintf("#!/bin/sh\n/bin/sh '%s' &\nwait\n", shell))
	launch := func(path string) *os.Process {
		cmd := exec.Command("/bin/sh", path)
		cmd.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + f.path("home")}
		if err := cmd.Start(); err != nil {
			f.t.Fatal(err)
		}
		f.children = append(f.children, cmd.Process)
		go cmd.Wait()
		return cmd.Process
	}
	f.t.Cleanup(f.stop)
	worker := launch(f.path("fix/worker.sh"))
	f.worker = worker.Pid
	if len(detached) > 0 {
		launch(script("detached", detached))
	}
	for _, spec := range append(append([]agentSpec{}, agents...), detached...) {
		pid, ppid := f.waitReady(spec.name)
		f.pids[spec.name] = pid
		f.starts[spec.name] = f.startOf(pid)
		if containsSpec(agents, spec.name) {
			f.shell = ppid
		}
	}
	f.starts["worker"] = f.startOf(f.worker)
	f.starts["shell"] = f.startOf(f.shell)
}

func containsSpec(specs []agentSpec, name string) bool {
	for _, spec := range specs {
		if spec.name == name {
			return true
		}
	}
	return false
}

func (f *fixture) waitReady(name string) (int, int) {
	f.t.Helper()
	path := f.path("rec/ready-" + name)
	for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var pid, ppid int
		if _, err := fmt.Sscanf(string(data), "%d %d", &pid, &ppid); err == nil {
			return pid, ppid
		}
	}
	f.t.Fatalf("agent %s never became ready", name)
	return 0, 0
}

// startOf is the part of the adapter's process identity after "linux:" or
// "darwin:", which session registries publish as procStart.
func (f *fixture) startOf(pid int) string {
	identity, err := defaultSource().identity(int64(pid))
	if err != nil {
		f.t.Fatalf("identity of %d: %v", pid, err)
	}
	_, after, _ := strings.Cut(identity, ":")
	return after
}

// stop ends exactly the processes this fixture started: the agents by their
// reported PIDs, then the shells.
func (f *fixture) stop() {
	for _, pid := range f.pids {
		if pid > 1 {
			syscall.Kill(pid, syscall.SIGKILL)
		}
	}
	if f.shell > 1 {
		syscall.Kill(f.shell, syscall.SIGKILL)
	}
	for _, process := range f.children {
		process.Kill()
	}
}

// workerRecord publishes the pane's durable worker.
func (f *fixture) workerRecord(overrides map[string]any) {
	start, _ := strconv.ParseInt(f.starts["worker"], 10, 64)
	record := map[string]any{"session_id": f.pane, "state": "running", "worker_pid": f.worker, "shell_pid": f.shell,
		"worker_start_time": start}
	if start == 0 {
		record["worker_start_time"] = f.starts["worker"]
	}
	for key, value := range overrides {
		if value == nil {
			delete(record, key)
		} else {
			record[key] = value
		}
	}
	f.write("state/relay/workers/"+f.pane+".json", record)
}

// claudeSession publishes a Claude process's session record and inbox key.
func (f *fixture) claudeSession(name, session, socket string, overrides map[string]any) {
	pid := f.pids[name]
	row := map[string]any{"pid": pid, "sessionId": session, "procStart": f.procStart(name), "kind": "interactive",
		"entrypoint": "cli", "peerProtocol": 1}
	if socket != "" {
		row["messagingSocketPath"] = socket
	}
	for key, value := range overrides {
		if value == nil {
			delete(row, key)
		} else {
			row[key] = value
		}
	}
	f.write(fmt.Sprintf("claude/sessions/%d.json", pid), row)
	if socket != "" {
		sum := sha256.Sum256([]byte(socket))
		f.write(fmt.Sprintf("claude/sessions/%d.%s.key", pid, hex.EncodeToString(sum[:])),
			map[string]any{"peerToken": "token-0123456789abcdef"})
	}
}

// procStart is how Claude publishes its process start: the Linux tick count
// as a number, the Darwin ps lstart text as a string.
func (f *fixture) procStart(name string) any {
	start := f.starts[name]
	if n, err := strconv.ParseInt(start, 10, 64); err == nil {
		return n
	}
	return start
}

func (f *fixture) socketIdentity(path string) string {
	info, err := os.Lstat(path)
	if err != nil {
		f.t.Fatal(err)
	}
	return devIno(statT(info))
}

// records lists what an inbox received, connection by connection.
func (f *fixture) records(prefix string) []string {
	matches, _ := filepath.Glob(filepath.Join(f.path("rec"), prefix+"-*"))
	var result []string
	for _, match := range matches {
		data, _ := os.ReadFile(match)
		result = append(result, string(data))
	}
	return result
}

func (f *fixture) clearRecords() {
	matches, _ := filepath.Glob(filepath.Join(f.path("rec"), "*.sock-*"))
	for _, match := range matches {
		os.Remove(match)
	}
}

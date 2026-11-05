package nativechat

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const MaxTransportBytes = 24 << 20
const MaxImageBytes = 4 << 20

// Kernel supplies platform process-incarnation and socket-peer checks. They are
// actual host observations, never reconstructed from a saved conversation.
type Kernel struct {
	ProcessGone     func(int, string) (bool, error)
	ProcessStart    func(int) (string, error)
	PeerCredentials func(net.Conn) (int, int, error)
}
type RunConfig struct {
	Identity    Identity
	Provider    ProviderOptions
	Executable  string
	Arguments   []string
	Environment []string
	Root        string
	Kernel      Kernel
}
type Descriptor struct {
	Version       int      `json:"version"`
	Identity      Identity `json:"identity"`
	PID           int      `json:"pid"`
	ProcessStart  string   `json:"processStart"`
	ProviderPID   int      `json:"providerPid"`
	ProviderStart string   `json:"providerStart"`
	Socket        string   `json:"socket"`
}
type RPCRequest struct {
	Operation     string   `json:"operation"`
	Identity      Identity `json:"identity"`
	Action        *Action  `json:"action,omitempty"`
	AfterRevision uint64   `json:"afterRevision,omitempty"`
	WaitMillis    int      `json:"waitMillis,omitempty"`
	Before        uint64   `json:"before,omitempty"`
	ImageData     []byte   `json:"imageData,omitempty"`
	ReceiptID     string   `json:"receiptId,omitempty"`
}
type RPCResponse struct {
	Snapshot  *Snapshot `json:"snapshot,omitempty"`
	Receipt   *Receipt  `json:"receipt,omitempty"`
	ImagePath string    `json:"imagePath,omitempty"`
	Error     string    `json:"error,omitempty"`
}
type itemRecord = ItemUpdate
type worker struct {
	mu         sync.Mutex
	writeMu    sync.Mutex
	state      *State
	driver     *Driver
	input      io.WriteCloser
	directory  string
	changed    chan struct{}
	inputHeld  bool
	kernel     Kernel
	descriptor Descriptor
	items      *os.File
	actions    *os.File
}

func privateDirectory(path string) error {
	if e := os.MkdirAll(path, 0700); e != nil {
		return e
	}
	info, e := os.Lstat(path)
	if e != nil {
		return e
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || info.Mode().Perm()&0077 != 0 || int(stat.Uid) != os.Getuid() {
		return errors.New("native conversation directory must be private and owned")
	}
	return nil
}
func instanceDirectory(root string, id Identity) (string, error) {
	if !id.Valid() || !filepath.IsAbs(root) {
		return "", errors.New("invalid native conversation location")
	}
	return filepath.Join(root, "native-chat", id.Pane, id.Instance), nil
}
func atomicJSON(path string, value any) error {
	b, e := json.Marshal(value)
	if e != nil {
		return e
	}
	dir := filepath.Dir(path)
	f, e := os.CreateTemp(dir, ".native-")
	if e != nil {
		return e
	}
	name := f.Name()
	defer os.Remove(name)
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(append(b, '\n'))
	}
	if e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e == nil {
		e = closeErr
	}
	if e != nil {
		return e
	}
	if e = os.Rename(name, path); e != nil {
		return e
	}
	directory, e := os.Open(dir)
	if e != nil {
		return e
	}
	defer directory.Close()
	return directory.Sync()
}
func privateRead(path string, limit int) ([]byte, error) {
	f, e := os.OpenFile(path, os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	info, e := f.Stat()
	if e != nil {
		return nil, e
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || int(stat.Uid) != os.Getuid() || info.Size() > int64(limit) {
		return nil, errors.New("native conversation record is not private or bounded")
	}
	b, e := io.ReadAll(io.LimitReader(f, int64(limit)+1))
	if len(b) > limit {
		return nil, errors.New("native conversation record exceeds size limit")
	}
	return b, e
}
func readFrame(r io.Reader, limit int) ([]byte, error) {
	reader := bufio.NewReaderSize(r, 4096)
	var data []byte
	for {
		part, e := reader.ReadSlice('\n')
		if len(data)+len(part) > limit {
			return nil, errors.New("native protocol frame exceeds size limit")
		}
		data = append(data, part...)
		if e == nil {
			return bytes.TrimSuffix(data, []byte{'\n'}), nil
		}
		if e != bufio.ErrBufferFull {
			return nil, e
		}
	}
}
func DecodeRPC(data []byte) (RPCRequest, error) {
	var r RPCRequest
	if _, e := DecodeObject(data, MaxTransportBytes); e != nil {
		return r, e
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if e := decoder.Decode(&r); e != nil {
		return r, e
	}
	if !r.Identity.Valid() || r.WaitMillis < 0 || r.WaitMillis > 15000 {
		return r, errors.New("invalid native request identity or wait")
	}
	switch r.Operation {
	case "snapshot":
		if r.Action != nil || len(r.ImageData) != 0 || r.ReceiptID != "" {
			return r, errors.New("snapshot cannot contain a mutation")
		}
	case "action":
		if r.Action == nil || r.Action.Identity != r.Identity || len(r.ImageData) != 0 || r.Before != 0 || r.WaitMillis != 0 || r.AfterRevision != 0 || r.ReceiptID != "" {
			return r, errors.New("invalid native action envelope")
		}
	case "receipt":
		if !validID(r.ReceiptID) || r.Action != nil || len(r.ImageData) != 0 || r.Before != 0 || r.WaitMillis != 0 || r.AfterRevision != 0 {
			return r, errors.New("invalid receipt request")
		}
	case "image":
		if len(r.ImageData) == 0 || len(r.ImageData) > MaxImageBytes || r.Action != nil || r.Before != 0 || r.WaitMillis != 0 || r.AfterRevision != 0 || r.ReceiptID != "" {
			return r, errors.New("invalid image request")
		}
	default:
		return r, errors.New("unsupported native operation")
	}
	// Canonical empty optional collections must survive decode/encode unchanged.
	if len(r.ImageData) == 0 {
		r.ImageData = nil
	}
	if r.Action != nil {
		if len(r.Action.Images) == 0 {
			r.Action.Images = nil
		}
		if len(r.Action.Answers) == 0 {
			r.Action.Answers = nil
		}
	}
	return r, nil
}
func (w *worker) signal() { close(w.changed); w.changed = make(chan struct{}) }
func (w *worker) view() Snapshot {
	v := w.state.Snapshot()
	if w.inputHeld {
		v.Phase = "held"
		v.Capabilities.Send = false
		v.Capabilities.Respond = false
		v.Capabilities.Interrupt = false
		v.Capabilities.Steer = false
	}
	return boundedSnapshot(v)
}
func boundedSnapshot(v Snapshot) Snapshot {
	// Encode metadata once and each retained item once, rather than repeatedly
	// marshalling a shrinking multi-megabyte history on every stream update.
	items := v.Items
	v.Items = []Item{}
	v.Failure = boundedDetail(v.Failure)
	metadata, _ := json.Marshal(v)
	budget := (2 << 20) - len(metadata) - 4096
	start := len(items)
	for start > 0 {
		encoded, _ := json.Marshal(items[start-1])
		if len(encoded)+1 > budget {
			break
		}
		budget -= len(encoded) + 1
		start--
	}
	if start == len(items) && len(items) > 0 {
		last := items[len(items)-1]
		v.Items = []Item{{ID: last.ID, Role: last.Role, Sequence: last.Sequence, Text: "[Message exceeds display budget]", Truncated: true}}
		v.OlderBefore = last.Sequence
	} else {
		v.Items = items[start:]
		if start > 0 {
			v.OlderBefore = v.Items[0].Sequence
		}
	}
	return v
}
func (w *worker) persistView() error {
	return atomicJSON(filepath.Join(w.directory, "snapshot.json"), w.view())
}
func (w *worker) appendItems() error {
	for _, update := range w.state.historyChanges {
		b, e := json.Marshal(update)
		if e != nil {
			return e
		}
		if _, e = w.items.Write(append(b, '\n')); e != nil {
			return e
		}
	}
	w.state.historyChanges = nil
	return nil
}
func (w *worker) persistReceipt(r Receipt) error {
	b, e := json.Marshal(r)
	if e != nil {
		return e
	}
	if _, e = w.actions.Write(append(b, '\n')); e != nil {
		return e
	}
	return w.actions.Sync()
}
func (w *worker) write(frame []byte) error {
	if len(frame) > MaxTransportBytes {
		return errors.New("provider input exceeds size limit")
	}
	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	if f, ok := w.input.(*os.File); ok {
		if e := f.SetWriteDeadline(time.Now().Add(10 * time.Second)); e != nil {
			return e
		}
		defer f.SetWriteDeadline(time.Time{})
	}
	data := append(append([]byte(nil), frame...), '\n')
	n, e := w.input.Write(data)
	if e == nil && n != len(data) {
		e = io.ErrShortWrite
	}
	return e
}
func copyView(v Snapshot) Snapshot {
	v.Items = append([]Item(nil), v.Items...)
	v.Requests = append([]Request(nil), v.Requests...)
	return v
}
func (w *worker) action(a Action) RPCResponse {
	w.mu.Lock()
	if w.inputHeld {
		v := w.view()
		w.mu.Unlock()
		return RPCResponse{Snapshot: &v, Error: "A previous provider write has an unknown outcome. It was not replayed."}
	}
	// Validate/read immutable uploaded images before claiming any provider work.
	imageBlocks, e := w.imageBlocks(a.Images)
	if e != nil {
		w.mu.Unlock()
		return RPCResponse{Error: e.Error()}
	}
	before := copyView(w.state.View)
	receipt, fresh, e := w.state.Claim(a)
	if e != nil {
		w.mu.Unlock()
		return RPCResponse{Error: e.Error()}
	}
	if !fresh {
		v := w.view()
		w.mu.Unlock()
		return RPCResponse{Snapshot: &v, Receipt: &receipt}
	}
	commandAction := a
	if w.state.View.Identity.Provider == "claude" {
		commandAction.Images = nil
	}
	frame, e := w.driver.Command(commandAction)
	if e == nil && len(imageBlocks) > 0 && w.state.View.Identity.Provider == "claude" {
		envelope := obj(frame)
		message := obj(envelope["message"])
		content := array(message["content"])
		content = append(content, imageBlocks...)
		message["content"] = wire(content)
		envelope["message"] = wire(message)
		frame = wire(envelope)
	}
	if e != nil {
		w.state.View = before
		_ = w.state.RecordOutcome(a.ID, "rejected", e.Error())
		receipt = w.state.Receipts[a.ID]
		if pe := w.persistReceipt(receipt); pe != nil {
			w.inputHeld = true
			w.state.View.Failure = pe.Error()
		}
		w.signal()
		w.mu.Unlock()
		return RPCResponse{Receipt: &receipt, Error: e.Error()}
	}
	if e = w.persistReceipt(receipt); e != nil {
		w.state.View = before
		w.inputHeld = true
		w.state.View.Failure = "Action could not be durably recorded. No provider input was sent."
		w.signal()
		detail := w.state.View.Failure
		w.mu.Unlock()
		return RPCResponse{Error: detail}
	}
	w.signal()
	w.mu.Unlock()
	writeErr := w.write(frame)
	w.mu.Lock()
	defer w.mu.Unlock()
	outcome, detail := "sent", "Written once to the provider; this is not turn completion."
	if writeErr != nil {
		outcome = "uncertain"
		detail = writeErr.Error()
		w.inputHeld = true
		w.state.View.Failure = "Provider input outcome is unknown. Relay will not resend it."
	}
	// A native rejection can arrive before the pipe write completes.
	if w.state.Receipts[a.ID].State == "claimed" {
		_ = w.state.RecordOutcome(a.ID, outcome, detail)
	}
	receipt = w.state.Receipts[a.ID]
	if e = w.persistReceipt(receipt); e != nil {
		w.inputHeld = true
		w.state.View.Failure = "Provider input was sent but its receipt could not be persisted."
	}
	if writeErr == nil && a.Kind == "respond" {
		w.state.ResolveRequest(a.RequestID)
	}
	if a.Kind == "send" || a.Kind == "steer" {
		text := a.Text
		for range a.Images {
			text += "\n[Attached image]"
		}
		_ = w.state.AddItem(Item{ID: "user-" + a.ID, Role: "user", Text: text, Status: outcome}, false)
	}
	if e = w.appendItems(); e == nil {
		e = w.items.Sync()
	}
	if e == nil {
		e = w.persistView()
	}
	if e != nil {
		w.inputHeld = true
		w.state.View.Failure = e.Error()
	}
	w.signal()
	v := w.view()
	return RPCResponse{Snapshot: &v, Receipt: &receipt}
}
func (w *worker) handle(ctx context.Context, r RPCRequest) RPCResponse {
	if r.Identity != w.descriptor.Identity {
		return RPCResponse{Error: "Native worker identity changed; no operation was performed."}
	}
	if r.Operation == "action" {
		return w.action(*r.Action)
	}
	if r.Operation == "image" {
		path, e := storeImage(w.directory, r.ImageData)
		if e != nil {
			return RPCResponse{Error: e.Error()}
		}
		return RPCResponse{ImagePath: path}
	}
	w.mu.Lock()
	if r.Operation == "receipt" {
		receipt, ok := w.state.Receipts[r.ReceiptID]
		w.mu.Unlock()
		if !ok {
			return RPCResponse{Error: "Receipt is unknown; do not replay the action."}
		}
		return RPCResponse{Receipt: &receipt}
	}
	if r.Before == 0 && r.WaitMillis > 0 && r.AfterRevision >= w.state.View.Revision {
		changed := w.changed
		w.mu.Unlock()
		timer := time.NewTimer(time.Duration(r.WaitMillis) * time.Millisecond)
		select {
		case <-ctx.Done():
		case <-changed:
		case <-timer.C:
		}
		timer.Stop()
		// Coalesce token deltas. One native UI reader does not create one RPC per token.
		if ctx.Err() == nil {
			timer = time.NewTimer(100 * time.Millisecond)
			select {
			case <-ctx.Done():
			case <-timer.C:
			}
			timer.Stop()
		}
		w.mu.Lock()
	}
	v := w.view()
	w.mu.Unlock()
	if r.Before > 0 {
		w.mu.Lock()
		items, older, e := readHistory(w.directory, r.Before)
		w.mu.Unlock()
		if e != nil {
			return RPCResponse{Error: e.Error()}
		}
		v.Items = items
		v.OlderBefore = older
		v.Requests = []Request{}
		v.Phase = "history"
		v.Capabilities = Capabilities{ScheduledTasks: "unknown"}
	}
	return RPCResponse{Snapshot: &v}
}
func (w *worker) serveConnection(ctx context.Context, c net.Conn) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(25 * time.Second))
	uid, _, e := w.kernel.PeerCredentials(c)
	if e != nil || uid != os.Getuid() {
		return
	}
	data, e := readFrame(c, MaxTransportBytes)
	if e != nil {
		return
	}
	r, e := DecodeRPC(data)
	response := RPCResponse{}
	if e != nil {
		response.Error = e.Error()
	} else {
		response = w.handle(ctx, r)
	}
	data, e = json.Marshal(response)
	if e == nil && len(data) <= MaxTransportBytes {
		_, _ = c.Write(append(data, '\n'))
	}
}
func Serve(ctx context.Context, c RunConfig) error {
	if c.Kernel.ProcessStart == nil || c.Kernel.PeerCredentials == nil || !filepath.IsAbs(c.Executable) {
		return errors.New("native worker requires an exact executable and kernel identity checks")
	}
	dir, e := instanceDirectory(c.Root, c.Identity)
	if e != nil {
		return e
	}
	paneDir := filepath.Dir(dir)
	if e = privateDirectory(filepath.Dir(paneDir)); e != nil {
		return e
	}
	if e = privateDirectory(paneDir); e != nil {
		return e
	}
	lock, e := os.OpenFile(filepath.Join(paneDir, "worker.lock"), os.O_CREATE|os.O_RDWR|unix.O_NOFOLLOW, 0600)
	if e != nil {
		return e
	}
	defer lock.Close()
	if e = unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); e != nil {
		return errors.New("this pane already has a native worker")
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	if _, e = os.Lstat(dir); !os.IsNotExist(e) {
		return errors.New("native instance already exists; a launch is never replayed")
	}
	if e = privateDirectory(dir); e != nil {
		return e
	}
	if e = privateDirectory(filepath.Join(dir, "images")); e != nil {
		return e
	}
	state, e := NewState(c.Identity, c.Provider.CWD, c.Provider.Model)
	if e != nil {
		return e
	}
	state.View.AccountRoot = c.Provider.AccountRoot
	driver, e := NewDriver(state, c.Provider)
	if e != nil {
		return e
	}
	socketDir := filepath.Join("/tmp", "relay-native-"+strconv.Itoa(os.Getuid()))
	if e = privateDirectory(socketDir); e != nil {
		return e
	}
	socket := filepath.Join(socketDir, stableID("chat", c.Identity.Pane+":"+c.Identity.Instance)+".sock")
	listener, e := net.Listen("unix", socket)
	if e != nil {
		return e
	}
	// macOS TMPDIR can exceed sockaddr_un even for short instance IDs.
	// The fixed short parent contains a private, owned per-UID directory.
	listener.(*net.UnixListener).SetUnlinkOnClose(false)
	defer listener.Close()
	if e = os.Chmod(socket, 0600); e != nil {
		return e
	}
	socketInfo, e := os.Lstat(socket)
	if e != nil {
		return e
	}
	defer func() {
		if current, e := os.Lstat(socket); e == nil && os.SameFile(socketInfo, current) {
			_ = os.Remove(socket)
		}
	}()
	cmd := exec.Command(c.Executable, c.Arguments...)
	cmd.Dir = c.Provider.CWD
	cmd.Env = c.Environment
	input, e := cmd.StdinPipe()
	if e != nil {
		return e
	}
	output, e := cmd.StdoutPipe()
	if e != nil {
		return e
	}
	stderr, e := cmd.StderrPipe()
	if e != nil {
		return e
	}
	// Complete all local preflight before a provider can create tools or jobs.
	start, e := c.Kernel.ProcessStart(os.Getpid())
	if e != nil {
		return e
	}
	items, e := os.OpenFile(filepath.Join(dir, "items.jsonl"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	defer items.Close()
	actions, e := os.OpenFile(filepath.Join(dir, "actions.jsonl"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	defer actions.Close()
	descriptor := Descriptor{Version: 1, Identity: c.Identity, PID: os.Getpid(), ProcessStart: start, Socket: socket}
	w := &worker{state: state, driver: driver, input: input, directory: dir, changed: make(chan struct{}), kernel: c.Kernel, descriptor: descriptor, items: items, actions: actions}
	if e = atomicJSON(filepath.Join(dir, "descriptor.json"), descriptor); e != nil {
		return e
	}
	if e = w.persistView(); e != nil {
		return e
	}
	if e = ctx.Err(); e != nil {
		return e
	}
	var lease *os.File
	defer func() {
		if lease != nil {
			_ = lease.Close()
		}
	}()
	if c.Provider.Resume != "" {
		lease, e = sessionLease(c.Root, c.Identity.Provider, c.Provider.AccountRoot, c.Provider.Resume)
		if e != nil {
			return e
		}
	}
	if e = claimLaunch(c.Root, c.Identity); e != nil {
		return e
	}
	if e = cmd.Start(); e != nil {
		return e
	}
	// After start, failures hold controls while this worker continues observing
	// the same provider. No termination, stdin closure, replacement or replay.
	providerStart, identityErr := c.Kernel.ProcessStart(cmd.Process.Pid)
	descriptor.ProviderPID = cmd.Process.Pid
	descriptor.ProviderStart = providerStart
	w.descriptor = descriptor
	if identityErr == nil {
		identityErr = atomicJSON(filepath.Join(dir, "descriptor.json"), descriptor)
	}
	if identityErr != nil {
		w.inputHeld = true
		state.View.Failure = "Provider started but its identity could not be recorded: " + identityErr.Error()
	}
	childContext, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { <-childContext.Done(); _ = listener.Close() }()
	go func() {
		slots := make(chan struct{}, 16)
		for {
			connection, e := listener.Accept()
			if e != nil {
				return
			}
			select {
			case slots <- struct{}{}:
				go func() { defer func() { <-slots }(); w.serveConnection(childContext, connection) }()
			default:
				_ = connection.Close()
			}
		}
	}()
	// Stderr is bounded diagnostic text, not a protocol or authority source.
	go func() {
		scanner := bufio.NewScanner(stderr)
		scanner.Buffer(make([]byte, 4096), 64<<10)
		for scanner.Scan() {
			line := scanner.Text()
			w.mu.Lock()
			if w.state.View.Phase == "starting" {
				w.state.View.Failure = line
				w.state.touch()
				w.signal()
			}
			w.mu.Unlock()
		}
	}()
	if !w.inputHeld {
		if e = w.write(driver.Initial()); e != nil {
			w.mu.Lock()
			w.inputHeld = true
			state.View.Failure = e.Error()
			w.signal()
			w.mu.Unlock()
		}
	}
	go func() {
		select {
		case <-ctx.Done():
			w.mu.Lock()
			w.inputHeld = true
			state.View.Failure = "Worker control context ended; the provider is retained and inputs are held."
			state.touch()
			w.signal()
			w.mu.Unlock()
		case <-childContext.Done():
		}
	}()
	scanner := bufio.NewScanner(output)
	scanner.Buffer(make([]byte, 64<<10), MaxFrameBytes)
	for scanner.Scan() {
		w.mu.Lock()
		previousPhase := state.View.Phase
		frames, err := driver.Consume(scanner.Bytes())
		if err == nil && lease == nil && state.View.SessionID != "" && c.Provider.AccountRoot != "" {
			lease, err = sessionLease(c.Root, c.Identity.Provider, c.Provider.AccountRoot, state.View.SessionID)
		}
		if err != nil {
			w.inputHeld = true
			state.View.Failure = "Provider protocol error: " + err.Error()
			state.touch()
		}
		if e = w.appendItems(); e != nil {
			w.inputHeld = true
			state.View.Failure = e.Error()
		}
		if state.View.Phase != previousPhase {
			if e = items.Sync(); e == nil {
				e = w.persistView()
			}
			if e != nil {
				w.inputHeld = true
				state.View.Failure = "Conversation state could not be persisted: " + e.Error()
			}
		}
		w.signal()
		w.mu.Unlock()
		for _, frame := range frames {
			if e = w.write(frame); e != nil {
				w.mu.Lock()
				w.inputHeld = true
				state.View.Failure = e.Error()
				w.signal()
				w.mu.Unlock()
			}
		}
	}
	scanErr := scanner.Err()
	if scanErr != nil {
		w.mu.Lock()
		w.inputHeld = true
		state.View.Failure = "Provider output exceeded the supported frame limit; controls are held."
		state.touch()
		w.signal()
		w.mu.Unlock()
		_, _ = io.Copy(io.Discard, output)
	}
	waitErr := cmd.Wait()
	w.mu.Lock()
	detail := "Provider process exited."
	if scanErr != nil {
		detail = "Provider protocol stream failed: " + scanErr.Error()
	} else if waitErr != nil {
		detail = waitErr.Error()
	}
	state.Exit(detail)
	_ = w.persistView()
	w.signal()
	w.mu.Unlock()
	cancel()
	_ = items.Sync()
	return waitErr
}
func readHistory(dir string, before uint64) ([]Item, uint64, error) {
	f, e := os.OpenFile(filepath.Join(dir, "items.jsonl"), os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if e != nil {
		return nil, 0, e
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	items := map[string]Item{}
	var lower uint64
	for scanner.Scan() {
		b := scanner.Bytes()
		if _, e := DecodeObject(b, 1<<20); e != nil {
			return nil, 0, e
		}
		var r itemRecord
		if json.Unmarshal(b, &r) != nil || r.Item.Sequence == 0 {
			return nil, 0, errors.New("invalid native history item")
		}
		i := r.Item
		if before > 0 && i.Sequence >= before {
			continue
		}
		if i.Sequence < lower {
			continue
		}
		if r.Delta {
			prior, ok := items[i.ID]
			if !ok {
				if lower > 0 && i.Sequence < lower {
					continue
				}
				return nil, 0, errors.New("native history delta has no base item")
			}
			i.Text = prior.Text + i.Text
			i = boundItem(i)
		}
		items[i.ID] = i
		if len(items) > MaxItems {
			var oldest string
			seq := ^uint64(0)
			for id, item := range items {
				if item.Sequence < seq {
					seq = item.Sequence
					oldest = id
				}
			}
			delete(items, oldest)
			lower = seq + 1
		}
	}
	if e = scanner.Err(); e != nil {
		return nil, 0, e
	}
	ordered := make([]Item, 0, len(items))
	for _, i := range items {
		ordered = append(ordered, i)
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].Sequence < ordered[j].Sequence })
	older := uint64(0)
	if len(ordered) > 0 && ordered[0].Sequence > 1 {
		older = ordered[0].Sequence
	}
	return ordered, older, nil
}
func Call(ctx context.Context, root string, r RPCRequest, k Kernel) (RPCResponse, error) {
	if _, e := DecodeRPC(wire(r)); e != nil {
		return RPCResponse{}, e
	}
	dir, e := instanceDirectory(root, r.Identity)
	if e != nil {
		return RPCResponse{}, e
	}
	data, e := privateRead(filepath.Join(dir, "descriptor.json"), 16<<10)
	if e != nil {
		return RPCResponse{}, e
	}
	if _, e = DecodeObject(data, 16<<10); e != nil {
		return RPCResponse{}, e
	}
	var d Descriptor
	if json.Unmarshal(data, &d) != nil || d.Version != 1 || d.Identity != r.Identity {
		return RPCResponse{}, errors.New("native descriptor identity mismatch")
	}
	actual, e := k.ProcessStart(d.PID)
	if e != nil || actual != d.ProcessStart {
		if r.Operation != "snapshot" {
			return RPCResponse{}, errors.New("native worker exited; no action was sent")
		}
		data, e = privateRead(filepath.Join(dir, "snapshot.json"), MaxTransportBytes)
		if e != nil {
			return RPCResponse{}, e
		}
		var v Snapshot
		if json.Unmarshal(data, &v) != nil || v.Identity != r.Identity {
			return RPCResponse{}, errors.New("invalid saved native history")
		}
		v.Phase = "exited"
		v.Requests = []Request{}
		v.Capabilities = Capabilities{ScheduledTasks: "unknown", MaintenanceReason: "Worker is not running."}
		v.Items, v.OlderBefore, e = readHistory(dir, r.Before)
		if e != nil {
			return RPCResponse{}, e
		}
		return RPCResponse{Snapshot: &v}, nil
	}
	socketDir := filepath.Join("/tmp", "relay-native-"+strconv.Itoa(os.Getuid()))
	expected := filepath.Join(socketDir, stableID("chat", r.Identity.Pane+":"+r.Identity.Instance)+".sock")
	if d.Socket != expected {
		return RPCResponse{}, errors.New("native socket escaped its owned directory")
	}
	connection, e := (&net.Dialer{}).DialContext(ctx, "unix", d.Socket)
	if e != nil {
		return RPCResponse{}, e
	}
	defer connection.Close()
	stop := context.AfterFunc(ctx, func() { _ = connection.Close() })
	defer stop()
	_ = connection.SetDeadline(time.Now().Add(25 * time.Second))
	uid, pid, e := k.PeerCredentials(connection)
	if e != nil || uid != os.Getuid() || pid != d.PID {
		return RPCResponse{}, errors.New("native socket peer does not match its owner")
	}
	actual, e = k.ProcessStart(pid)
	if e != nil || actual != d.ProcessStart {
		return RPCResponse{}, errors.New("native worker incarnation changed")
	}
	if _, e = connection.Write(append(wire(r), '\n')); e != nil {
		return RPCResponse{}, fmt.Errorf("native request write outcome unknown: %w", e)
	}
	data, e = readFrame(connection, MaxTransportBytes)
	if e != nil {
		return RPCResponse{}, fmt.Errorf("native request response unavailable; do not replay: %w", e)
	}
	if _, e = DecodeObject(data, MaxTransportBytes); e != nil {
		return RPCResponse{}, e
	}
	var response RPCResponse
	if json.Unmarshal(data, &response) != nil {
		return RPCResponse{}, errors.New("invalid native response")
	}
	actual, e = k.ProcessStart(pid)
	if e != nil || actual != d.ProcessStart {
		return RPCResponse{}, errors.New("native worker changed during request; do not replay")
	}
	if response.Snapshot != nil && response.Snapshot.Identity != r.Identity {
		return RPCResponse{}, errors.New("native response identity mismatch")
	}
	return response, nil
}
func imageType(data []byte) string {
	if len(data) >= 8 && bytes.Equal(data[:8], []byte{137, 80, 78, 71, 13, 10, 26, 10}) {
		return "image/png"
	}
	if len(data) >= 3 && data[0] == 255 && data[1] == 216 && data[2] == 255 {
		return "image/jpeg"
	}
	if len(data) >= 6 && (string(data[:6]) == "GIF87a" || string(data[:6]) == "GIF89a") {
		return "image/gif"
	}
	return ""
}
func storeImage(dir string, data []byte) (string, error) {
	if len(data) == 0 || len(data) > MaxImageBytes || imageType(data) == "" {
		return "", errors.New("attach a PNG, JPEG or GIF image up to 4 MiB")
	}
	path := filepath.Join(dir, "images", stableID("image", string(data)))
	f, e := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY|unix.O_NOFOLLOW, 0600)
	if os.IsExist(e) {
		old, re := privateRead(path, MaxImageBytes)
		if re != nil || !bytes.Equal(old, data) {
			return "", errors.New("uploaded image changed")
		}
		return path, nil
	}
	if e != nil {
		return "", e
	}
	_, e = f.Write(data)
	if e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e == nil {
		e = closeErr
	}
	if e != nil {
		return "", e
	}
	return path, nil
}
func (w *worker) imageBlocks(paths []string) ([]json.RawMessage, error) {
	blocks := []json.RawMessage{}
	if len(paths) > 4 {
		return nil, errors.New("attach at most four images per message")
	}
	for _, path := range paths {
		if filepath.Dir(path) != filepath.Join(w.directory, "images") || !strings.HasPrefix(filepath.Base(path), "image-") {
			return nil, errors.New("image was not uploaded for this native instance")
		}
		data, e := privateRead(path, MaxImageBytes)
		if e != nil {
			return nil, e
		}
		if filepath.Base(path) != stableID("image", string(data)) || imageType(data) == "" {
			return nil, errors.New("uploaded image content changed")
		}
		blocks = append(blocks, wire(map[string]any{"type": "image", "source": map[string]any{"type": "base64", "media_type": imageType(data), "data": base64.StdEncoding.EncodeToString(data)}}))
	}
	return blocks, nil
}

// One launch action identifies at most one provider start across all panes.
// A failed or uncertain launch claim is never deleted or reused.
func claimLaunch(root string, identity Identity) error {
	if !identity.Valid() || !filepath.IsAbs(root) {
		return errors.New("invalid launch identity")
	}
	dir := filepath.Join(root, "native-launches")
	if e := privateDirectory(dir); e != nil {
		return e
	}
	f, e := os.OpenFile(filepath.Join(dir, identity.Instance+".json"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return fmt.Errorf("launch action already claimed or unavailable; do not replay: %w", e)
	}
	data := wire(identity)
	_, writeErr := f.Write(append(data, '\n'))
	if writeErr == nil {
		writeErr = f.Sync()
	}
	closeErr := f.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	directory, e := os.Open(dir)
	if e != nil {
		return e
	}
	defer directory.Close()
	return directory.Sync()
}

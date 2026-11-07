package desktoproute

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const workApp = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"

type workReference struct {
	Schema  int    `json:"schema"`
	Thread  string `json:"thread"`
	Host    string `json:"hostId"`
	Socket  string `json:"socket"`
	AppPath string `json:"appPath"`
	PID     int    `json:"appPID"`
	Start   string `json:"appStart"`
	Owner   string `json:"ownerClientId"`
}

func (d *nativeDesktop) validateWork(r workReference) error {
	if r.Schema != 1 || !identifier.MatchString(r.Thread) || r.Host != "local" || r.Socket != d.workSocket() || r.AppPath != workApp || r.PID <= 0 || len(r.Start) < 10 || len(r.Start) > 80 || !clientID.MatchString(r.Owner) {
		return errors.New("invalid Work endpoint identity")
	}
	return nil
}
func (d *nativeDesktop) readWork(path string) (*workReference, error) {
	if e := privateDirectory(d.workRoot(), false); e != nil {
		if os.IsNotExist(e) {
			return nil, nil
		}
		return nil, e
	}
	var r workReference
	if e := readJSONFile(path, 16384, &r); e != nil {
		if os.IsNotExist(e) {
			return nil, nil
		}
		return nil, e
	}
	if e := d.validateWork(r); e != nil {
		return nil, e
	}
	if filepath.Base(path) != r.Thread+".json" {
		return nil, errors.New("Work endpoint filename changed")
	}
	return &r, nil
}
func (d *nativeDesktop) workRef(path, thread string) (*workReference, error) {
	if filepath.Clean(path) != d.legacySocket() {
		return nil, nil
	}
	if !identifier.MatchString(thread) {
		return nil, errors.New("exact task required")
	}
	return d.readWork(filepath.Join(d.workRoot(), thread+".json"))
}
func (d *nativeDesktop) workRefs(path string) ([]workReference, error) {
	rows := []workReference{}
	if filepath.Clean(path) != d.legacySocket() {
		return rows, nil
	}
	if e := privateDirectory(d.workRoot(), false); e != nil {
		if os.IsNotExist(e) {
			return rows, nil
		}
		return nil, e
	}
	files, e := jsonFiles(d.workRoot(), 16)
	if e != nil {
		return nil, e
	}
	for _, p := range files {
		r, e := d.readWork(p)
		if e != nil {
			return nil, e
		}
		if r == nil {
			return nil, errors.New("Work reference disappeared")
		}
		rows = append(rows, *r)
	}
	return rows, nil
}
func (d *nativeDesktop) workProcess(r workReference) error {
	if e := d.validateWork(r); e != nil {
		return e
	}
	p, e := d.inspect(r.PID)
	if e != nil {
		return e
	}
	if p.WorkStart != r.Start || p.Executable != r.AppPath {
		return errors.New("Work application incarnation changed")
	}
	return nil
}

type workClient struct {
	conn   *net.UnixConn
	ref    workReference
	client string
	cancel func() bool
}

func (c *workClient) close() { c.cancel(); c.conn.Close() }
func (d *nativeDesktop) openWork(ctx context.Context, r workReference) (*workClient, error) {
	if e := d.workProcess(r); e != nil {
		return nil, e
	}
	if e := privateDirectory(filepath.Dir(r.Socket), false); e != nil {
		return nil, e
	}
	socket, e := dialSocket(ctx, r.Socket)
	if e != nil {
		return nil, e
	}
	pid, uid, e := socketPeer(socket)
	if e != nil || pid != r.PID || uid != os.Getuid() {
		socket.Close()
		return nil, errors.New("Work kernel socket owner changed")
	}
	if e = d.workProcess(r); e != nil {
		socket.Close()
		return nil, e
	}
	c := &workClient{conn: socket, ref: r, client: "initializing-client", cancel: context.AfterFunc(ctx, func() { socket.Close() })}
	reply, e := c.request("initialize", map[string]string{"clientType": "relay"}, 0, "")
	if e != nil {
		c.close()
		return nil, e
	}
	var result struct {
		Client string `json:"clientId"`
	}
	if decodeJSON(reply.Result, 8<<20, &result) != nil || !clientID.MatchString(result.Client) {
		c.close()
		return nil, errors.New("invalid Work client identity")
	}
	c.client = result.Client
	return c, nil
}
func (c *workClient) send(value any) error { return c.sendGuarded(value, nil) }

// guard runs after serialization immediately before the first socket write.
func (c *workClient) sendGuarded(value any, guard func() error) error {
	b, e := json.Marshal(value)
	if e != nil || len(b) > 131072 {
		return errors.New("Work request exceeds limit")
	}
	frame := make([]byte, 4+len(b))
	binary.LittleEndian.PutUint32(frame, uint32(len(b)))
	copy(frame[4:], b)
	if guard != nil {
		if e = guard(); e != nil {
			return e
		}
	}
	for len(frame) > 0 {
		n, e := c.conn.Write(frame)
		if e != nil {
			return e
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		frame = frame[n:]
	}
	return nil
}

type workResponse struct {
	Type   string          `json:"type"`
	ID     string          `json:"requestId"`
	Method string          `json:"method"`
	Kind   string          `json:"resultType"`
	Owner  string          `json:"handledByClientId"`
	Result json.RawMessage `json:"result"`
}

func readWorkFrame(r io.Reader) (workResponse, error) {
	var result workResponse
	var prefix [4]byte
	if _, e := io.ReadFull(r, prefix[:]); e != nil {
		return result, e
	}
	n := binary.LittleEndian.Uint32(prefix[:])
	if n == 0 || n > 8<<20 {
		return result, errors.New("Work response exceeds limit")
	}
	b := make([]byte, n)
	if _, e := io.ReadFull(r, b); e != nil {
		return result, e
	}
	e := decodeJSON(b, 8<<20, &result)
	return result, e
}
func (c *workClient) request(method string, params any, version int, target string) (workResponse, error) {
	return c.requestGuarded(method, params, version, target, nil)
}
func (c *workClient) requestGuarded(method string, params any, version int, target string, guard func() error) (workResponse, error) {
	id := uuid()
	request := map[string]any{"type": "request", "requestId": id, "sourceClientId": c.client, "method": method, "params": params, "version": version, "timeoutMs": 12000}
	if target != "" {
		request["targetClientId"] = target
	}
	if e := c.sendGuarded(request, guard); e != nil {
		return workResponse{}, e
	}
	for n := 0; n < 4096; n++ {
		reply, e := readWorkFrame(c.conn)
		if e != nil {
			return reply, e
		}
		if reply.Type == "client-discovery-request" {
			if !clientID.MatchString(reply.ID) {
				return reply, errors.New("invalid discovery ID")
			}
			if e = c.send(map[string]any{"type": "client-discovery-response", "requestId": reply.ID, "response": map[string]bool{"canHandle": false}}); e != nil {
				return reply, e
			}
		}
		if reply.Type != "response" || reply.ID != id {
			continue
		}
		if reply.Kind != "success" || reply.Method != method || (target != "" && reply.Owner != target) {
			return reply, errors.New("Work response refused or identity changed")
		}
		return reply, nil
	}
	return workResponse{}, errors.New("too many unrelated Work frames")
}
func (c *workClient) owner(pin bool) (string, error) {
	reply, e := c.request("thread-owner-discovery", map[string]string{"hostId": "local", "conversationId": c.ref.Thread}, 1, "")
	if e != nil {
		return "", e
	}
	var r struct {
		Safe bool `json:"supportsUntrustedAppInput"`
	}
	if decodeJSON(reply.Result, 8<<20, &r) != nil || !r.Safe || !clientID.MatchString(reply.Owner) || (pin && reply.Owner != c.ref.Owner) {
		return "", errors.New("Work task owner changed or untrusted-input support absent")
	}
	return reply.Owner, nil
}
func (d *nativeDesktop) inspectWork(ctx context.Context, thread string) (workReference, error) {
	r := workReference{Schema: 1, Thread: thread, Host: "local", Socket: d.workSocket(), AppPath: workApp, Owner: "00000000-0000-0000-0000-000000000000"}
	if !identifier.MatchString(thread) {
		return r, errors.New("invalid task")
	}
	if e := privateDirectory(filepath.Dir(r.Socket), false); e != nil {
		return r, e
	}
	socket, e := dialSocket(ctx, r.Socket)
	if e != nil {
		return r, e
	}
	pid, uid, e := socketPeer(socket)
	socket.Close()
	if e != nil || uid != os.Getuid() {
		return r, errors.New("Work peer unavailable")
	}
	r.PID = pid
	p, e := d.inspect(pid)
	if e != nil {
		return r, e
	}
	r.Start = p.WorkStart
	c, e := d.openWork(ctx, r)
	if e != nil {
		return r, e
	}
	defer c.close()
	r.Owner, e = c.owner(false)
	if e != nil {
		return r, e
	}
	return r, d.workProcess(r)
}

// verifyWork reports whether a saved Work endpoint still answers as pinned:
// the same app incarnation, kernel socket owner and thread owner.
func (d *nativeDesktop) verifyWork(ctx context.Context, ref workReference) bool {
	c, e := d.openWork(ctx, ref)
	if e != nil {
		return false
	}
	defer c.close()
	_, e = c.owner(true)
	return e == nil
}

// repinWork moves a saved Work endpoint to the app's current incarnation after
// the Codex app restarted. It applies only on the legacy discovery path that
// task-prepare also uses, re-checks the same thread with the same evidence a
// first registration needs (socket peer UID and PID, the Work app executable
// and start time, the thread's owner and untrusted-input support), and commits
// only if the saved record is still the one that failed. A different thread,
// executable or owner without untrusted-input support is never pinned.
func (d *nativeDesktop) repinWork(ctx context.Context, path string, stale workReference) bool {
	if filepath.Clean(path) != d.legacySocket() {
		return false
	}
	fresh, e := d.inspectWork(ctx, stale.Thread)
	if e != nil || fresh.Thread != stale.Thread || fresh.AppPath != stale.AppPath || !laterIncarnation(stale.Start, fresh.Start) {
		return false
	}
	return d.commitWork(fresh, &stale) == nil
}

// laterIncarnation reports whether the app's new start time is strictly after
// the pinned one. Both are ps lstart strings; an unparseable time never repins.
func laterIncarnation(pinned, current string) bool {
	const layout = "Mon Jan 2 15:04:05 2006"
	a, e := time.ParseInLocation(layout, strings.Join(strings.Fields(pinned), " "), time.Local)
	b, f := time.ParseInLocation(layout, strings.Join(strings.Fields(current), " "), time.Local)
	return e == nil && f == nil && b.After(a)
}

func (d *nativeDesktop) commitWork(r workReference, expected *workReference) error {
	if e := d.validateWork(r); e != nil {
		return e
	}
	if e := privateDirectory(d.workRoot(), true); e != nil {
		return e
	}
	lock, e := fileLock(filepath.Join(d.workRoot(), ".registry.lock"), false)
	if e != nil {
		return e
	}
	defer lock.Close()
	path := filepath.Join(d.workRoot(), r.Thread+".json")
	current, e := d.readWork(path)
	if e != nil {
		return e
	}
	if (current == nil) != (expected == nil) || (current != nil && *current != *expected) {
		return errors.New("selected Work endpoint changed concurrently")
	}
	if current == nil {
		files, e := jsonFiles(d.workRoot(), 16)
		if e != nil {
			return e
		}
		if len(files) >= 16 {
			return errors.New("Work registry full")
		}
	}
	if e = d.workProcess(r); e != nil {
		return e
	}
	if current == nil {
		return exclusiveJSON(path, r)
	}
	return atomicJSON(path, r)
}
func (d *nativeDesktop) deliverWork(ctx context.Context, r workReference, m Envelope, payload map[string]any) (result Delivery) {
	result = Delivery{MessageID: m.ID, Receipt: "not_sent", Transport: "work_ipc"}
	c, e := d.openWork(ctx, r)
	if e != nil {
		result.Error = e.Error()
		return
	}
	defer c.close()
	owner, e := c.owner(true)
	if e != nil {
		result.Error = e.Error()
		return
	}
	params := map[string]any{"conversationId": r.Thread, "turnStart": map[string]any{"request": payload, "context": map[string]bool{"useAppServerPermissionDefault": true, "inheritThreadSettings": true}}}
	result.Receipt = "unknown"
	_, e = c.request("thread-follower-start-turn", params, 2, owner)
	if e != nil {
		result.Error = e.Error()
		return
	}
	result.Receipt = "admitted"
	return
}

// SelectedWorkIdentity is an exact native owner and application incarnation.
// It is an observation, not a persistent authorization or a liveness promise.
type SelectedWorkIdentity struct {
	Thread string
	Owner  string
	PID    int
	Start  string
}

func (w SelectedWorkIdentity) Incarnation() string { return strconv.Itoa(w.PID) + ":" + w.Start }

// InspectSelectedWork observes one explicitly selected Work conversation.
func InspectSelectedWork(ctx context.Context, thread string) (SelectedWorkIdentity, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return SelectedWorkIdentity{}, err
	}
	return (&nativeDesktop{home: home, inspect: inspectProcess}).inspectSelectedWork(ctx, thread)
}
func (d *nativeDesktop) inspectSelectedWork(ctx context.Context, thread string) (SelectedWorkIdentity, error) {
	r, err := d.inspectWork(ctx, thread)
	if err != nil {
		return SelectedWorkIdentity{}, err
	}
	return SelectedWorkIdentity{Thread: r.Thread, Owner: r.Owner, PID: r.PID, Start: r.Start}, nil
}

// VerifySelectedWork reopens the saved exact reference, checks kernel socket
// peer and application incarnation, and queries that conversation's owner.
// It does not reserve the owner against a later application change.
func VerifySelectedWork(ctx context.Context, thread, owner, incarnation string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	return (&nativeDesktop{home: home, inspect: inspectProcess}).verifySelectedWork(ctx, thread, owner, incarnation)
}
func (d *nativeDesktop) verifySelectedWork(ctx context.Context, thread, owner, incarnation string) error {
	r, err := d.workRef(d.legacySocket(), thread)
	if err != nil {
		return err
	}
	if r == nil {
		return errors.New("selected Work reference missing")
	}
	selected := SelectedWorkIdentity{Thread: r.Thread, Owner: r.Owner, PID: r.PID, Start: r.Start}
	if selected.Thread != thread || selected.Owner != owner || selected.Incarnation() != incarnation {
		return errors.New("selected Work identity changed")
	}
	c, err := d.openWork(ctx, *r)
	if err != nil {
		return err
	}
	defer c.close()
	if _, err = c.owner(true); err != nil {
		return err
	}
	latest, err := d.workRef(d.legacySocket(), thread)
	if err != nil {
		return err
	}
	if latest == nil || *latest != *r {
		return errors.New("selected Work reference changed")
	}
	return d.workProcess(*r)
}

// DeliverSelectedWork sends only to the saved exact Work selection. The caller
// must already have authenticated the source, authorized this pair and bound
// the envelope to its durable request. A successful receipt means admitted by
// the Work IPC owner; it is not a read receipt.
func DeliverSelectedWork(ctx context.Context, thread, owner, incarnation string, m Envelope, guard func(context.Context) error) Delivery {
	home, err := os.UserHomeDir()
	if err != nil {
		return Delivery{MessageID: m.ID, Receipt: "not_sent", Error: err.Error()}
	}
	return (&nativeDesktop{home: home, inspect: inspectProcess}).deliverSelectedWork(ctx, thread, owner, incarnation, m, guard)
}

func (d *nativeDesktop) deliverSelectedWork(ctx context.Context, thread, owner, incarnation string, m Envelope, guard func(context.Context) error) (result Delivery) {
	result = Delivery{MessageID: m.ID, Receipt: "not_sent", Transport: "work_ipc"}
	if guard == nil {
		result.Error = "admission guard unavailable"
		return
	}
	if !utf8.ValidString(m.Sender) || !utf8.ValidString(m.Content) {
		result.Error = "invalid Work text"
		return
	}
	payload, err := deliveryParams(thread, m)
	if err != nil {
		result.Error = err.Error()
		return
	}
	if err = ctx.Err(); err != nil {
		result.Error = err.Error()
		return
	}
	// Fail closed instead of blocking the authority on an outstanding rebind.
	lock, err := fileLock(filepath.Join(d.workRoot(), ".registry.lock"), true)
	if err != nil {
		result.Error = "Work registry unavailable"
		return
	}
	defer lock.Close()
	r, err := d.workRef(d.legacySocket(), thread)
	if err != nil || r == nil {
		result.Error = "selected Work reference unavailable"
		return
	}
	selected := SelectedWorkIdentity{Thread: r.Thread, Owner: r.Owner, PID: r.PID, Start: r.Start}
	if selected.Thread != thread || selected.Owner != owner || selected.Incarnation() != incarnation {
		result.Error = "selected Work identity changed"
		return
	}
	c, err := d.openWork(ctx, *r)
	if err != nil {
		result.Error = err.Error()
		return
	}
	defer c.close()
	pinnedOwner, err := c.owner(true)
	if err != nil {
		result.Error = err.Error()
		return
	}
	latest, err := d.workRef(d.legacySocket(), thread)
	if err != nil || latest == nil || *latest != *r {
		result.Error = "selected Work reference changed"
		return
	}
	if err = d.workProcess(*r); err != nil {
		result.Error = err.Error()
		return
	}
	if err = ctx.Err(); err != nil {
		result.Error = err.Error()
		return
	}
	params := map[string]any{"conversationId": r.Thread, "turnStart": map[string]any{"request": payload, "context": map[string]bool{"useAppServerPermissionDefault": true, "inheritThreadSettings": true}}}
	result.Receipt = "unknown"
	if _, err = c.requestGuarded("thread-follower-start-turn", params, 2, pinnedOwner, func() error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := guard(ctx); err != nil {
			return err
		}
		return ctx.Err()
	}); err != nil {
		result.Error = err.Error()
		return
	}
	result.Receipt = "admitted"
	return
}

// BindSelectedWork records a locally selected Work conversation without
// silently replacing an existing owner or application incarnation.
// The caller must obtain explicit local selection before invoking it.
func BindSelectedWork(ctx context.Context, thread string) (SelectedWorkIdentity, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return SelectedWorkIdentity{}, err
	}
	return (&nativeDesktop{home: home, inspect: inspectProcess}).bindSelectedWork(ctx, thread)
}
func (d *nativeDesktop) bindSelectedWork(ctx context.Context, thread string) (SelectedWorkIdentity, error) {
	r, err := d.inspectWork(ctx, thread)
	if err != nil {
		return SelectedWorkIdentity{}, err
	}
	if err = d.persistSelectedWork(ctx, r); err != nil {
		return SelectedWorkIdentity{}, err
	}
	return SelectedWorkIdentity{Thread: r.Thread, Owner: r.Owner, PID: r.PID, Start: r.Start}, nil
}
func (d *nativeDesktop) persistSelectedWork(ctx context.Context, r workReference) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := d.validateWork(r); err != nil {
		return err
	}
	if err := privateDirectory(d.workRoot(), true); err != nil {
		return err
	}
	lock, err := fileLock(filepath.Join(d.workRoot(), ".registry.lock"), true)
	if err != nil {
		return err
	}
	defer lock.Close()
	path := filepath.Join(d.workRoot(), r.Thread+".json")
	current, err := d.readWork(path)
	if err != nil {
		return err
	}
	if current != nil && *current != r {
		return errors.New("existing Work selection requires explicit rebind")
	}
	if err = d.workProcess(r); err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if current != nil {
		return syncDirectory(d.workRoot())
	}
	files, err := jsonFiles(d.workRoot(), 16)
	if err != nil {
		return err
	}
	if len(files) >= 16 {
		return errors.New("Work registry full")
	}
	return exclusiveJSON(path, r)
}

// ValidWorkThread reports whether a thread can be used as a single registry
// filename and Work conversation identifier.
func ValidWorkThread(thread string) bool { return identifier.MatchString(thread) }

// PrepareSelectedWork re-observes the exact Work conversation and commits its
// current native reference, exactly as `desktop-route task-prepare` does on the
// legacy control socket. It never selects a different conversation.
func PrepareSelectedWork(ctx context.Context, thread string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	d := &nativeDesktop{home: home, inspect: inspectProcess}
	_, err = d.Inspect(ctx, d.legacySocket(), thread, true)
	return err
}

package desktoproute

import (
	"context"
	"encoding/json"
	"errors"
	"golang.org/x/net/websocket"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode"
)

var errDesktopDiscoveryIncomplete = errors.New("desktop task discovery incomplete: no verified Work or legacy task")
var errDesktopIdentityConflict = errors.New("saved Work identity conflicts with a live legacy task; explicit repair required")

type discoveryWork uint8

const (
	workNoSaved discoveryWork = iota
	workSavedUnverified
	workRegistryUnavailable
)

type discoveryLegacy uint8

const (
	legacyEmpty discoveryLegacy = iota
	legacyUnavailable
	legacyNotChecked
	legacyIdentityConflict
)

type discoveryFailure struct {
	work   discoveryWork
	legacy discoveryLegacy
}

func (d discoveryFailure) Error() string {
	work := "work_discovery_unavailable"
	switch d.work {
	case workNoSaved:
		work = "no_saved_work_refs"
	case workSavedUnverified:
		work = "saved_work_unverified"
	}
	legacy := "not_checked"
	switch d.legacy {
	case legacyEmpty:
		legacy = "empty"
	case legacyUnavailable:
		legacy = "unavailable"
	case legacyIdentityConflict:
		legacy = "identity_conflict"
	}
	return "relay-desktop-discovery-go-v1:" + work + ":" + legacy
}
func (d discoveryFailure) Unwrap() error {
	if d.legacy == legacyIdentityConflict {
		return errDesktopIdentityConflict
	}
	return errDesktopDiscoveryIncomplete
}

type processInfo struct{ Start, WorkStart, Executable string }
type TaskInfo struct {
	ID     string  `json:"id"`
	Name   *string `json:"name"`
	Status string  `json:"status"`
}
type SelectedTask struct {
	ID        string `json:"id"`
	Transport string `json:"transport"`
}
type desktop interface {
	Tasks(context.Context, string) ([]TaskInfo, error)
	Loaded(context.Context, string) ([]string, error)
	Inspect(context.Context, string, string, bool) (SelectedTask, error)
	Verify(context.Context, string, string) error
	Permission(context.Context, string, string) (string, error)
	Deliver(context.Context, string, string, Envelope) Delivery
}
type nativeDesktop struct {
	home    string
	inspect func(int) (processInfo, error)
}

func (d *nativeDesktop) legacySocket() string {
	return filepath.Join(d.home, ".codex/app-server-control/app-server-control.sock")
}
func (d *nativeDesktop) workSocket() string { return filepath.Join(d.home, ".codex/ipc/ipc.sock") }
func (d *nativeDesktop) workRoot() string {
	return filepath.Join(d.home, ".local/share/relay/work-task-endpoints")
}

type socketIdentity struct {
	path     string
	dev, ino uint64
}

func checkSocket(path string) (socketIdentity, error) {
	var result socketIdentity
	if !filepath.IsAbs(path) {
		return result, errors.New("socket path must be absolute")
	}
	path = filepath.Clean(path)
	s, e := os.Lstat(path)
	if e != nil {
		return result, e
	}
	if s.Mode()&os.ModeSymlink != 0 {
		owner, ok := s.Sys().(*syscall.Stat_t)
		if !ok || int(owner.Uid) != os.Getuid() {
			return result, errors.New("unsafe socket link")
		}
		if e = privateDirectory(filepath.Dir(path), false); e != nil {
			return result, e
		}
		link, e := os.Readlink(path)
		if e != nil {
			return result, e
		}
		if !filepath.IsAbs(link) {
			link = filepath.Join(filepath.Dir(path), link)
		}
		path = filepath.Clean(link)
		if e = privateDirectory(filepath.Dir(path), false); e != nil {
			return result, e
		}
		s, e = os.Lstat(path)
		if e != nil {
			return result, e
		}
	}
	owner, ok := s.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() || s.Mode()&os.ModeSocket == 0 || s.Mode().Perm() != 0600 {
		return result, errors.New("server socket must be owned by this user, mode 0600")
	}
	return socketIdentity{path, uint64(owner.Dev), uint64(owner.Ino)}, nil
}
func dialSocket(ctx context.Context, path string) (*net.UnixConn, error) {
	before, e := checkSocket(path)
	if e != nil {
		return nil, e
	}
	c, e := (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, "unix", before.path)
	if e != nil {
		return nil, e
	}
	u := c.(*net.UnixConn)
	after, e := checkSocket(path)
	if e != nil || after != before {
		u.Close()
		return nil, errors.New("desktop socket changed while connecting")
	}
	_, uid, e := socketPeer(u)
	if e != nil || uid != os.Getuid() {
		u.Close()
		return nil, errors.New("desktop socket kernel owner changed")
	}
	deadline := time.Now().Add(15 * time.Second)
	if when, ok := ctx.Deadline(); ok && when.Before(deadline) {
		deadline = when
	}
	u.SetDeadline(deadline)
	return u, nil
}

type appClient struct {
	conn        *websocket.Conn
	next        int
	closeCancel func() bool
}

func openApp(ctx context.Context, path string) (*appClient, error) {
	socket, e := dialSocket(ctx, path)
	if e != nil {
		return nil, e
	}
	cfg, e := websocket.NewConfig("ws://localhost/", "http://localhost/")
	if e != nil {
		socket.Close()
		return nil, e
	}
	c, e := websocket.NewClient(cfg, socket)
	if e != nil {
		socket.Close()
		return nil, e
	}
	c.MaxPayloadBytes = 1 << 20
	a := &appClient{conn: c, closeCancel: context.AfterFunc(ctx, func() { c.Close() })}
	_, e = a.rpc("initialize", map[string]any{"clientInfo": map[string]string{"name": "relay_desktop_ingress", "version": "1"}, "capabilities": map[string]bool{"experimentalApi": true}})
	if e != nil {
		a.close()
		return nil, e
	}
	return a, nil
}
func (a *appClient) close() { a.closeCancel(); a.conn.Close() }
func (a *appClient) rpc(method string, params any) (json.RawMessage, error) {
	a.next++
	req := map[string]any{"id": a.next, "method": method, "params": params}
	b, e := json.Marshal(req)
	if e != nil || len(b) > 131072 {
		return nil, errors.New("desktop request exceeds limit")
	}
	if e = websocket.Message.Send(a.conn, string(b)); e != nil {
		return nil, e
	}
	for count := 0; count < 4096; count++ {
		var raw []byte
		if e = websocket.Message.Receive(a.conn, &raw); e != nil {
			return nil, e
		}
		var reply map[string]json.RawMessage
		if e = decodeJSON(raw, 1<<20, &reply); e != nil {
			return nil, e
		}
		var id int
		if json.Unmarshal(reply["id"], &id) != nil || id != a.next {
			continue
		}
		if _, ok := reply["error"]; ok {
			return nil, errors.New("desktop request refused")
		}
		result, ok := reply["result"]
		if !ok {
			return nil, errors.New("desktop result missing")
		}
		return result, nil
	}
	return nil, errors.New("too many unrelated desktop frames")
}
func (a *appClient) loaded() ([]string, error) {
	raw, e := a.rpc("thread/loaded/list", map[string]any{})
	if e != nil {
		return nil, e
	}
	var value struct {
		Data []string `json:"data"`
	}
	if e = decodeJSON(raw, 1<<20, &value); e != nil {
		return nil, e
	}
	if value.Data == nil || len(value.Data) > 128 {
		return nil, errors.New("desktop task list exceeds 128 tasks")
	}
	seen := map[string]bool{}
	var ids []string
	for _, id := range value.Data {
		if !identifier.MatchString(id) {
			return nil, errors.New("invalid desktop task ID")
		}
		if !seen[id] {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	sort.Strings(ids)
	return ids, nil
}
func contains(ids []string, id string) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}
func (a *appClient) verify(thread string) error {
	ids, e := a.loaded()
	if e != nil {
		return e
	}
	if !contains(ids, thread) {
		return errors.New("task not loaded; no implicit resume")
	}
	return nil
}
func validTaskName(s string) *string {
	if strings.TrimSpace(s) == "" || len([]rune(s)) > 180 || strings.IndexFunc(s, unicode.IsControl) >= 0 {
		return nil
	}
	return &s
}
func (d *nativeDesktop) Tasks(ctx context.Context, path string) ([]TaskInfo, error) {
	return d.tasks(ctx, path, true)
}
func (d *nativeDesktop) Loaded(ctx context.Context, path string) ([]string, error) {
	rows, e := d.tasks(ctx, path, false)
	if e != nil {
		return nil, e
	}
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.ID)
	}
	return ids, nil
}
func (d *nativeDesktop) tasks(ctx context.Context, path string, details bool) ([]TaskInfo, error) {
	refs, e := d.workRefs(path)
	if e != nil {
		if filepath.Clean(path) == d.legacySocket() {
			return nil, discoveryFailure{workRegistryUnavailable, legacyNotChecked}
		}
		return nil, e
	}
	workState := workNoSaved
	if len(refs) > 0 {
		workState = workSavedUnverified
	}
	rows := []TaskInfo{}
	registered := map[string]bool{}
	verified := map[string]bool{}
	for _, ref := range refs {
		registered[ref.Thread] = true
		if d.verifyWork(ctx, ref) || d.repinWork(ctx, path, ref) {
			verified[ref.Thread] = true
			rows = append(rows, TaskInfo{ID: ref.Thread, Status: "unknown"})
		}
	}
	a, e := openApp(ctx, path)
	if e != nil {
		if len(rows) > 0 && (os.IsNotExist(e) || errors.Is(e, syscall.ECONNREFUSED)) {
			return rows, nil
		}
		if filepath.Clean(path) == d.legacySocket() && len(rows) == 0 {
			return nil, discoveryFailure{workState, legacyUnavailable}
		}
		return nil, e
	}
	defer a.close()
	ids, e := a.loaded()
	if e != nil {
		if filepath.Clean(path) == d.legacySocket() && len(rows) == 0 {
			return nil, discoveryFailure{workState, legacyUnavailable}
		}
		return nil, e
	}
	if filepath.Clean(path) == d.legacySocket() && len(rows) == 0 && len(ids) == 0 {
		return nil, discoveryFailure{workState, legacyEmpty}
	}
	for _, id := range ids {
		if registered[id] {
			if !verified[id] {
				// Never hide the collision or silently switch a pinned Work
				// identity to a different transport.
				return nil, discoveryFailure{workSavedUnverified, legacyIdentityConflict}
			}
			continue
		}
		info := TaskInfo{ID: id, Status: "unknown"}
		if !details {
			rows = append(rows, info)
			continue
		}
		raw, e := a.rpc("thread/read", map[string]any{"threadId": id, "includeTurns": false})
		if e != nil {
			return nil, e
		}
		var item struct {
			Thread struct {
				ID     string `json:"id"`
				Name   string `json:"name"`
				Status struct {
					Type string `json:"type"`
				} `json:"status"`
			} `json:"thread"`
		}
		if decodeJSON(raw, 1<<20, &item) == nil && item.Thread.ID == id {
			info.Name = validTaskName(item.Thread.Name)
			if item.Thread.Status.Type == "active" || item.Thread.Status.Type == "idle" {
				info.Status = item.Thread.Status.Type
			}
		}
		rows = append(rows, info)
	}
	if len(rows) > 128 {
		return nil, errors.New("combined task list exceeds 128")
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].ID < rows[j].ID })
	return rows, nil
}
func (d *nativeDesktop) Verify(ctx context.Context, path, thread string) error {
	if !identifier.MatchString(thread) {
		return errors.New("exact desktop task required")
	}
	ref, e := d.workRef(path, thread)
	if e != nil {
		return e
	}
	if ref != nil {
		ref = d.liveWork(ctx, path, ref)
		c, e := d.openWork(ctx, *ref)
		if e != nil {
			return e
		}
		defer c.close()
		_, e = c.owner(true)
		return e
	}
	a, e := openApp(ctx, path)
	if e != nil {
		return e
	}
	defer a.close()
	return a.verify(thread)
}
func deliveryParams(thread string, m Envelope) (map[string]any, error) {
	if !identifier.MatchString(thread) || !messageID.MatchString(m.ID) || strings.TrimSpace(m.Sender) == "" || strings.TrimSpace(m.Content) == "" {
		return nil, errors.New("exact task, message ID, sender and content required")
	}
	body, e := json.Marshal(map[string]string{"id": m.ID, "sender": m.Sender, "content": m.Content})
	if e != nil || len(body) > messageLimit {
		return nil, errors.New("message too large")
	}
	return map[string]any{"threadId": thread, "input": []any{}, "toolOutput": map[string]string{"namespace": "relay", "name": "peer_message", "output": string(body)}}, nil
}
func (d *nativeDesktop) Deliver(ctx context.Context, path, thread string, m Envelope) (result Delivery) {
	result = Delivery{MessageID: m.ID, Receipt: "not_sent"}
	payload, e := deliveryParams(thread, m)
	if e != nil {
		result.Error = e.Error()
		return
	}
	ref, e := d.workRef(path, thread)
	if e != nil {
		result.Error = e.Error()
		return
	}
	if ref != nil {
		ref = d.liveWork(ctx, path, ref)
		return d.deliverWork(ctx, *ref, m, payload)
	}
	a, e := openApp(ctx, path)
	if e != nil {
		result.Error = e.Error()
		return
	}
	defer a.close()
	if e = a.verify(thread); e != nil {
		result.Error = e.Error()
		return
	}
	// Set uncertainty before handing bytes to the socket. No resume/retry.
	result.Receipt = "unknown"
	raw, e := a.rpc("turn/start", payload)
	if e != nil {
		result.Error = e.Error()
		return
	}
	var reply struct {
		Turn struct {
			ID string `json:"id"`
		} `json:"turn"`
	}
	if e = decodeJSON(raw, 1<<20, &reply); e != nil || reply.Turn.ID == "" {
		result.Error = "invalid turn admission receipt"
		return
	}
	result.Receipt = "admitted"
	result.TurnID = reply.Turn.ID
	return
}
func (d *nativeDesktop) Permission(ctx context.Context, path, thread string) (string, error) {
	ref, e := d.workRef(path, thread)
	if e != nil {
		return "", e
	}
	if ref != nil {
		return "", d.Verify(ctx, path, thread)
	}
	a, e := openApp(ctx, path)
	if e != nil {
		return "", e
	}
	defer a.close()
	if e = a.verify(thread); e != nil {
		return "", e
	}
	raw, e := a.rpc("thread/read", map[string]any{"threadId": thread, "includeTurns": false})
	if e != nil {
		return "", e
	}
	var value struct {
		Thread struct {
			ID   string `json:"id"`
			Path string `json:"path"`
		} `json:"thread"`
	}
	if e = decodeJSON(raw, 1<<20, &value); e != nil {
		return "", e
	}
	if value.Thread.ID != thread {
		return "", errors.New("sender task identity changed")
	}
	root, e := filepath.EvalSymlinks(filepath.Join(d.home, ".codex/sessions"))
	if e != nil {
		return "", e
	}
	actual, e := filepath.EvalSymlinks(value.Thread.Path)
	if e != nil {
		return "", e
	}
	rel, e := filepath.Rel(root, actual)
	if e != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || !filepath.IsAbs(value.Thread.Path) {
		return "", errors.New("invalid sender context path")
	}
	fd, e := syscall.Open(value.Thread.Path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if e != nil {
		return "", e
	}
	f := os.NewFile(uintptr(fd), value.Thread.Path)
	defer f.Close()
	st, e := f.Stat()
	if e != nil {
		return "", e
	}
	owner, ok := st.Sys().(*syscall.Stat_t)
	if !ok || !st.Mode().IsRegular() || int(owner.Uid) != os.Getuid() || st.Mode().Perm()&0022 != 0 {
		return "", errors.New("unsafe sender context")
	}
	if st.Size() > 8<<20 {
		if _, e = f.Seek(st.Size()-(8<<20), 0); e != nil {
			return "", e
		}
	}
	data, e := readBounded(f, 8<<20)
	if e != nil {
		return "", e
	}
	return permissionFromContext(data), nil
}
func permissionFromContext(data []byte) string {
	lines := strings.Split(string(data), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		var row struct {
			Type    string `json:"type"`
			Payload struct {
				Approval string `json:"approval_policy"`
				Sandbox  struct {
					Type string `json:"type"`
				} `json:"sandbox_policy"`
			} `json:"payload"`
		}
		if decodeJSON([]byte(lines[i]), 8<<20, &row) != nil || row.Type != "turn_context" {
			continue
		}
		if row.Payload.Approval == "never" && row.Payload.Sandbox.Type == "danger-full-access" {
			return "bypass"
		}
		switch row.Payload.Approval {
		case "on-request", "on-failure", "untrusted":
			return "prompting"
		}
		return ""
	}
	return ""
}
func (d *nativeDesktop) Inspect(ctx context.Context, path, thread string, prepare bool) (SelectedTask, error) {
	if !identifier.MatchString(thread) {
		return SelectedTask{}, errors.New("exact desktop task required")
	}
	expected, e := d.workRef(path, thread)
	if e != nil {
		return SelectedTask{}, e
	}
	if filepath.Clean(path) == d.legacySocket() {
		ref, e := d.inspectWork(ctx, thread)
		if e == nil {
			if prepare {
				e = d.commitWork(ref, expected)
			}
			return SelectedTask{thread, "work_ipc"}, e
		}
		// A registered Work task never falls through an owner/authentication
		// failure. An unregistered task can still be an exact legacy task;
		// that independent provider must verify it is currently loaded.
		if expected != nil {
			return SelectedTask{}, e
		}
	}
	a, e := openApp(ctx, path)
	if e != nil {
		return SelectedTask{}, e
	}
	defer a.close()
	if e = a.verify(thread); e != nil {
		return SelectedTask{}, e
	}
	return SelectedTask{thread, "app_server"}, nil
}

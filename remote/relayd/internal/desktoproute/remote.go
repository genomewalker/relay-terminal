package desktoproute

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

type peerRecord struct {
	PID     int    `json:"pid"`
	Name    string `json:"name"`
	Session string `json:"sessionId"`
	Start   string `json:"procStart"`
	Socket  string `json:"messagingSocketPath"`
	CWD     string `json:"cwd"`
	Proxy   bool   `json:"relayProxy"`
}
type remoteRuntime struct {
	home        string
	inspect     func(int) (processInfo, error)
	environment func(int, ...string) (map[string]string, error)
}

func (r *remoteRuntime) registry(pid int, start string) (string, error) {
	root, err := r.accountRoot(pid, start)
	if err != nil {
		return "", err
	}
	sessions := filepath.Join(root, "sessions")
	return sessions, privateDirectory(sessions, false)
}

// accountRoot is the Claude account directory of the exact process incarnation:
// its own CLAUDE_CONFIG_DIR, or ~/.claude only when unset.
func (r *remoteRuntime) accountRoot(pid int, start string) (string, error) {
	before, e := r.inspect(pid)
	if e != nil || before.Start != start {
		return "", errIdentity
	}
	env, e := r.environment(pid, "CLAUDE_CONFIG_DIR")
	after, ae := r.inspect(pid)
	if ae != nil || after.Start != start {
		return "", errIdentity
	}
	if e != nil {
		return "", e
	}
	// Only an unset variable selects ~/.claude; a set one is the account.
	root, set := env["CLAUDE_CONFIG_DIR"]
	if !set {
		root = filepath.Join(r.home, ".claude")
	}
	if !filepath.IsAbs(root) || filepath.Clean(root) != root {
		return "", errors.New("invalid account path")
	}
	return root, nil
}
func (r *remoteRuntime) endpoint(registry string, pid int, session, start string) (peerRecord, error) {
	var p peerRecord
	b, e := privateRead(filepath.Join(registry, strconv.Itoa(pid)+".json"), messageLimit, 0022)
	if e != nil {
		return p, errIdentity
	}
	if e = decodeJSON(b, messageLimit, &p); e != nil {
		return p, e
	}
	if p.PID != pid || p.Session != session || p.Start != start || !identifier.MatchString(p.Name) {
		return p, errIdentity
	}
	proc, e := r.inspect(pid)
	if e != nil || proc.Start != start {
		return p, errIdentity
	}
	if _, e = checkPeerSocket(p.Socket); e != nil {
		return p, errIdentity
	}
	return p, nil
}
func (r *remoteRuntime) replacement(registry, session string) (*Mailbox, error) {
	files, e := jsonFiles(registry, 4096)
	if e != nil {
		return nil, e
	}
	var found *Mailbox
	for _, file := range files {
		pid, e := strconv.Atoi(strings.TrimSuffix(filepath.Base(file), ".json"))
		if e != nil || pid <= 1 {
			continue
		}
		var p peerRecord
		b, e := privateRead(file, messageLimit, 0022)
		if e != nil || decodeJSON(b, messageLimit, &p) != nil || p.PID != pid || p.Session != session || p.Proxy || len(p.Start) > 64 || !identifier.MatchString(p.Name) {
			continue
		}
		if _, e = r.endpoint(registry, pid, session, p.Start); e != nil {
			continue
		}
		if found != nil {
			return nil, errIdentity
		}
		found = &Mailbox{PID: pid, Start: p.Start, Name: p.Name}
	}
	return found, nil
}
func emit(out io.Writer, value any) error { return json.NewEncoder(out).Encode(value) }
func (r *remoteRuntime) send(ctx context.Context, registry string, target peerRecord, name string, mailbox Mailbox, in io.Reader, out io.Writer) error {
	box, e := r.endpoint(registry, mailbox.PID, name, mailbox.Start)
	if e != nil {
		return e
	}
	if box.Name != name {
		return errors.New("return mailbox changed")
	}
	data, e := readBounded(in, messageLimit)
	if e != nil {
		return e
	}
	m, e := parseEnvelope(data, false)
	if e != nil {
		return e
	}
	var key struct {
		Token string `json:"peerToken"`
		Start string `json:"procStart"`
	}
	b, e := privateRead(filepath.Join(registry, fmt.Sprintf("%d.%s.key", target.PID, hash([]byte(target.Socket)))), messageLimit, 0022)
	if e != nil {
		return e
	}
	if e = decodeJSON(b, messageLimit, &key); e != nil {
		return e
	}
	if key.Token == "" || (key.Start != "" && key.Start != target.Start) {
		return errors.New("recipient key changed")
	}
	body := strings.ReplaceAll(strings.ReplaceAll(m.Content, "<cross-session-message", "<\\cross-session-message"), "</cross-session-message>", "<\\/cross-session-message>")
	// Registry addresses are never interpolated as XML attributes unchecked.
	if strings.ContainsAny(box.Socket, "\"<>&\r\n") {
		return errors.New("invalid reply socket address")
	}
	mode := ""
	if m.PermissionClass == "prompting" || m.PermissionClass == "bypass" {
		mode = " from-mode=\"" + m.PermissionClass + "\""
	}
	content := fmt.Sprintf("<cross-session-message from=\"uds:%s\" from-session=\"%s\" from-name=\"%s\"%s>\n%s\n</cross-session-message>", box.Socket, name, name, mode, body)
	auth, _ := json.Marshal(map[string]string{"type": "auth", "token": key.Token})
	frame, _ := json.Marshal(map[string]any{"msgV": 1, "msg_id": m.ID, "type": "user", "priority": "next", "from": "uds:" + box.Socket, "message": map[string]string{"role": "user", "content": content}})
	payload := append(append(auth, '\n'), append(frame, '\n')...)
	if len(payload) > messageLimit {
		return errors.New("wrapped message exceeds limit")
	}
	conn, e := dialPeerSocket(ctx, target.Socket)
	if e != nil {
		return e
	}
	defer conn.Close()
	pid, uid, e := socketPeer(conn)
	if e != nil || uid != os.Getuid() || pid != target.PID {
		return errIdentity
	}
	current, e := r.endpoint(registry, target.PID, target.Session, target.Start)
	if e != nil || current.Socket != target.Socket {
		return errIdentity
	}
	for len(payload) > 0 {
		n, e := conn.Write(payload)
		if e != nil {
			return e
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		payload = payload[n:]
	}
	return emit(out, map[string]string{"type": "receipt", "id": m.ID, "receipt": "written_to_socket"})
}
func readLine(r *bufio.Reader, limit int) ([]byte, error) {
	b, e := r.ReadSlice('\n')
	if e != nil {
		return nil, e
	}
	if len(b) > limit {
		return nil, errors.New("line exceeds limit")
	}
	return b, nil
}
func parsePeerMessage(auth, frame []byte, secret string, target peerRecord) (Envelope, error) {
	var a struct {
		Type  string `json:"type"`
		Token string `json:"token"`
	}
	if decodeJSON(auth, messageLimit, &a) != nil || a.Type != "auth" || subtle.ConstantTimeCompare([]byte(a.Token), []byte(secret)) != 1 {
		return Envelope{}, errors.New("authentication rejected")
	}
	var p struct {
		Type    string `json:"type"`
		From    string `json:"from"`
		ID      string `json:"msg_id"`
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	}
	if e := decodeJSON(frame, messageLimit, &p); e != nil {
		return Envelope{}, e
	}
	if p.Type != "user" || p.From != "uds:"+target.Socket || !messageID.MatchString(p.ID) {
		return Envelope{}, errors.New("sender mismatch")
	}
	return Envelope{ID: p.ID, Sender: target.Name, Content: p.Message.Content}, nil
}
func (r *remoteRuntime) listen(ctx context.Context, registry string, target peerRecord, name string, out io.Writer) error {
	root := mailboxRoot(os.Getuid())
	if e := privateDirectory(root, true); e != nil {
		return e
	}
	directory := filepath.Join(root, hash([]byte(name))[:24])
	if e := privateDirectory(directory, true); e != nil {
		return e
	}
	lock, e := fileLock(filepath.Join(directory, "lock"), true)
	if e != nil {
		if errors.Is(e, syscall.EWOULDBLOCK) {
			return emit(out, map[string]string{"type": "mailbox_busy"})
		}
		return e
	}
	defer lock.Close()
	path := filepath.Join(directory, "peer.sock")
	if exists(path) {
		st, e := os.Lstat(path)
		if e != nil {
			return e
		}
		owner, ok := st.Sys().(*syscall.Stat_t)
		if !ok || st.Mode()&os.ModeSocket == 0 || int(owner.Uid) != os.Getuid() {
			return errors.New("unsafe stale mailbox")
		}
		if e = os.Remove(path); e != nil {
			return e
		}
	}
	listener, e := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if e != nil {
		return e
	}
	listener.SetUnlinkOnClose(false)
	defer listener.Close()
	defer os.Remove(path)
	if e = os.Chmod(path, 0600); e != nil {
		return e
	}
	ownPID := os.Getpid()
	own, e := r.inspect(ownPID)
	if e != nil {
		return e
	}
	var secretBytes [16]byte
	if _, e = rand.Read(secretBytes[:]); e != nil {
		return e
	}
	secret := hex.EncodeToString(secretBytes[:])
	recordPath := filepath.Join(registry, strconv.Itoa(ownPID)+".json")
	keyPath := filepath.Join(registry, fmt.Sprintf("%d.%s.key", ownPID, hash([]byte(path))))
	now := time.Now().UnixMilli()
	record := map[string]any{"pid": ownPID, "name": name, "sessionId": name, "procStart": own.Start, "cwd": target.CWD, "messagingSocketPath": path, "relayProxy": true, "status": "idle", "startedAt": now, "updatedAt": now, "nameSince": now, "statusUpdatedAt": now, "version": "2.1.239", "peerProtocol": 1, "peerFeatures": []string{"notify_idle"}, "kind": "interactive", "entrypoint": "cli"}
	if e = exclusiveJSON(keyPath, map[string]string{"peerToken": secret, "procStart": own.Start}); e != nil {
		return e
	}
	defer os.Remove(keyPath)
	if e = exclusiveJSON(recordPath, record); e != nil {
		return e
	}
	defer os.Remove(recordPath)
	if e = emit(out, map[string]any{"type": "ready", "pid": ownPID, "start": own.Start, "name": name, "peer": target.Name, "drain": 1, "account": filepath.Dir(registry)}); e != nil {
		return e
	}
	last := time.Time{}
	draining := false
	for {
		if ctx.Err() != nil && !draining {
			draining = true
			os.Remove(recordPath)
			os.Remove(keyPath)
			os.Remove(path)
		}
		if !draining {
			current, e := r.endpoint(registry, target.PID, target.Session, target.Start)
			if e != nil || current.Socket != target.Socket {
				return errIdentity
			}
			if time.Since(last) >= 10*time.Second {
				record["updatedAt"] = time.Now().UnixMilli()
				if e = atomicJSON(recordPath, record); e != nil {
					return e
				}
				if e = emit(out, map[string]string{"type": "heartbeat"}); e != nil {
					return e
				}
				last = time.Now()
			}
		}
		delay := time.Second
		if draining {
			delay = 200 * time.Millisecond
		}
		listener.SetDeadline(time.Now().Add(delay))
		conn, e := listener.AcceptUnix()
		if e != nil {
			if ne, ok := e.(net.Error); ok && ne.Timeout() {
				if draining {
					return nil
				}
				continue
			}
			return e
		}
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		reader := bufio.NewReaderSize(conn, messageLimit+1)
		auth, ae := readLine(reader, messageLimit)
		var m Envelope
		if ae == nil {
			var frame []byte
			frame, ae = readLine(reader, messageLimit)
			if ae == nil {
				m, ae = parsePeerMessage(auth, frame, secret, target)
			}
		}
		// Native helpers may send for their exact registered agent; keep the
		// authenticated token and source-address checks, with kernel UID.
		_, uid, pe := socketPeer(conn)
		conn.Close()
		if ae != nil || pe != nil || uid != os.Getuid() {
			if e = emit(out, map[string]string{"type": "rejected"}); e != nil {
				return e
			}
			continue
		}
		if e = emit(out, map[string]string{"type": "message", "id": m.ID, "sender": m.Sender, "content": m.Content}); e != nil {
			return e
		}
	}
}
func RunRemote(ctx context.Context, args []string, in io.Reader, out io.Writer) error {
	home, e := os.UserHomeDir()
	if e != nil {
		return e
	}
	r := &remoteRuntime{home, inspectProcess, agentlaunch.ProcessEnvironment}
	return r.run(ctx, args, in, out)
}
func (r *remoteRuntime) identityEvent(registry, session, account string, out io.Writer) error {
	// An empty registry means the live owner could not be resolved. Only the
	// account the route recorded is searched, and never the default by fallback.
	if registry == "" {
		if account == "" {
			return emit(out, map[string]string{"type": "identity_missing"})
		}
		registry = filepath.Join(account, "sessions")
	}
	if e := privateDirectory(registry, false); e != nil {
		return emit(out, map[string]string{"type": "identity_missing"})
	}
	replacement, e := r.replacement(registry, session)
	if e != nil {
		return emit(out, map[string]string{"type": "identity_changed"})
	}
	if replacement == nil {
		return emit(out, map[string]string{"type": "identity_missing"})
	}
	return emit(out, map[string]any{"type": "identity_replacement", "session": session, "pid": replacement.PID, "start": replacement.Start, "name": replacement.Name})
}
func (r *remoteRuntime) run(ctx context.Context, args []string, in io.Reader, out io.Writer) error {
	if len(args) != 5 && len(args) != 6 && len(args) != 7 {
		return errors.New("desktop-remote requires exact mode and process identity")
	}
	mode := args[0]
	pid, e := strconv.Atoi(args[1])
	if e != nil || pid <= 1 || !identifier.MatchString(args[2]) || !identifier.MatchString(args[4]) {
		return errors.New("invalid remote identity")
	}
	if (mode == "send" && len(args) != 7) || (mode == "listen" && len(args) != 5 && len(args) != 6) || (mode != "send" && mode != "listen") {
		return errors.New("invalid remote mode")
	}
	// The optional sixth listen argument is the owner account the route recorded.
	account := ""
	if mode == "listen" && len(args) == 6 {
		account = args[5]
		if !filepath.IsAbs(account) || filepath.Clean(account) != account || len(account) > 4096 || strings.ContainsRune(account, 0) {
			return errors.New("invalid recorded owner account")
		}
	}
	registry, e := r.registry(pid, args[3])
	if e != nil {
		if mode == "listen" && errors.Is(e, errIdentity) {
			return r.identityEvent(registry, args[2], account, out)
		}
		return e
	}
	target, e := r.endpoint(registry, pid, args[2], args[3])
	if e != nil {
		if mode == "listen" && errors.Is(e, errIdentity) {
			return r.identityEvent(registry, args[2], account, out)
		}
		return e
	}
	if mode == "send" {
		boxPID, e := strconv.Atoi(args[5])
		if e != nil {
			return e
		}
		return r.send(ctx, registry, target, args[4], Mailbox{PID: boxPID, Start: args[6]}, in, out)
	}
	e = r.listen(ctx, registry, target, args[4], out)
	if errors.Is(e, errIdentity) {
		return r.identityEvent(registry, args[2], account, out)
	}
	return e
}

// The typed daemon listener registry and historical desktop workers use this
// fixed address space. TMPDIR must never relocate a live reply mailbox.
func mailboxRoot(uid int) string { return filepath.Join("/tmp", fmt.Sprintf("relay-desktop-%d", uid)) }

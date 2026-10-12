package peernet

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

const MaxFrame = 65536

type Config struct {
	Home, Name, Session, Label                   string
	PID                                          int
	ExpectedName, ExpectedSession, ExpectedStart string
	OnEvent                                      func(Event)
}

// Event contains transport metadata only; it never includes message bodies or keys.
type Event struct {
	State        string `json:"state"`
	Peer         string `json:"peer,omitempty"`
	ProcessStart string `json:"processStart,omitempty"`
	MessageID    string `json:"messageId,omitempty"`
	Receipt      string `json:"receipt,omitempty"`
	RTTMillis    int64  `json:"rttMillis,omitempty"`
}
type frame struct {
	PermissionClass string `json:"permissionClass,omitempty"`
	Version         int    `json:"version,omitempty"`
	Type            string `json:"type"`
	Name            string `json:"name,omitempty"`
	Session         string `json:"session,omitempty"`
	ID              string `json:"id,omitempty"`
	Body            string `json:"body,omitempty"`
	Status          string `json:"status,omitempty"`
	Start           string `json:"start,omitempty"`
}
type wire struct {
	sync.Mutex
	out io.Writer
}

// deliveryStatus retains the outcome for each ID. A failed socket write may
// have been partial, so a repeat is not retried or mislabeled as delivered.
func deliveryStatus(seen map[string]string, id string, write func() error) (string, error) {
	if status, ok := seen[id]; ok {
		if status == "socket-written" {
			return "duplicate", nil
		}
		return status, nil
	}
	if len(seen) >= 4096 {
		return "", errors.New("link message budget reached")
	}
	status := "socket-written"
	err := write()
	if err != nil {
		status = "failed"
	}
	seen[id] = status
	return status, err
}

// Reserve before socket I/O. A process restart cannot turn an uncertain write
// into a fresh attempt. Identity and content conflicts fail closed.
func durableDelivery(c Config, peer frame, f frame, write func() error) (string, error) {
	dir := filepath.Join(c.Home, ".local", "state", "relay", "peer-deliveries")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return "", errors.New("unsafe delivery directory")
	}
	if owner, ok := info.Sys().(*syscall.Stat_t); !ok || owner.Uid != uint32(os.Getuid()) {
		return "", errors.New("delivery directory owner mismatch")
	}
	identity := sha256.Sum256([]byte(c.Session + "\x00" + peer.Session + "\x00" + f.ID))
	fingerprint := sha256.Sum256([]byte(peer.Name + "\x00" + f.Body + "\x00" + f.PermissionClass))
	path := filepath.Join(dir, fmt.Sprintf("%x.json", identity))
	type record struct {
		Fingerprint string `json:"fingerprint"`
		Status      string `json:"status"`
	}
	value := record{fmt.Sprintf("%x", fingerprint), "failed"}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if os.IsExist(err) {
		info, e := os.Lstat(path)
		if e != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 4096 {
			return "", errors.New("unsafe delivery record")
		}
		if owner, ok := info.Sys().(*syscall.Stat_t); !ok || owner.Uid != uint32(os.Getuid()) {
			return "", errors.New("delivery record owner mismatch")
		}
		data, e := os.ReadFile(path)
		var prior record
		if e != nil || json.Unmarshal(data, &prior) != nil || prior.Fingerprint != value.Fingerprint {
			return "", errors.New("delivery ID conflict or uncertain reservation")
		}
		if prior.Status == "socket-written" {
			return "duplicate", nil
		}
		return "failed", nil
	}
	if err != nil {
		return "", err
	}
	data, _ := json.Marshal(value)
	_, err = file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	file.Close()
	if err != nil {
		return "", err
	}
	directory, err := os.Open(dir)
	if err != nil {
		return "", err
	}
	defer directory.Close()
	if err = directory.Sync(); err != nil {
		return "", err
	}
	if err = write(); err != nil {
		return "failed", err
	}
	value.Status = "socket-written"
	data, _ = json.Marshal(value)
	temp, err := os.CreateTemp(dir, ".delivery-")
	if err != nil {
		return "failed", err
	}
	defer os.Remove(temp.Name())
	_, err = temp.Write(data)
	if err == nil {
		err = temp.Sync()
	}
	temp.Close()
	if err == nil {
		err = os.Rename(temp.Name(), path)
	}
	if err == nil {
		err = directory.Sync()
	}
	if err != nil {
		return "failed", err
	}
	return "socket-written", nil
}

func (w *wire) send(f frame) error {
	w.Lock()
	defer w.Unlock()
	b, e := json.Marshal(f)
	if e != nil {
		return e
	}
	if len(b) > MaxFrame {
		return errors.New("frame too large")
	}
	_, e = w.out.Write(append(b, '\n'))
	return e
}
func line(r *bufio.Reader) ([]byte, error) {
	b, e := r.ReadSlice('\n')
	if e != nil {
		return nil, e
	}
	if len(b) > MaxFrame {
		return nil, errors.New("frame too large")
	}
	return b, nil
}

// Run serves a single link until disconnect. The caller owns and closes stream.
// No message retries: a broken stream makes in-flight delivery ambiguous.
func Run(ctx context.Context, stream io.ReadWriteCloser, c Config, log io.Writer) error {
	if !identifier.MatchString(c.Label) || !identifier.MatchString(c.Name) || len(c.Label)+len(c.Name) > 110 {
		return errors.New("invalid endpoint label")
	}
	target, e := Resolve(c.Home, c.Name, c.Session, c.PID)
	if e != nil {
		return e
	}
	defer stream.Close()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() { <-ctx.Done(); stream.Close() }()
	w := &wire{out: stream}
	r := bufio.NewReaderSize(stream, MaxFrame+1)
	handshake := time.AfterFunc(15*time.Second, cancel)
	defer handshake.Stop()
	if e = w.send(frame{Version: 1, Type: "hello", Name: c.Label + "--" + c.Name, Session: c.Session, Start: target.Start}); e != nil {
		return e
	}
	b, e := line(r)
	if e != nil {
		return e
	}
	var peer frame
	if e = json.Unmarshal(b, &peer); e != nil {
		return e
	}
	if peer.Version != 1 || peer.Type != "hello" || !identifier.MatchString(peer.Name) || !identifier.MatchString(peer.Session) || peer.Start == "" || len(peer.Start) > 128 {
		return errors.New("invalid peer handshake")
	}
	if (c.ExpectedName != "" && c.ExpectedName != peer.Name) || (c.ExpectedSession != "" && c.ExpectedSession != peer.Session) || (c.ExpectedStart != "" && c.ExpectedStart != peer.Start) {
		return errors.New("remote endpoint identity changed")
	}
	handshake.Stop()
	dir, e := os.MkdirTemp("/tmp", "relay-peer-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "peer.sock")
	listener, e := net.Listen("unix", path)
	if e != nil {
		return e
	}
	defer listener.Close()
	reg, e := register(c.Home, path, peer.Name, peer.Session)
	if e != nil {
		return e
	}
	defer reg.close()
	// Refresh and cleanup have one owner: the loop below. No late heartbeat can
	// resurrect a removed registration.
	fmt.Fprintln(log, "peer link online:", peer.Name)
	emit := func(event Event) {
		if c.OnEvent != nil {
			c.OnEvent(event)
		}
	}
	emit(Event{State: "online", Peer: peer.Name, ProcessStart: peer.Start})
	defer emit(Event{State: "offline", Peer: peer.Name})
	incoming := make(chan frame, 16)
	fail := make(chan error, 1)
	go func() {
		for frames := 0; ; frames++ {
			if frames >= 16384 {
				select {
				case fail <- errors.New("link frame budget reached"):
				default:
				}
				return
			}
			b, e := line(r)
			if e != nil {
				select {
				case fail <- e:
				default:
				}
				return
			}
			var f frame
			if e = json.Unmarshal(b, &f); e != nil {
				select {
				case fail <- e:
				default:
				}
				return
			}
			select {
			case incoming <- f:
			case <-ctx.Done():
				return
			}
		}
	}()
	go func() { <-ctx.Done(); listener.Close() }()
	slots := make(chan struct{}, 8)
	go func() {
		for connections := 0; ; connections++ {
			if connections >= 4096 {
				select {
				case fail <- errors.New("link connection budget reached"):
				default:
				}
				return
			}
			conn, e := listener.Accept()
			if e != nil {
				return
			}
			select {
			case slots <- struct{}{}:
				go func() {
					defer func() { <-slots }()
					defer conn.Close()
					if err := acceptNative(conn, reg.secret, target, w, c.Home); err != nil {
						fmt.Fprintln(log, "peer message rejected:", err)
					}
				}()
			default:
				conn.Close()
			}
		}
	}()
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	last := time.Now()
	var pingAt time.Time
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case e := <-fail:
			return e
		case <-tick.C:
			if time.Since(last) > 20*time.Second {
				return errors.New("peer heartbeat timeout")
			}
			current, e := Resolve(c.Home, c.Name, c.Session, c.PID)
			if e != nil || !sameEndpoint(current, target) {
				return errors.New("recipient changed or exited")
			}
			if e = reg.refresh(); e != nil {
				return e
			}
			pingAt = time.Now()
			if e = w.send(frame{Type: "ping"}); e != nil {
				return e
			}
		case f := <-incoming:
			last = time.Now()
			switch f.Type {
			case "ping":
				if e = w.send(frame{Type: "pong"}); e != nil {
					return e
				}
			case "pong":
				if !pingAt.IsZero() {
					emit(Event{State: "online", Peer: peer.Name, RTTMillis: time.Since(pingAt).Milliseconds()})
				}
			case "receipt":
				if !identifier.MatchString(f.ID) || (f.Status != "socket-written" && f.Status != "failed" && f.Status != "duplicate") {
					return errors.New("invalid receipt")
				}
				fmt.Fprintf(log, "peer receipt %s %s\n", f.ID, f.Status)
				emit(Event{State: "online", Peer: peer.Name, MessageID: f.ID, Receipt: f.Status})
			case "message":
				if !identifier.MatchString(f.ID) || len(f.Body) > 32768 {
					return errors.New("invalid message")
				}
				status, deliveryErr := durableDelivery(c, peer, f, func() error {
					return deliver(c, target, path, peer, f)
				})
				if status == "" {
					return deliveryErr
				}
				if deliveryErr != nil {
					fmt.Fprintln(log, "peer delivery failed:", deliveryErr)
				}
				if e = w.send(frame{Type: "receipt", ID: f.ID, Status: status}); e != nil {
					return e
				}
			default:
				return errors.New("unknown link frame")
			}
		}
	}
}

type nativeFrame struct {
	Type    string `json:"type"`
	Token   string `json:"token"`
	ID      string `json:"msg_id"`
	From    string `json:"from"`
	Message struct {
		Content string `json:"content"`
	} `json:"message"`
}

func acceptNative(conn net.Conn, secret string, target Record, w *wire, homes ...string) error {
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	r := bufio.NewReaderSize(conn, MaxFrame+1)
	b, e := line(r)
	if e != nil {
		return e
	}
	var a nativeFrame
	if e = json.Unmarshal(b, &a); e != nil {
		return e
	}
	if a.Type != "auth" || subtle.ConstantTimeCompare([]byte(a.Token), []byte(secret)) != 1 {
		return errors.New("authentication failed")
	}
	b, e = line(r)
	if e != nil {
		return e
	}
	var f nativeFrame
	if e = json.Unmarshal(b, &f); e != nil {
		return e
	}
	if f.Type != "user" || !identifier.MatchString(f.ID) || f.From != "uds:"+target.Socket {
		return errors.New("sender is not the configured endpoint")
	}
	body := f.Message.Content
	permissionClass := ""
	if strings.HasPrefix(body, "<cross-session-message ") {
		end := strings.Index(body, ">")
		close := strings.LastIndex(body, "</cross-session-message>")
		if end < 0 || close < end {
			return errors.New("invalid envelope")
		}
		// Preserve the native provider's attestation from the authenticated
		// configured sender. Message bodies cannot replace the outer envelope.
		opening := body[:end]
		if match := regexp.MustCompile(` from-mode="(prompting|bypass)"`).FindStringSubmatch(opening); len(match) == 2 {
			permissionClass = match[1]
		}
		body = strings.TrimSpace(body[end+1 : close])
	}
	if len(body) == 0 || len(body) > 32768 {
		return errors.New("invalid message size")
	}
	if len(homes) == 1 {
		if verified := runtimePermissionClass(homes[0], target); verified != "" {
			permissionClass = verified
		}
	}
	return w.send(frame{Type: "message", ID: f.ID, Body: body, PermissionClass: permissionClass})
}

// A path can be reused after a restart. Bind delivery to the original process
// incarnation as well as its logical identity and socket.
func sameEndpoint(current, target Record) bool {
	return current.PID == target.PID && current.Name == target.Name &&
		current.Session == target.Session && current.Socket == target.Socket &&
		current.Start != "" && current.Start == target.Start
}

func deliver(c Config, target Record, proxy string, peer frame, f frame) error {
	current, e := Resolve(c.Home, c.Name, c.Session, c.PID)
	if e != nil {
		return e
	}
	if !sameEndpoint(current, target) {
		return errors.New("recipient identity changed")
	}
	secret, e := token(c.Home, current)
	if e != nil {
		return e
	}
	conn, e := net.DialTimeout("unix", current.Socket, 5*time.Second)
	if e != nil {
		return e
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	// Escape nested envelopes so payload cannot replace the transport attribution.
	body := strings.ReplaceAll(strings.ReplaceAll(f.Body, "<cross-session-message", "<\\cross-session-message"), "</cross-session-message>", "<\\/cross-session-message>")
	modeAttribute := ""
	if f.PermissionClass == "prompting" || f.PermissionClass == "bypass" {
		modeAttribute = fmt.Sprintf(" from-mode=\"%s\"", f.PermissionClass)
	}
	content := fmt.Sprintf("<cross-session-message from=\"uds:%s\" from-session=\"%s\" from-name=\"%s\"%s>\n%s\n</cross-session-message>", proxy, peer.Session, peer.Name, modeAttribute, body)
	enc := json.NewEncoder(conn)
	if e = enc.Encode(map[string]any{"type": "auth", "token": secret}); e != nil {
		return e
	}
	return enc.Encode(map[string]any{"msgV": 1, "msg_id": f.ID, "type": "user", "priority": "next", "from": "uds:" + proxy, "message": map[string]string{"role": "user", "content": content}})
}

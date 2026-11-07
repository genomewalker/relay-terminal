// Package peernet provides an opt-in, two-session SSH link for native peer sockets.
// It is not a durable queue and never grants execution authority to messages.
package peernet

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var identifier = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,110}$`)

type Record struct {
	RelayProxy bool   `json:"relayProxy"`
	PID        int    `json:"pid"`
	Name       string `json:"name"`
	Session    string `json:"sessionId"`
	Socket     string `json:"messagingSocketPath"`
	Start      string `json:"procStart"`
	Cwd        string `json:"cwd"`
}

func processStart(pid int) (string, error) {
	if pid <= 0 {
		return "", errors.New("invalid PID")
	}
	if runtime.GOOS == "linux" {
		b, e := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
		if e != nil {
			return "", e
		}
		end := strings.LastIndex(string(b), ")")
		if end < 0 {
			return "", errors.New("invalid proc stat")
		}
		fields := strings.Fields(string(b)[end+1:])
		if len(fields) < 20 {
			return "", errors.New("short proc stat")
		}
		return fields[19], nil
	}
	c := exec.Command("/bin/ps", "-p", strconv.Itoa(pid), "-o", "lstart=")
	c.Env = append(os.Environ(), "TZ=UTC", "LC_ALL=C")
	b, e := c.Output()
	return strings.TrimSpace(string(b)), e
}

func readPrivate(path string, limit int64) ([]byte, error) {
	s, e := os.Lstat(path)
	if e != nil {
		return nil, e
	}
	st, ok := s.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != os.Getuid() || !s.Mode().IsRegular() || s.Size() > limit || s.Mode().Perm()&0022 != 0 {
		return nil, errors.New("unsafe peer record")
	}
	return os.ReadFile(path)
}

// Resolve selects one specific live process. Both session and PID are mandatory:
// two processes can advertise the same Claude session ID after a resume.
func Resolve(home, name, session string, pid int) (Record, error) {
	var r Record
	config, e := claudeConfig(home, pid)
	if e != nil {
		return r, e
	}
	b, e := readPrivate(filepath.Join(config, "sessions", fmt.Sprintf("%d.json", pid)), 16384)
	if e != nil {
		return r, e
	}
	if e = json.Unmarshal(b, &r); e != nil {
		return r, e
	}
	if r.PID != pid || r.Name != name || r.Session != session || !identifier.MatchString(name) || !identifier.MatchString(session) {
		return r, errors.New("recipient identity mismatch")
	}
	start, e := processStart(pid)
	if e != nil || start == "" || r.Start == "" || start != r.Start {
		return r, errors.New("recipient process replaced or unavailable")
	}
	s, e := os.Lstat(r.Socket)
	if e != nil {
		return r, e
	}
	st, ok := s.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != os.Getuid() || s.Mode()&os.ModeSocket == 0 {
		return r, errors.New("unsafe recipient socket")
	}
	return r, nil
}

func token(home string, r Record) (string, error) {
	h := sha256.Sum256([]byte(r.Socket))
	config, e := claudeConfig(home, r.PID)
	if e != nil {
		return "", e
	}
	b, e := readPrivate(filepath.Join(config, "sessions", fmt.Sprintf("%d.%x.key", r.PID, h)), 4096)
	if e != nil {
		return "", e
	}
	var k struct {
		Token string `json:"peerToken"`
	}
	e = json.Unmarshal(b, &k)
	if len(k.Token) < 16 || len(k.Token) > 256 {
		return "", errors.New("invalid peer token")
	}
	return k.Token, e
}

func atomicJSON(path string, v any) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".relay-peer-")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if _, e = f.Write(b); e != nil {
		return e
	}
	if e = f.Close(); e != nil {
		return e
	}
	return os.Rename(f.Name(), path)
}

type registration struct {
	socket, record, key, secret string
	value                       map[string]any
}

func register(home, socket, name, session string) (*registration, error) {
	own, e := ownClaudeConfig(home)
	if e != nil {
		return nil, e
	}
	dir := filepath.Join(own, "sessions")
	if e := os.MkdirAll(dir, 0700); e != nil {
		return nil, e
	}
	st, e := os.Lstat(dir)
	if e != nil {
		return nil, e
	}
	owner, ok := st.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() || !st.IsDir() || st.Mode().Perm()&0077 != 0 {
		return nil, errors.New("registry must be private and owned by current user")
	}
	pid := os.Getpid()
	start, e := processStart(pid)
	if e != nil {
		return nil, e
	}
	// Claude's native registry validates exactly 32 hexadecimal characters.
	// Match its 128-bit peer token format, not a longer incompatible token.
	b := make([]byte, 16)
	if _, e = rand.Read(b); e != nil {
		return nil, e
	}
	secret := hex.EncodeToString(b)
	h := sha256.Sum256([]byte(socket))
	now := time.Now().UnixMilli()
	r := &registration{socket: socket, record: filepath.Join(dir, fmt.Sprintf("%d.json", pid)), key: filepath.Join(dir, fmt.Sprintf("%d.%x.key", pid, h)), secret: secret}
	if _, e = os.Lstat(r.record); !os.IsNotExist(e) {
		return nil, errors.New("refusing to replace existing process registry")
	}
	r.value = map[string]any{"pid": pid, "sessionId": session, "cwd": "/", "procStart": start, "name": name, "nameSource": "user", "nameSince": now, "startedAt": now, "updatedAt": now, "statusUpdatedAt": now, "status": "idle", "version": "2.1.239", "peerProtocol": 1, "peerFeatures": []string{"notify_idle"}, "kind": "interactive", "entrypoint": "cli", "messagingSocketPath": socket, "relayProxy": true}
	key := map[string]any{"peerToken": secret, "procStart": start}
	if runtime.GOOS == "darwin" {
		r.value["pidDomain"] = "darwin"
		key["pidDomain"] = "darwin"
	}
	if e = atomicJSON(r.key, key); e != nil {
		return nil, e
	}
	if e = r.refresh(); e != nil {
		os.Remove(r.key)
		return nil, e
	}
	return r, nil
}
func (r *registration) refresh() error {
	r.value["updatedAt"] = time.Now().UnixMilli()
	return atomicJSON(r.record, r.value)
}
func (r *registration) close() { os.Remove(r.record); os.Remove(r.key); os.Remove(r.socket) }

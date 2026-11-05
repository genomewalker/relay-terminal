package appupdate

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"time"
)

type Command struct {
	Args    []string
	Timeout time.Duration
}
type Runner func(Command) ([]byte, error)
type Watcher interface {
	Register(int) error
	Wait(int, time.Duration) ([]int, error)
	Close() error
}
type Config struct {
	Home, Installed, TempRoot, LockRoot, APIURL string
	UID                                         int
}
type Engine struct {
	Config Config
	Run    Runner
	Kernel func(int) (string, error)
	Watch  func() (Watcher, error)
	Client *http.Client
	Now    func() time.Time
}

func New() (*Engine, error) {
	home, e := os.UserHomeDir()
	if e != nil {
		return nil, e
	}
	return &Engine{Config: Config{Home: home, Installed: "/Applications/Relay.app", TempRoot: "/private/tmp", LockRoot: os.TempDir(), APIURL: "http://127.0.0.1:47471/api/state", UID: os.Getuid()}, Run: execute, Kernel: kernelIdentity, Watch: newWatcher, Client: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("state redirects forbidden") }}, Now: time.Now}, nil
}

type limitedBuffer struct {
	bytes.Buffer
	overflow bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	if b.Len()+n > maxState {
		b.overflow = true
		room := maxState - b.Len()
		if room > 0 {
			b.Buffer.Write(p[:room])
		}
		return n, nil
	}
	return b.Buffer.Write(p)
}
func execute(c Command) ([]byte, error) {
	ctx := context.Background()
	var cancel context.CancelFunc
	if c.Timeout > 0 {
		ctx, cancel = context.WithTimeout(ctx, c.Timeout)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, c.Args[0], c.Args[1:]...)
	var b limitedBuffer
	cmd.Stdout = &b
	cmd.Stderr = os.Stderr
	e := cmd.Run()
	if b.overflow {
		return nil, errors.New("command output exceeds bound")
	}
	return b.Bytes(), e
}
func (e *Engine) command(timeout time.Duration, args ...string) ([]byte, error) {
	return e.Run(Command{Args: args, Timeout: timeout})
}
func readBound(p string) ([]byte, error) {
	f, e := os.Open(p)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	b, e := io.ReadAll(io.LimitReader(f, maxState+1))
	if len(b) > maxState {
		return nil, errors.New("file exceeds state bound")
	}
	return b, e
}
func sumFile(p string) (string, error) {
	f, e := os.Open(p)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	_, e = io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), e
}
func contained(root, p string) bool {
	r, e := filepath.Rel(root, p)
	return e == nil && r != ".." && !strings.HasPrefix(r, ".."+string(filepath.Separator)) && !filepath.IsAbs(r)
}
func Hashes(root string) (map[string]string, error) {
	out := map[string]string{}
	info, e := os.Stat(root)
	if os.IsNotExist(e) {
		return out, nil
	}
	if e != nil {
		return nil, e
	}
	if !info.IsDir() {
		return nil, errors.New("hash root is not a directory")
	}
	base, e := filepath.EvalSymlinks(root)
	if e != nil {
		return nil, e
	}
	count := 0
	e = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		count++
		if count > 100000 {
			return errors.New("bundle entry bound exceeded")
		}
		if d.IsDir() {
			return nil
		}
		info, err := os.Stat(p)
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		if !info.Mode().IsRegular() {
			return errors.New("bundle contains nonregular file")
		}
		resolved, err := filepath.EvalSymlinks(p)
		if err != nil || !contained(base, resolved) {
			return errors.New("bundle symlink escapes root")
		}
		h, err := sumFile(p)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		out[filepath.ToSlash(rel)] = h
		return nil
	})
	return out, e
}
func syncDirectory(p string) error {
	f, e := os.Open(p)
	if e != nil {
		return e
	}
	defer f.Close()
	return f.Sync()
}
func privateInfo(fd int, uid int) error {
	var s unix.Stat_t
	if e := unix.Fstat(fd, &s); e != nil {
		return e
	}
	if int(s.Uid) != uid || s.Mode&unix.S_IFMT != unix.S_IFREG || s.Mode&0077 != 0 || s.Nlink != 1 {
		return errors.New("private file ownership/mode invalid")
	}
	return nil
}
func lockFile(path string, uid int) (*os.File, error) {
	fd, e := unix.Open(path, unix.O_RDWR|unix.O_CREAT|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), path)
	if e = privateInfo(fd, uid); e != nil {
		f.Close()
		return nil, e
	}
	if e = unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); e != nil {
		f.Close()
		return nil, e
	}
	return f, nil
}
func readPrivate(path string, uid int) ([]byte, error) {
	fd, e := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	if e = privateInfo(fd, uid); e != nil {
		return nil, e
	}
	b, e := io.ReadAll(io.LimitReader(f, maxState+1))
	if len(b) > maxState {
		return nil, errors.New("receipt exceeds bound")
	}
	return b, e
}
func writePrivate(path string, data []byte) error {
	fd, e := unix.Open(path, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if e != nil {
		return e
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	if e = f.Chmod(0600); e != nil {
		return e
	}
	if _, e = f.Write(data); e != nil {
		return e
	}
	if e = f.Sync(); e != nil {
		return e
	}
	return syncDirectory(filepath.Dir(path))
}
func writeRecord(path string, v any) error { return writePrivate(path, jsonData(v)) }
func absolute(p string) (string, error) {
	p, e := filepath.Abs(p)
	if e != nil {
		return "", e
	}
	return filepath.EvalSymlinks(p)
}
func (e *Engine) receiptRoot(p string) (string, error) {
	root, err := absolute(p)
	if err != nil {
		return "", err
	}
	base, err := absolute(e.Config.TempRoot)
	if err != nil {
		return "", err
	}
	if filepath.Dir(root) != base || !strings.HasPrefix(filepath.Base(root), "relay-interface-update-") {
		return "", errors.New("invalid preservation root path")
	}
	var s unix.Stat_t
	if err = unix.Lstat(root, &s); err != nil {
		return "", err
	}
	if s.Mode&unix.S_IFMT != unix.S_IFDIR || int(s.Uid) != e.Config.UID || s.Mode&0077 != 0 {
		return "", errors.New("invalid preservation root ownership")
	}
	return root, nil
}
func (e *Engine) plist(p string) (map[string]any, error) {
	raw, err := readBound(p)
	if err != nil {
		return nil, err
	}
	if bytes.HasPrefix(raw, []byte("bplist")) {
		raw, err = e.command(15*time.Second, "/usr/bin/plutil", "-convert", "xml1", "-o", "-", p)
		if err != nil {
			return nil, err
		}
	}
	return parsePlist(raw)
}
func (e *Engine) preferences() string {
	return filepath.Join(e.Config.Home, "Library/Preferences/dev.relay.terminal.plist")
}
func (e *Engine) support() string {
	return filepath.Join(e.Config.Home, "Library/Application Support/Relay")
}
func (e *Engine) workspace(prefs map[string]any, authority string) (map[string]any, string, error) {
	shared := filepath.Join(e.support(), "Workspace/workspace-v1.json")
	if authority == "" {
		if _, err := os.Lstat(shared); err == nil {
			authority = "shared"
		} else if os.IsNotExist(err) {
			authority = "preferences"
		} else {
			return nil, "", err
		}
	}
	var b []byte
	var err error
	switch authority {
	case "shared":
		s, x := os.Lstat(shared)
		if x != nil {
			return nil, "", x
		}
		if !s.Mode().IsRegular() {
			return nil, "", errors.New("shared workspace unavailable")
		}
		b, err = readBound(shared)
	case "preferences":
		switch v := prefs["relay.workspace.v1"].(type) {
		case string:
			b = []byte(v)
		case []byte:
			b = v
		default:
			return nil, "", errors.New("saved workspace unavailable")
		}
	default:
		return nil, "", errors.New("unknown workspace authority")
	}
	if err != nil {
		return nil, "", err
	}
	v, err := object(b)
	return v, authority, err
}
func (e *Engine) state() (map[string]any, error) {
	prefs, err := e.plist(e.preferences())
	if err != nil {
		return nil, err
	}
	token, ok := prefs["relay.side-panel-token.v1"].(string)
	if !ok || token == "" {
		return nil, errors.New("state authentication unavailable")
	}
	request, err := http.NewRequest("GET", e.Config.APIURL, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("X-Relay-Token", token)
	response, err := e.Client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return nil, errors.New("state request failed")
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxState+1))
	if err != nil {
		return nil, err
	}
	return object(raw)
}
func (e *Engine) signature(bundle string) error {
	_, err := e.command(60*time.Second, "/usr/bin/codesign", "--verify", "--deep", "--strict", bundle)
	return err
}
func (e *Engine) verifyBundle(bundle string) (string, error) {
	info, err := e.plist(filepath.Join(bundle, "Contents/Info.plist"))
	if err != nil {
		return "", err
	}
	if info["CFBundleIdentifier"] != "dev.relay.terminal" {
		return "", errors.New("candidate is not a Relay bundle")
	}
	if err = e.signature(bundle); err != nil {
		return "", err
	}
	return sumFile(filepath.Join(bundle, "Contents/MacOS/Relay"))
}
func parseProcesses(raw []byte) (map[int]string, error) {
	if len(raw) > maxState {
		return nil, errors.New("process listing bound exceeded")
	}
	out := map[int]string{}
	for _, row := range strings.Split(string(raw), "\n") {
		row = strings.TrimSpace(row)
		if row == "" {
			continue
		}
		i := strings.IndexAny(row, " \t")
		if i < 0 {
			continue
		}
		pid, err := strconv.Atoi(row[:i])
		if err != nil || pid <= 0 || pid > 1<<31-1 {
			return nil, errors.New("invalid process id")
		}
		command := strings.TrimSpace(row[i:])
		if command == "" {
			continue
		}
		if _, ok := out[pid]; ok {
			return nil, errors.New("duplicate process id")
		}
		out[pid] = command
	}
	return out, nil
}
func (e *Engine) processes() (map[int]string, error) {
	raw, err := e.command(15*time.Second, "/bin/ps", "-axo", "pid=,comm=")
	if err != nil {
		return nil, err
	}
	return parseProcesses(raw)
}
func (e *Engine) AppPIDs(app string) ([]int, error) {
	rows, err := e.processes()
	if err != nil {
		return nil, err
	}
	out := []int{}
	executable := filepath.Join(app, "Contents/MacOS/Relay")
	for pid, command := range rows {
		if command == executable {
			out = append(out, pid)
		}
	}
	return out, nil
}
func (e *Engine) identities() (map[string]string, error) {
	rows, err := e.processes()
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for pid, command := range rows {
		if command == filepath.Join(e.Config.Installed, "Contents/MacOS/Relay") {
			continue
		}
		name := filepath.Base(command)
		if name == "codex" || name == "claude" || strings.Contains(command, "/.local/share/claude/versions/") {
			if id, x := e.Kernel(pid); x == nil {
				out[strconv.Itoa(pid)] = id
			}
		}
	}
	live, err := e.command(15*time.Second, filepath.Join(e.Config.Installed, "Contents/MacOS/relayd"), "live-status")
	if err != nil {
		return nil, err
	}
	fields := strings.Split(strings.TrimSpace(string(live)), "\t")
	if len(fields) < 2 || fields[0] != "RELAYD_LIVE" {
		return nil, errors.New("supervisor identity unavailable")
	}
	pid, err := strconv.Atoi(fields[len(fields)-1])
	if err != nil || pid <= 0 {
		return nil, errors.New("invalid supervisor pid")
	}
	id, err := e.Kernel(pid)
	if err != nil {
		return nil, err
	}
	out[strconv.Itoa(pid)] = id
	paths, err := filepath.Glob(filepath.Join(e.Config.Home, ".local/state/relay/workers/*.json"))
	if err != nil {
		return nil, err
	}
	for _, p := range paths {
		if strings.HasPrefix(filepath.Base(p), ".") {
			continue
		}
		raw, err := readBound(p)
		if err != nil {
			return nil, err
		}
		m, err := object(raw)
		if err != nil {
			return nil, err
		}
		for _, key := range []string{"worker_pid", "shell_pid"} {
			v, ok := m[key]
			if !ok || v == nil {
				continue
			}
			pid, err := strconv.Atoi(fmt.Sprint(v))
			if err != nil || pid <= 0 || pid > 1<<31-1 {
				continue // Original helper ignores absent or unresolvable worker slots.
			}
			if id, x := e.Kernel(pid); x == nil {
				out[strconv.Itoa(pid)] = id
			}
		}
	}
	return out, nil
}
func (e *Engine) retained(ids map[string]string) error {
	if len(ids) == 0 {
		return errors.New("empty kernel identity baseline")
	}
	for p, want := range ids {
		pid, err := strconv.Atoi(p)
		if err != nil || pid <= 0 || want == "" {
			return errors.New("invalid kernel identity baseline")
		}
		got, err := e.Kernel(pid)
		if err != nil {
			return err
		}
		if got != want {
			return errors.New("process incarnation changed: " + p)
		}
	}
	return nil
}
func sameStrings(a, b []string) bool { return reflect.DeepEqual(a, b) }

package codexmcphealth

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

type NativeRuntime struct{}

func (NativeRuntime) Start(pid int) (string, error) {
	raw, e := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if e != nil {
		return "", e
	}
	return ParseStart(string(raw))
}
func ParseStart(raw string) (string, error) {
	i := strings.LastIndex(raw, ")")
	if i < 0 {
		return "", errors.New("invalid process identity")
	}
	fields := strings.Fields(raw[i+1:])
	if len(fields) <= 19 {
		return "", errors.New("truncated process identity")
	}
	return fields[19], nil
}
func ExpectedEndpoint(argv []string, env map[string]string) (string, error) {
	remotes := []string{}
	for i, v := range argv {
		if strings.HasPrefix(v, "--remote=") {
			remotes = append(remotes, strings.TrimPrefix(v, "--remote="))
		}
		if v == "--remote" && i+1 < len(argv) {
			remotes = append(remotes, argv[i+1])
		}
	}
	if len(remotes) > 1 {
		return "", errors.New("ambiguous source endpoint")
	}
	if len(remotes) == 1 {
		u, e := url.Parse(remotes[0])
		if e != nil || u.Scheme != "unix" || u.Host != "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" {
			return "", errors.New("source endpoint is not a private Unix socket")
		}
		return u.EscapedPath(), nil
	}
	home := env["CODEX_HOME"]
	if home == "" {
		if env["HOME"] == "" {
			return "", errors.New("source HOME missing")
		}
		home = filepath.Join(env["HOME"], ".codex")
	}
	return filepath.Join(home, "app-server-control/app-server-control.sock"), nil
}
func (r NativeRuntime) Validate(o Options) error {
	start, e := r.Start(o.PID)
	if e != nil {
		return e
	}
	if start != o.Start {
		return errors.New("source process identity changed")
	}
	p := fmt.Sprintf("/proc/%d", o.PID)
	info, e := os.Stat(p)
	if e != nil {
		return e
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	exe, e := os.Readlink(p + "/exe")
	if e != nil {
		return e
	}
	if !ok || !ownedCodex(st.Uid, exe, uint32(os.Getuid())) {
		return errors.New("source is not an owned Codex process")
	}
	raw, e := os.ReadFile(p + "/environ")
	if e != nil {
		return e
	}
	env := map[string]string{}
	for _, s := range strings.Split(string(raw), "\x00") {
		if k, v, ok := strings.Cut(s, "="); ok {
			env[k] = v
		}
	}
	raw, e = os.ReadFile(p + "/cmdline")
	if e != nil {
		return e
	}
	expected, e := ExpectedEndpoint(strings.Split(string(raw), "\x00"), env)
	if e != nil {
		return e
	}
	cwd, e := os.Readlink(p + "/cwd")
	if e != nil {
		return e
	}
	if o.Socket != expected || cwd != o.Cwd {
		return errors.New("endpoint or working directory does not match the source")
	}
	return nil
}
func (NativeRuntime) PrivateSocket(path string) (Identity, error) {
	parent, e := os.Lstat(filepath.Dir(path))
	if e != nil {
		return Identity{}, e
	}
	info, e := os.Lstat(path)
	if e != nil {
		return Identity{}, e
	}
	if !parent.IsDir() || info.Mode()&os.ModeSocket == 0 {
		return Identity{}, errors.New("control socket is not private and owned by this user")
	}
	for _, i := range []os.FileInfo{parent, info} {
		st, ok := i.Sys().(*syscall.Stat_t)
		if !ok || st.Uid != uint32(os.Getuid()) || i.Mode().Perm()&0077 != 0 {
			return Identity{}, errors.New("control socket is not private and owned by this user")
		}
	}
	st := info.Sys().(*syscall.Stat_t)
	return Identity{uint64(st.Dev), uint64(st.Ino)}, nil
}
func (NativeRuntime) OwnsListener(pid int, path string) (bool, error) {
	raw, e := os.ReadFile("/proc/net/unix")
	if e != nil {
		return false, e
	}
	inodes := ListenerInodes(string(raw), path)
	entries, e := os.ReadDir(fmt.Sprintf("/proc/%d/fd", pid))
	if e != nil {
		return false, e
	}
	for _, entry := range entries {
		target, e := os.Readlink(fmt.Sprintf("/proc/%d/fd/%s", pid, entry.Name()))
		if os.IsNotExist(e) {
			continue
		}
		if e != nil {
			return false, e
		}
		if inodes[target] {
			return true, nil
		}
	}
	return false, nil
}
func ListenerInodes(raw, path string) map[string]bool {
	out := map[string]bool{}
	lines := strings.Split(raw, "\n")
	for _, l := range lines[1:] {
		fields := []string{}
		remaining := strings.TrimSpace(l)
		for i := 0; i < 7; i++ {
			index := strings.IndexAny(remaining, " \t")
			if index < 0 {
				break
			}
			fields = append(fields, remaining[:index])
			remaining = strings.TrimLeft(remaining[index:], " \t")
		}
		if len(fields) == 7 && remaining == path && fields[3] == "00010000" {
			out["socket:["+fields[6]+"]"] = true
		}
	}
	return out
}
func (NativeRuntime) Connect(ctx context.Context, path string) (RPC, error) { return Dial(ctx, path) }

func ownedCodex(owner uint32, exe string, uid uint32) bool {
	return owner == uid && filepath.Base(exe) == "codex"
}

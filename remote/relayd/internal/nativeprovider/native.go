// Package nativeprovider maintains immutable native Codex bundles.
package nativeprovider

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
	"unicode/utf8"
)

const maxManifest = 1 << 20

var names = []string{"codex", "codex-peer-worker", "codex-code-mode-host"}
var stableVersion = regexp.MustCompile(`^codex-cli ([0-9]+\.[0-9]+\.[0-9]+)$`)
var targetPattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$`)
var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Command struct {
	Args    []string
	Dir     string
	Env     []string
	Timeout time.Duration
	Stream  bool
}
type Runner func(Command) ([]byte, error)

func Execute(c Command) ([]byte, error) {
	ctx := context.Background()
	var cancel context.CancelFunc
	if c.Timeout > 0 {
		ctx, cancel = context.WithTimeout(ctx, c.Timeout)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, c.Args[0], c.Args[1:]...)
	// A descendant can retain the captured stdout pipe after the direct child
	// exits or is killed. Bound Go's pipe drain as well as the child lifetime.
	// This closes our pipe; it does not claim to terminate descendant processes.
	cmd.WaitDelay = 100 * time.Millisecond
	cmd.Dir = c.Dir
	cmd.Env = c.Env
	// Version/help responses are bounded independently of child output volume.
	var out boundedBuffer
	cmd.Stdout = &out
	if c.Stream {
		cmd.Stdout = os.Stdout
	}
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	if out.overflow {
		return nil, errors.New("command output exceeds bound")
	}
	return out.Bytes(), err
}

type boundedBuffer struct {
	bytes.Buffer
	overflow bool
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	if b.Len()+n > maxManifest {
		b.overflow = true
		room := maxManifest - b.Len()
		if room > 0 {
			b.Buffer.Write(p[:room])
		}
		return n, nil
	}
	return b.Buffer.Write(p)
}
func hashFile(p string) (string, error) {
	f, e := os.Open(p)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	_, e = io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), e
}
func readBound(p string) ([]byte, error) {
	f, e := os.Open(p)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	b, e := io.ReadAll(io.LimitReader(f, maxManifest+1))
	if len(b) > maxManifest {
		return nil, errors.New("manifest exceeds bound")
	}
	return b, e
}
func parseSums(b []byte) (map[string]string, error) {
	if len(b) > maxManifest || !utf8.Valid(b) {
		return nil, errors.New("invalid checksum manifest encoding/size")
	}
	out := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 || !digestPattern.MatchString(f[0]) || !safeName(f[1]) {
			return nil, errors.New("invalid artifact name or checksum")
		}
		if _, ok := out[f[1]]; ok {
			return nil, errors.New("duplicate artifact")
		}
		out[f[1]] = f[0]
	}
	return out, nil
}
func safeName(s string) bool {
	return s != "" && s != "." && s != ".." && !strings.ContainsAny(s, "/\\\x00") && filepath.Base(s) == s
}

// parseObject rejects duplicate keys recursively instead of silently selecting an owner.
func parseObject(b []byte) (map[string]any, error) {
	if len(b) > maxManifest || !utf8.Valid(b) {
		return nil, errors.New("invalid JSON encoding/size")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var value func(int) (any, error)
	value = func(depth int) (any, error) {
		if depth > 32 {
			return nil, errors.New("JSON depth exceeded")
		}
		t, e := d.Token()
		if e != nil {
			return nil, e
		}
		delim, ok := t.(json.Delim)
		if !ok {
			return t, nil
		}
		switch delim {
		case '{':
			m := map[string]any{}
			for d.More() {
				k, e := d.Token()
				if e != nil {
					return nil, e
				}
				s, ok := k.(string)
				if !ok {
					return nil, errors.New("invalid key")
				}
				if _, ok = m[s]; ok {
					return nil, errors.New("duplicate JSON key")
				}
				v, e := value(depth + 1)
				if e != nil {
					return nil, e
				}
				m[s] = v
			}
			_, e = d.Token()
			return m, e
		case '[':
			a := []any{}
			for d.More() {
				v, e := value(depth + 1)
				if e != nil {
					return nil, e
				}
				a = append(a, v)
			}
			_, e = d.Token()
			return a, e
		}
		return nil, errors.New("unexpected delimiter")
	}
	v, e := value(0)
	if e != nil {
		return nil, e
	}
	if _, e = d.Token(); e != io.EOF {
		return nil, errors.New("trailing JSON")
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("expected JSON object")
	}
	return m, nil
}
func filesOf(m map[string]any) (map[string]string, error) {
	f, ok := m["files"].(map[string]any)
	if !ok {
		return nil, errors.New("missing files object")
	}
	out := map[string]string{}
	for k, v := range f {
		s, ok := v.(string)
		if !ok || !digestPattern.MatchString(s) || !safeName(k) {
			return nil, errors.New("invalid file hash")
		}
		out[k] = s
	}
	return out, nil
}
func regular(p string, executable bool) error {
	s, e := os.Stat(p)
	if e != nil {
		return e
	}
	if !s.Mode().IsRegular() || executable && s.Mode().Perm()&0111 == 0 {
		return fmt.Errorf("missing executable or regular file: %s", p)
	}
	return nil
}
func syncDir(p string) error {
	f, e := os.Open(p)
	if e != nil {
		return e
	}
	defer f.Close()
	return f.Sync()
}
func copyPrivate(src, dst string) error {
	in, e := os.Open(src)
	if e != nil {
		return e
	}
	defer in.Close()
	out, e := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0700)
	if e != nil {
		return e
	}
	if e = out.Chmod(0700); e != nil {
		out.Close()
		return e
	}
	_, e = io.Copy(out, in)
	if e == nil {
		e = out.Sync()
	}
	ce := out.Close()
	if e == nil {
		e = ce
	}
	return e
}
func writePrivate(p string, b []byte) error {
	f, e := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	if e = f.Chmod(0600); e != nil {
		f.Close()
		return e
	}
	_, e = f.Write(b)
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	return e
}
func jsonBytes(v any) []byte { b, _ := json.MarshalIndent(v, "", "  "); return append(b, '\n') }
func absolute(p string) (string, error) {
	p, e := filepath.Abs(p)
	if e != nil {
		return "", e
	}
	return filepath.EvalSymlinks(p)
}

func Build(root, target string, bundle bool, run Runner) error {
	if !targetPattern.MatchString(target) {
		return errors.New("invalid target")
	}
	root, e := absolute(root)
	if e != nil {
		return e
	}
	cache := filepath.Join(root, ".relay-codehost-v8", target)
	if e = os.MkdirAll(cache, 0700); e != nil {
		return e
	}
	profile := "ptrcomp_sandbox_release_" + target
	mn := "rusty_v8_" + profile + ".sha256"
	b, e := readBound(filepath.Join(root, "third_party/v8/rusty_v8_150_4_0_release_manifests.sha256"))
	if e != nil {
		return e
	}
	trusted, e := parseSums(b)
	if e != nil {
		return e
	}
	digest, ok := trusted[mn]
	if !ok {
		return errors.New("missing trusted manifest")
	}
	fetch := func(name, digest string) (string, error) {
		dst := filepath.Join(cache, name)
		if got, e := hashFile(dst); e == nil && got == digest {
			return dst, nil
		}
		f, e := os.CreateTemp(cache, ".asset-*")
		if e != nil {
			return "", e
		}
		tmp := f.Name()
		f.Close()
		defer os.Remove(tmp)
		_, e = run(Command{Args: []string{"curl", "-fsSL", "https://github.com/openai/codex/releases/download/rusty-v8-v150.4.0/" + name, "-o", tmp}, Env: os.Environ()})
		if e != nil {
			return "", e
		}
		got, e := hashFile(tmp)
		if e != nil {
			return "", e
		}
		if got != digest {
			return "", errors.New("checksum mismatch: " + name)
		}
		if e = os.Rename(tmp, dst); e != nil {
			return "", e
		}
		return dst, nil
	}
	manifest, e := fetch(mn, digest)
	if e != nil {
		return e
	}
	b, e = readBound(manifest)
	if e != nil {
		return e
	}
	assets, e := parseSums(b)
	if e != nil {
		return e
	}
	an := "librusty_v8_" + profile + ".a.gz"
	bn := "src_binding_" + profile + ".rs"
	if len(assets) != 2 || assets[an] == "" || assets[bn] == "" {
		return errors.New("unexpected V8 artifact set")
	}
	archive, e := fetch(an, assets[an])
	if e != nil {
		return e
	}
	binding, e := fetch(bn, assets[bn])
	if e != nil {
		return e
	}
	args := []string{"cargo", "build", "--release"}
	if bundle {
		for _, n := range names {
			args = append(args, "--bin", n)
		}
	} else {
		args = append(args, "-p", "codex-code-mode-host")
	}
	env := []string{}
	for _, v := range os.Environ() {
		if !strings.HasPrefix(v, "RUSTY_V8_ARCHIVE=") && !strings.HasPrefix(v, "RUSTY_V8_SRC_BINDING_PATH=") {
			env = append(env, v)
		}
	}
	env = append(env, "RUSTY_V8_ARCHIVE="+archive, "RUSTY_V8_SRC_BINDING_PATH="+binding)
	_, e = run(Command{Args: args, Dir: filepath.Join(root, "codex-rs"), Env: env, Stream: true})
	return e
}

type InstallOptions struct {
	Codex, Worker, Host, Expected, Home string
	StageOnly                           bool
}

func Install(o InstallOptions, run Runner) (map[string]any, error) {
	sources := map[string]string{"codex": o.Codex, "codex-peer-worker": o.Worker}
	if o.Host == "" {
		resolved, e := absolute(o.Codex)
		if e != nil {
			return nil, e
		}
		o.Host = filepath.Join(filepath.Dir(resolved), "codex-code-mode-host")
	}
	sources["codex-code-mode-host"] = o.Host
	for _, n := range names {
		p, e := absolute(sources[n])
		if e != nil {
			return nil, e
		}
		sources[n] = p
		if e = regular(p, true); e != nil {
			return nil, e
		}
	}
	version, e := run(Command{Args: []string{sources["codex"], "--version"}, Env: os.Environ(), Timeout: 15 * time.Second})
	if e != nil {
		return nil, e
	}
	v := strings.TrimSpace(string(version))
	match := stableVersion.FindStringSubmatch(v)
	if match == nil {
		return nil, errors.New("unexpected Codex version")
	}
	parent := filepath.Join(o.Home, ".local/share/relay")
	if e = os.MkdirAll(parent, 0700); e != nil {
		return nil, e
	}
	dst := filepath.Join(parent, "native-codex")
	if e = requireManaged(dst); e != nil {
		return nil, e
	}

	stage, e := os.MkdirTemp(parent, "native-codex-"+match[1]+"-")
	if e != nil {
		return nil, e
	}
	activated := false
	defer func() {
		if !activated {
			os.RemoveAll(stage)
		}
	}()
	hashes := map[string]string{}
	for _, n := range names {
		p := filepath.Join(stage, n)
		if e = copyPrivate(sources[n], p); e != nil {
			return nil, e
		}
		h, e := hashFile(p)
		if e != nil {
			return nil, e
		}
		hashes[n] = h
	}
	if o.Expected != "" {
		b, e := readBound(o.Expected)
		if e != nil {
			return nil, e
		}
		m, e := parseObject(b)
		if e != nil {
			return nil, e
		}
		want, e := filesOf(m)
		if e != nil {
			return nil, e
		}
		if len(want) != len(hashes) {
			return nil, errors.New("staged hashes differ")
		}
		for n, h := range hashes {
			if want[n] != h {
				return nil, errors.New("staged hashes differ")
			}
		}
	}
	platform := runtime.GOOS
	if platform == "darwin" {
		platform = "Darwin"
	} else if platform == "linux" {
		platform = "Linux"
	}
	arch := runtime.GOARCH
	if arch == "amd64" {
		arch = "x86_64"
	} else if arch == "arm64" && runtime.GOOS == "linux" {
		arch = "aarch64"
	}
	record := map[string]any{"version": match[1] + "-relay-native-1", "native_inbox_protocol": 1, "files": hashes, "platform": platform, "arch": arch}
	if e = writePrivate(filepath.Join(stage, "installed.json"), jsonBytes(record)); e != nil {
		return nil, e
	}
	if e = syncDir(stage); e != nil {
		return nil, e
	}
	installed := stage
	if !o.StageOnly {
		activated, e = activateStage(stage, dst)
		if e != nil {
			return nil, e
		}
		installed = dst
	}

	activated = true // Stage-only owns its completed immutable directory as well.
	return map[string]any{"installed": installed, "activated": !o.StageOnly, "version": v, "running_agents_changed": false}, nil
}

func requireManaged(dst string) error {
	s, e := os.Lstat(dst)
	if os.IsNotExist(e) {
		return nil
	}
	if e != nil {
		return e
	}
	if s.Mode()&os.ModeSymlink == 0 {
		return errors.New("refusing unmanaged installation")
	}
	return nil
}

// activateStage only switches the reference; completed bundle bytes stay immutable.
// The bool indicates that the switch committed, even if directory sync reports failure.
func activateStage(stage, dst string) (bool, error) {
	if e := requireManaged(dst); e != nil {
		return false, e
	}
	link := stage + ".link"
	if e := os.Symlink(filepath.Base(stage), link); e != nil {
		return false, e
	}
	defer os.Remove(link)
	if e := os.Rename(link, dst); e != nil {
		return false, e
	}
	return true, syncDir(filepath.Dir(dst))
}

func Repair(root, source string, run Runner) (map[string]any, error) {
	root, e := absolute(root)
	if e != nil {
		return nil, e
	}
	source, e = absolute(source)
	if e != nil {
		return nil, e
	}
	mp := filepath.Join(root, "installed.json")
	original, e := readBound(mp)
	if e != nil {
		return nil, e
	}
	record, e := parseObject(original)
	if e != nil {
		return nil, e
	}
	if record["version"] != "0.160.0-relay-native-1" {
		return nil, errors.New("unsupported installation")
	}
	files, e := filesOf(record)
	if e != nil {
		return nil, e
	}
	for _, n := range names[:2] {
		h, e := hashFile(filepath.Join(root, n))
		if e != nil {
			return nil, e
		}
		if h != files[n] {
			return nil, errors.New("existing installation checksum mismatch: " + n)
		}
	}
	if e = regular(source, true); e != nil {
		return nil, e
	}
	if _, e = run(Command{Args: []string{source, "--help"}, Env: os.Environ(), Timeout: 15 * time.Second}); e != nil {
		return nil, e
	}
	expected, e := hashFile(source)
	if e != nil {
		return nil, e
	}
	name := "codex-code-mode-host"
	dst := filepath.Join(root, name)
	result := map[string]any{"installation": root, "added": name, "sha256": expected, "existing_executables_unchanged": true}
	s, e := os.Lstat(dst)
	if e == nil {
		if !s.Mode().IsRegular() {
			return nil, errors.New("refusing different existing tool host")
		}
		h, e := hashFile(dst)
		if e != nil || h != expected {
			return nil, errors.New("refusing different existing tool host")
		}
		if files[name] == expected {
			result["already_repaired"] = true
			return result, nil
		}
	} else if !os.IsNotExist(e) {
		return nil, e
	} else {
		f, e := os.CreateTemp(root, ".codehost-*")
		if e != nil {
			return nil, e
		}
		tmp := f.Name()
		f.Close()
		os.Remove(tmp)
		defer os.Remove(tmp)
		if e = copyPrivate(source, tmp); e != nil {
			return nil, e
		}
		h, e := hashFile(tmp)
		if e != nil {
			return nil, e
		}
		if h != expected {
			return nil, errors.New("copied tool host checksum mismatch")
		}
		if e = os.Link(tmp, dst); e != nil {
			return nil, e
		}
	}
	now, e := readBound(mp)
	if e != nil {
		return nil, e
	}
	if !bytes.Equal(now, original) {
		return nil, errors.New("installation manifest changed during repair")
	}
	if e = writePrivate(filepath.Join(root, "installed.before-codehost.json"), original); e != nil {
		return nil, e
	}
	files[name] = expected
	record["files"] = files
	f, e := os.CreateTemp(root, ".manifest-*")
	if e != nil {
		return nil, e
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	_, e = f.Write(jsonBytes(record))
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e != nil {
		return nil, e
	}
	if e = os.Rename(tmp, mp); e != nil {
		return nil, e
	}
	if e = syncDir(root); e != nil {
		return nil, e
	}
	return result, nil
}

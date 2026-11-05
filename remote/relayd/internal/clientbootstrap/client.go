// Package clientbootstrap execs the native MCP adapter using an already-issued
// private caller credential. It never issues, rotates or persists credentials.
package clientbootstrap

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"github.com/relay-terminal/relayd/internal/helpercli"
)

const MaxCredential = 65536

type Candidate struct{ MCP, Daemon string }
type Plan struct {
	Executable        string
	Args, Environment []string
}

func ParseCredential(data []byte) (string, error) {
	if len(data) > MaxCredential {
		return "", errors.New("Relay client credential exceeds limit")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	tok, err := dec.Token()
	if err != nil || tok != json.Delim('{') {
		return "", errors.New("Relay client credential must be an object")
	}
	seen := map[string]bool{}
	token := ""
	for dec.More() {
		k, e := dec.Token()
		if e != nil {
			return "", errors.New("Invalid Relay client credential")
		}
		key, ok := k.(string)
		if !ok || seen[key] {
			return "", errors.New("Ambiguous Relay client credential")
		}
		seen[key] = true
		var value json.RawMessage
		if dec.Decode(&value) != nil {
			return "", errors.New("Invalid Relay client credential")
		}
		if key == "caller_token" {
			if json.Unmarshal(value, &token) != nil {
				return "", errors.New("Invalid Relay client credential")
			}
		}
	}
	if _, err = dec.Token(); err != nil {
		return "", errors.New("Truncated Relay client credential")
	}
	var extra any
	if dec.Decode(&extra) != io.EOF {
		return "", errors.New("Trailing Relay client credential data")
	}
	if token == "" || len(token) > 200 || strings.ContainsAny(token, "\x00\r\n") {
		return "", errors.New("Invalid Relay client credential")
	}
	return token, nil
}

func ReadCredential(path string) (string, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return "", errors.New("Relay client credential unavailable")
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return "", errors.New("Relay client credential unavailable")
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != os.Getuid() || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > MaxCredential {
		return "", errors.New("Relay client credential permissions are unsafe")
	}
	data, err := io.ReadAll(io.LimitReader(f, MaxCredential+1))
	if err != nil {
		return "", errors.New("Relay client credential unavailable")
	}
	return ParseCredential(data)
}

// Prepare performs all authority checks before producing the exact exec plan.
// Executable selection and environment replacement match the previous adapter;
// callers retain their process parent because Run uses exec, not a child.
func Prepare(credential string, candidates []Candidate, args, environment []string) (Plan, error) {
	token, err := ReadCredential(credential)
	if err != nil {
		return Plan{}, err
	}
	for _, c := range candidates {
		if !executable(c.MCP) || !executable(c.Daemon) {
			continue
		}
		env := make([]string, 0, len(environment)+3)
		for _, v := range environment {
			if !strings.HasPrefix(v, "RELAY_MCP_CALLER_TOKEN=") && !strings.HasPrefix(v, "RELAY_MCP_BACKEND=") && !strings.HasPrefix(v, "RELAY_MCP_DAEMON=") {
				env = append(env, v)
			}
		}
		env = append(env, "RELAY_MCP_CALLER_TOKEN="+token, "RELAY_MCP_BACKEND=daemon", "RELAY_MCP_DAEMON="+c.Daemon)
		argv := append([]string{"relay-mcp", "--use-relay-token"}, args...)
		return Plan{c.MCP, argv, env}, nil
	}
	return Plan{}, errors.New("Native Relay messaging helpers are unavailable")
}
func executable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && syscall.Access(path, 1) == nil
}
func Run(args []string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	plan, err := prepareForHost(runtime.GOOS, exe, home, args, os.Environ())
	if err != nil {
		return err
	}
	return Execute(plan)
}

// prepareForHost keeps the original Mac adapter and remote caller contracts
// separate: the remote wrapper ignores argv and forwards desktop token/port.
func prepareForHost(host, exe, home string, args, environment []string) (Plan, error) {
	credential := filepath.Join(filepath.Dir(exe), "credential.json")
	if host == "darwin" {
		app := "/Applications/Relay.app/Contents/MacOS"
		bin := filepath.Join(home, ".local/share/relay/bin")
		return Prepare(credential, []Candidate{{filepath.Join(app, "relay-mcp"), filepath.Join(app, "relayd")}, {filepath.Join(bin, "relay-mcp-verified"), filepath.Join(bin, "relayd-verified")}}, args, environment)
	}
	token, err := ReadCredential(credential)
	if err != nil {
		return Plan{}, err
	}
	data, err := readDesktopConfiguration(filepath.Join(home, ".relay-mcp-desktop.json"))
	if err != nil {
		return Plan{}, err
	}
	return prepareRemote(home, token, data, environment)
}

// Match helpercli's existing document cap while bounding the file read itself.
const maxDesktopConfiguration = 1 << 20

func readDesktopConfiguration(path string) ([]byte, error) {
	// Desktop configuration may be a symlink, as in the original wrapper.
	// Nonblocking open lets us refuse nonregular files without waiting on a FIFO.
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, errors.New("Relay desktop configuration unavailable")
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxDesktopConfiguration {
		return nil, errors.New("Relay desktop configuration is not a bounded regular file")
	}
	data, err := io.ReadAll(io.LimitReader(f, maxDesktopConfiguration+1))
	if err != nil || len(data) > maxDesktopConfiguration {
		return nil, errors.New("Relay desktop configuration exceeds limit or is unreadable")
	}
	return data, nil
}

// prepareRemote is pure composition after ReadCredential's authority checks.
// Reuse the maintained desktop JSON/port conversion, but select the original
// communication aliases rather than a possibly user-owned ~/.local/bin entry.
func prepareRemote(home, caller string, desktop []byte, environment []string) (Plan, error) {
	_, _, desktopEnv, err := helpercli.MCPBootstrap(home, desktop, environment)
	if err != nil {
		return Plan{}, errors.New("Invalid Relay desktop configuration")
	}
	bin := filepath.Join(home, ".local/share/relay/bin")
	mcp := filepath.Join(bin, "relay-mcp-communication")
	env := make([]string, 0, len(desktopEnv)+3)
	for _, value := range desktopEnv {
		if !strings.HasPrefix(value, "RELAY_MCP_CALLER_TOKEN=") && !strings.HasPrefix(value, "RELAY_MCP_BACKEND=") && !strings.HasPrefix(value, "RELAY_MCP_DAEMON=") {
			env = append(env, value)
		}
	}
	env = append(env, "RELAY_MCP_CALLER_TOKEN="+caller, "RELAY_MCP_BACKEND=daemon", "RELAY_MCP_DAEMON="+filepath.Join(bin, "relayd-communication"))
	return Plan{mcp, []string{mcp}, env}, nil
}

// Execute replaces this process, retaining the original caller parent.
func Execute(plan Plan) error { return syscall.Exec(plan.Executable, plan.Args, plan.Environment) }

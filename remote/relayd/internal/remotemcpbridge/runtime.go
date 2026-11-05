package remotemcpbridge

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var hostPattern = regexp.MustCompile(`^[A-Za-z0-9_@.-]{1,128}$`)

func LoadCapability(home, host string, port int) (string, error) {
	if !hostPattern.MatchString(host) || host == "." || host == ".." {
		return "", errors.New("invalid bridge host")
	}
	root := filepath.Join(home, ".local/share/relay/remote-mcp")
	if e := os.MkdirAll(root, 0700); e != nil {
		return "", e
	}
	info, e := os.Lstat(root)
	if e != nil {
		return "", e
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || st.Uid != uint32(os.Getuid()) {
		return "", errors.New("bridge capability directory is not owned")
	}
	if e = os.Chmod(root, 0700); e != nil {
		return "", e
	}
	path := filepath.Join(root, host+".json")
	read := func() (string, error) {
		fd, e := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if e != nil {
			return "", e
		}
		f := os.NewFile(uintptr(fd), path)
		defer f.Close()
		info, e := f.Stat()
		if e != nil {
			return "", e
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || st.Uid != uint32(os.Getuid()) {
			return "", errors.New("bridge capability file is not private")
		}
		data, e := io.ReadAll(io.LimitReader(f, 4097))
		if e != nil {
			return "", e
		}
		if len(data) > 4096 {
			return "", errors.New("bridge capability exceeds limit")
		}
		var row struct {
			Token string `json:"token"`
		}
		if e = json.Unmarshal(data, &row); e != nil {
			return "", e
		}
		if row.Token == "" || len(row.Token) > 200 || !callerPattern.MatchString(row.Token) {
			return "", errors.New("invalid bridge capability")
		}
		return row.Token, nil
	}
	if _, e = os.Lstat(path); e == nil {
		return read()
	} else if !os.IsNotExist(e) {
		return "", e
	}
	secret := make([]byte, 32)
	if _, e = rand.Read(secret); e != nil {
		return "", e
	}
	token := base64.RawURLEncoding.EncodeToString(secret)
	data := encode(map[string]any{"token": token, "port": port})
	f, e := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if os.IsExist(e) {
		return read()
	}
	if e != nil {
		return "", e
	}
	_, e = f.Write(data)
	if e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e != nil {
		return "", e
	}
	if closeErr != nil {
		return "", closeErr
	}
	return token, nil
}

type HTTPDesktop struct {
	URL    string
	Client *http.Client
	Token  func(context.Context) (string, error)
}

func DefaultToken(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, e := exec.CommandContext(ctx, "/usr/bin/defaults", "read", "dev.relay.terminal", "relay.side-panel-token.v1").Output()
	return strings.TrimSpace(string(out)), e
}
func (d HTTPDesktop) Call(ctx context.Context, method, path string, body []byte, caller string) (int, []byte, error) {
	reader := d.Token
	if reader == nil {
		reader = DefaultToken
	}
	token, e := reader(ctx)
	if e != nil {
		return 0, nil, e
	}
	base := d.URL
	if base == "" {
		base = "http://127.0.0.1:47471"
	}
	request, e := http.NewRequestWithContext(ctx, method, base+path, bytes.NewReader(body))
	if e != nil {
		return 0, nil, e
	}
	request.Header.Set("x-relay-token", token)
	request.Header.Set("Content-Type", "application/json")
	if caller != "" {
		request.Header.Set("X-Relay-Caller-Token", caller)
	}
	client := d.Client
	if client == nil {
		client = &http.Client{Timeout: 65 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	response, e := client.Do(request)
	if e != nil {
		return 0, nil, e
	}
	defer response.Body.Close()
	result, e := io.ReadAll(io.LimitReader(response.Body, ResponseLimit+1))
	return response.StatusCode, result, e
}

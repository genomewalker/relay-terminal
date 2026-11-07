package desktoproute

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"testing"
)

// The owner's registry is its own account's, never the default's by fallback.
func TestRemoteRegistryFollowsOwnerAccount(t *testing.T) {
	home := privateTemp(t)
	acct := privateTemp(t)
	for _, dir := range []string{filepath.Join(home, ".claude", "sessions"), filepath.Join(acct, "sessions")} {
		if err := privateDirectory(dir, true); err != nil {
			t.Fatal(err)
		}
	}
	alive := func(int) (processInfo, error) { return processInfo{Start: "456"}, nil }
	gone := func(int) (processInfo, error) { return processInfo{}, errIdentity }
	cases := []struct {
		name    string
		env     map[string]string
		envErr  error
		inspect func(int) (processInfo, error)
		want    string // "" means refused
	}{
		{"own account", map[string]string{"CLAUDE_CONFIG_DIR": acct}, nil, alive, filepath.Join(acct, "sessions")},
		{"unset selects default", map[string]string{}, nil, alive, filepath.Join(home, ".claude", "sessions")},
		{"set but empty refused", map[string]string{"CLAUDE_CONFIG_DIR": ""}, nil, alive, ""},
		{"relative refused", map[string]string{"CLAUDE_CONFIG_DIR": "rel/acct"}, nil, alive, ""},
		{"unclean refused", map[string]string{"CLAUDE_CONFIG_DIR": acct + "/."}, nil, alive, ""},
		{"unreadable env refused", nil, errors.New("environment unavailable"), alive, ""},
		{"gone pid refused", map[string]string{"CLAUDE_CONFIG_DIR": acct}, nil, gone, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := &remoteRuntime{home: home, inspect: c.inspect, environment: func(int, ...string) (map[string]string, error) {
				return c.env, c.envErr
			}}
			got, err := r.registry(123, "456")
			if c.want == "" {
				if err == nil {
					t.Fatalf("resolved %q for a refused owner", got)
				}
				return
			}
			if err != nil || got != c.want {
				t.Fatalf("registry = %q, %v; want %q", got, err, c.want)
			}
		})
	}
}

// A gone owner's account is not recorded, so no replacement is searched for
// in the default account. The default directory holds a valid replacement.
func TestIdentityEventNeverSearchesDefaultAccount(t *testing.T) {
	home := privateTemp(t)
	sessions := filepath.Join(home, ".claude", "sessions")
	if err := privateDirectory(sessions, true); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(home, "replacement.sock")
	listener := unixFixture(t, socket)
	defer listener.Close()
	if err := atomicJSON(filepath.Join(sessions, "4242.json"), peerRecord{PID: 4242, Name: "reply", Session: "session", Start: "789", Socket: socket, CWD: home}); err != nil {
		t.Fatal(err)
	}
	r := &remoteRuntime{home: home, inspect: func(pid int) (processInfo, error) {
		if pid == 4242 {
			return processInfo{Start: "789"}, nil
		}
		return processInfo{}, errIdentity
	}, environment: func(int, ...string) (map[string]string, error) {
		t.Fatal("environment read for a gone owner")
		return nil, nil
	}}
	var out bytes.Buffer
	if e := r.run(context.Background(), []string{"listen", "123", "session", "456", "reply"}, bytes.NewReader(nil), &out); e != nil {
		t.Fatal(e)
	}
	event, e := parseEvent(out.Bytes())
	if e != nil || event.Type != "identity_missing" {
		t.Fatalf("default-account replacement searched: %s", out.String())
	}
}

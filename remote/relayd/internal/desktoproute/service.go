package desktoproute

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var serviceLabel = regexp.MustCompile(`^dev\.vaklab\.relay-desktop-[A-Za-z0-9_-]{1,64}$`)

func parsePlist(raw []byte) (map[string]any, error) {
	if len(raw) > 16384 {
		return nil, errors.New("service exceeds limit")
	}
	d := xml.NewDecoder(bytes.NewReader(raw))
	var parse func(xml.StartElement, int) (any, error)
	parse = func(start xml.StartElement, depth int) (any, error) {
		if depth > 8 {
			return nil, errors.New("plist nesting exceeds limit")
		}
		switch start.Name.Local {
		case "string", "key":
			var text string
			if e := d.DecodeElement(&text, &start); e != nil {
				return nil, e
			}
			return text, nil
		case "true", "false":
			var text string
			if e := d.DecodeElement(&text, &start); e != nil || text != "" {
				return nil, errors.New("invalid boolean")
			}
			return start.Name.Local == "true", nil
		case "array":
			items := []any{}
			for {
				t, e := d.Token()
				if e != nil {
					return nil, e
				}
				switch t := t.(type) {
				case xml.EndElement:
					if t.Name != start.Name {
						return nil, errors.New("plist close mismatch")
					}
					return items, nil
				case xml.StartElement:
					v, e := parse(t, depth+1)
					if e != nil {
						return nil, e
					}
					items = append(items, v)
					if len(items) > 64 {
						return nil, errors.New("plist array exceeds limit")
					}
				case xml.CharData:
					if strings.TrimSpace(string(t)) != "" {
						return nil, errors.New("invalid plist text")
					}
				}
			}
		case "dict":
			items := map[string]any{}
			key := ""
			expectKey := true
			for {
				t, e := d.Token()
				if e != nil {
					return nil, e
				}
				switch t := t.(type) {
				case xml.EndElement:
					if t.Name != start.Name || !expectKey {
						return nil, errors.New("truncated plist dictionary")
					}
					return items, nil
				case xml.StartElement:
					if expectKey && t.Name.Local != "key" {
						return nil, errors.New("plist key required")
					}
					v, e := parse(t, depth+1)
					if e != nil {
						return nil, e
					}
					if expectKey {
						key = v.(string)
						if _, ok := items[key]; ok {
							return nil, errors.New("duplicate plist key")
						}
					} else {
						items[key] = v
					}
					expectKey = !expectKey
				case xml.CharData:
					if strings.TrimSpace(string(t)) != "" {
						return nil, errors.New("invalid plist text")
					}
				}
			}
		}
		return nil, errors.New("unsupported plist type")
	}
	var result map[string]any
	opened, closed := false, false
	for {
		t, e := d.Token()
		if e == io.EOF {
			break
		}
		if e != nil {
			return nil, e
		}
		switch t := t.(type) {
		case xml.StartElement:
			if !opened {
				if t.Name.Local != "plist" {
					return nil, errors.New("plist root required")
				}
				opened = true
			} else {
				if closed || result != nil || t.Name.Local != "dict" {
					return nil, errors.New("unexpected plist root")
				}
				v, e := parse(t, 0)
				if e != nil {
					return nil, e
				}
				result = v.(map[string]any)
			}
		case xml.EndElement:
			if t.Name.Local != "plist" || result == nil {
				return nil, errors.New("invalid plist end")
			}
			closed = true
		case xml.CharData:
			if strings.TrimSpace(string(t)) != "" {
				return nil, errors.New("invalid plist text")
			}
		}
	}
	if !closed {
		return nil, errors.New("truncated plist")
	}
	return result, nil
}
func xmlText(s string) string { var b bytes.Buffer; xml.EscapeText(&b, []byte(s)); return b.String() }
func serviceBytes(label string, args []string) []byte {
	var b strings.Builder
	b.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>Label</key><string>" + xmlText(label) + "</string><key>ProgramArguments</key><array>")
	for _, arg := range args {
		b.WriteString("<string>" + xmlText(arg) + "</string>")
	}
	b.WriteString("</array><key>RunAtLoad</key><true/><key>KeepAlive</key><false/><key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict></dict></plist>\n")
	return []byte(b.String())
}
func (r *runtime) serviceArgs(config string) []string {
	return []string{r.exe, "desktop-route", "listen", "--config", config}
}
func (r *runtime) serviceMatches(raw []byte, label, config string, allowLegacy bool) bool {
	p, e := parsePlist(raw)
	if e != nil || p["Label"] != label || !serviceLabel.MatchString(label) {
		return false
	}
	array, ok := p["ProgramArguments"].([]any)
	if !ok {
		return false
	}
	args := []string{}
	for _, v := range array {
		s, ok := v.(string)
		if !ok {
			return false
		}
		args = append(args, s)
	}
	if reflect.DeepEqual(args, r.serviceArgs(config)) {
		return true
	}
	return allowLegacy && reflect.DeepEqual(args, []string{filepath.Join(r.root(), "venv/bin/python"), filepath.Join(r.root(), "relay-desktop-route.py"), "listen", "--config", config})
}
func (r *runtime) serviceFor(config string) (string, string, error) {
	if e := relativeConfig(r.root(), config); e != nil {
		return "", "", e
	}
	files, e := filepath.Glob(filepath.Join(r.home, "Library/LaunchAgents/dev.vaklab.relay-desktop-*.plist"))
	if e != nil {
		return "", "", e
	}
	if len(files) > 64 {
		return "", "", errors.New("too many route services")
	}
	label, path := "", ""
	for _, file := range files {
		raw, e := privateRead(file, 16384, 0077)
		if e != nil {
			continue
		}
		candidate := strings.TrimSuffix(filepath.Base(file), ".plist")
		if r.serviceMatches(raw, candidate, config, true) {
			if path != "" {
				return "", "", errors.New("ambiguous route service")
			}
			label, path = candidate, file
		}
	}
	if path == "" {
		return "", "", errors.New("saved route service missing")
	}
	return label, path, nil
}
func launchctl(ctx context.Context, args ...string) error {
	callCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(callCtx, "/bin/launchctl", args...)
	if e := cmd.Run(); e != nil {
		return errors.New("launch service operation failed")
	}
	return nil
}
func (r *runtime) stopService(ctx context.Context, label string) error {
	target := fmt.Sprintf("gui/%d/%s", os.Getuid(), label)
	if e := r.service(ctx, "disable", target); e != nil {
		return e
	}
	if r.service(ctx, "print", target) == nil {
		return r.service(ctx, "bootout", target)
	}
	return nil
}
func (r *runtime) startService(ctx context.Context, label, path string, connect bool) error {
	target := fmt.Sprintf("gui/%d/%s", os.Getuid(), label)
	if connect {
		if e := r.service(ctx, "enable", target); e != nil {
			return e
		}
	}
	if r.service(ctx, "print", target) != nil {
		if e := r.service(ctx, "bootstrap", fmt.Sprintf("gui/%d", os.Getuid()), path); e != nil {
			return e
		}
	}
	if connect {
		return r.service(ctx, "kickstart", target)
	}
	return nil
}
func (r *runtime) saved(c Config) (string, error) {
	files, e := jsonFiles(r.root(), 65)
	if e != nil {
		return "", e
	}
	found := ""
	count := 0
	for _, path := range files {
		if filepath.Base(path) == "connections.json" {
			continue
		}
		count++
		item, e := readConfig(path)
		if e != nil {
			return "", e
		}
		if item.Thread == c.Thread && item.Host == c.Host && item.RemoteSession == c.RemoteSession {
			if found != "" {
				return "", errors.New("ambiguous saved route")
			}
			found = path
		}
	}
	if count > 64 {
		return "", errors.New("too many saved routes")
	}
	return found, nil
}

type savedRoute struct {
	Config  string `json:"config"`
	Service string `json:"service"`
	Label   string `json:"label"`
	Reply   string `json:"replyName"`
}

func (r *runtime) remember(ctx context.Context, c Config, connect, rebind bool) (savedRoute, error) {
	var result savedRoute
	if e := c.Validate(); e != nil {
		return result, e
	}
	if e := privateDirectory(r.root(), true); e != nil {
		return result, e
	}
	lock, e := fileLock(filepath.Join(r.root(), ".routes.lock"), false)
	if e != nil {
		return result, e
	}
	defer lock.Close()
	path, e := r.saved(c)
	if e != nil {
		return result, e
	}
	key := routeKey(c)
	old := Config{}
	hasOld := path != ""
	if !hasOld {
		if rebind {
			return result, errors.New("no route for explicit rebind")
		}
		path = filepath.Join(r.root(), key+".json")
		c.LocalName = "relay-" + key
		// A local owner's account is recorded now, from the exact live process. An
		// unresolved one is backfilled from the owner when its listener verifies it.
		c = recordLocalOwnerAccount(localOwnerRuntime(r.home), c)
	} else {
		old, e = readConfig(path)
		if e != nil {
			return result, e
		}
		c.LocalName = old.LocalName
		if old != c {
			copy := c
			copy.RemoteName = old.RemoteName
			copy.RemotePID = old.RemotePID
			copy.RemoteStart = old.RemoteStart
			if !rebind || copy != old {
				return result, errIdentity
			}
		} else if rebind {
			return result, errors.New("selected incarnation did not change")
		}
	}
	label := "dev.vaklab.relay-desktop-" + key
	service := filepath.Join(r.home, "Library/LaunchAgents", label+".plist")
	if hasOld {
		label, service, e = r.serviceFor(path)
		if e != nil {
			return result, e
		}
	}
	if e = os.MkdirAll(filepath.Dir(service), 0700); e != nil {
		return result, e
	}
	encoded := serviceBytes(label, r.serviceArgs(path))
	if exists(service) {
		raw, e := privateRead(service, 16384, 0077)
		if e != nil {
			return result, e
		}
		if !r.serviceMatches(raw, label, path, true) {
			return result, errors.New("saved service changed")
		}
		native := r.serviceMatches(raw, label, path, false)
		expectedArgs := r.serviceArgs(path)
		if !native {
			expectedArgs = []string{filepath.Join(r.root(), "venv/bin/python"), filepath.Join(r.root(), "relay-desktop-route.py"), "listen", "--config", path}
		}
		expectedDefinition, _ := parsePlist(serviceBytes(label, expectedArgs))
		actualDefinition, _ := parsePlist(raw)
		if !reflect.DeepEqual(actualDefinition, expectedDefinition) {
			return result, errors.New("saved launch service behavior changed; explicit repair required")
		}
		if rebind || (!native && connect) {
			if e = r.stopService(ctx, label); e != nil {
				return result, e
			}
		}
		if !native {
			if !connect {
				return result, errors.New("legacy route requires explicit connection to migrate")
			}
			if e = atomicService(service, encoded); e != nil {
				return result, e
			}
		}
	} else {
		if e = exclusiveService(service, encoded); e != nil {
			return result, e
		}
	}
	if !hasOld {
		e = exclusiveJSON(path, c)
	} else if c != old {
		e = atomicJSON(path, c)
	}
	if e != nil {
		return result, e
	}
	if e = recordConnection(r.root(), c, "", time.Now()); e != nil {
		return result, e
	}
	if e = r.startService(ctx, label, service, connect); e != nil {
		return result, e
	}
	return savedRoute{path, service, label, c.LocalName}, nil
}

// LaunchAgents itself need not be private (macOS commonly creates 0755), but
// the service is an owned regular 0600 file and its parent cannot be writable
// by another user. Configs and receipts retain the stricter directory rule.
func serviceParent(path string) error {
	st, e := os.Lstat(filepath.Dir(path))
	if e != nil {
		return e
	}
	owner, ok := st.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() || !st.IsDir() || st.Mode().Perm()&0022 != 0 {
		return errors.New("unsafe LaunchAgents directory")
	}
	return nil
}
func atomicService(path string, raw []byte) error {
	if e := serviceParent(path); e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".relay-route-")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(raw)
	}
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e != nil {
		return e
	}
	if e = os.Rename(f.Name(), path); e != nil {
		return e
	}
	return syncDirectory(filepath.Dir(path))
}
func exclusiveService(path string, raw []byte) error {
	if e := serviceParent(path); e != nil {
		return e
	}
	f, e := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return e
	}
	_, e = f.Write(raw)
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e != nil {
		return e
	}
	return syncDirectory(filepath.Dir(path))
}
func (r *runtime) syncConnections() error {
	if !exists(r.root()) {
		return nil
	}
	if e := privateDirectory(r.root(), false); e != nil {
		return e
	}
	files, e := jsonFiles(r.root(), 65)
	if e != nil {
		return e
	}
	for _, path := range files {
		if filepath.Base(path) == "connections.json" {
			continue
		}
		c, e := readConfig(path)
		if e != nil {
			return e
		}
		if _, _, e = r.serviceFor(path); e != nil {
			return e
		}
		if e = recordConnection(r.root(), c, "", time.Now()); e != nil {
			return e
		}
	}
	return nil
}
func (r *runtime) handoff(ctx context.Context, path string, c Config, thread string) (Config, error) {
	if e := relativeConfig(r.root(), path); e != nil {
		return c, e
	}
	if !identifier.MatchString(thread) || thread == c.Thread {
		return c, errors.New("choose a different exact task")
	}
	if _, e := r.desktop.Inspect(ctx, c.Socket, thread, true); e != nil {
		return c, e
	}
	lock, e := fileLock(filepath.Join(r.root(), ".routes.lock"), false)
	if e != nil {
		return c, e
	}
	defer lock.Close()
	current, e := readConfig(path)
	if e != nil || current != c {
		return c, errIdentity
	}
	updated := c
	updated.Thread = thread
	existing, e := r.saved(updated)
	if e != nil {
		return c, e
	}
	if existing != "" {
		return c, errors.New("task already has a route to this session")
	}
	label, service, e := r.serviceFor(path)
	if e != nil {
		return c, e
	}
	if e = r.stopService(ctx, label); e != nil {
		return c, e
	}
	if e = atomicService(service, serviceBytes(label, r.serviceArgs(path))); e != nil {
		return c, e
	}
	if e = atomicJSON(path, updated); e != nil {
		return c, e
	}
	if e = recordConnection(r.root(), updated, c.Thread, time.Now()); e != nil {
		_ = atomicJSON(path, c)
		return c, e
	}
	if e = r.startService(ctx, label, service, true); e != nil {
		return updated, e
	}
	return updated, nil
}

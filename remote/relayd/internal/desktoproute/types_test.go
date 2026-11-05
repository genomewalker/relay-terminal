package desktoproute

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"
)

func configFixture() Config {
	return Config{Host: "remote", LocalName: "reply", Thread: "task-a", RemoteName: "peer", RemoteSession: "session-a", RemotePID: 123, RemoteStart: "456", Socket: "/tmp/desktop.sock"}
}
func TestStrictJSONAndConfig(t *testing.T) {
	valid := configFixture()
	b, _ := json.Marshal(valid)
	got, e := ParseConfig(b)
	if e != nil || got != valid {
		t.Fatalf("round trip: %v %+v", e, got)
	}
	for _, bad := range []string{`{"a":1,"a":2}`, `{"a":{"b":1,"b":2}}`, `{} {}`, `{"a":`, strings.Repeat("[", 34) + strings.Repeat("]", 34), "\xff"} {
		var v any
		if decodeJSON([]byte(bad), 65536, &v) == nil {
			t.Fatalf("accepted ambiguous/malformed JSON %q", bad)
		}
	}
	for _, edit := range []func(*Config){func(c *Config) { c.Thread = "../escape" }, func(c *Config) { c.RemotePID = 0 }, func(c *Config) { c.RemoteStart = "date" }, func(c *Config) { c.Socket = "relative" }, func(c *Config) { c.Host = "host;command" }} {
		c := valid
		edit(&c)
		if c.Validate() == nil {
			t.Fatalf("invalid config admitted: %+v", c)
		}
	}
	for i := 0; i < len(b); i++ {
		if _, e := ParseConfig(b[:i]); e == nil {
			t.Fatalf("truncated config admitted at %d", i)
		}
	}
}
func TestRouteIdentityFreshnessAndAcknowledgment(t *testing.T) {
	c := configFixture()
	now := time.Unix(100, 0)
	s := RouteState{Host: c.Host, LocalName: c.LocalName, LocalSession: c.Thread, RemoteSession: c.RemoteSession, RemotePID: c.RemotePID, RemoteStart: c.RemoteStart, State: "online", Heartbeat: 99, Mailbox: &Mailbox{PID: 999, Start: "789"}}
	if _, e := s.live(c, now); e != nil {
		t.Fatal(e)
	}
	for _, edit := range []func(*RouteState){func(v *RouteState) { v.LocalSession = "other" }, func(v *RouteState) { v.RemotePID++ }, func(v *RouteState) { v.RemoteStart = "different" }, func(v *RouteState) { v.Heartbeat = 74 }, func(v *RouteState) { v.Heartbeat = 101 }, func(v *RouteState) { v.Heartbeat = math.NaN() }, func(v *RouteState) { v.Mailbox = nil }, func(v *RouteState) { v.State = "offline" }} {
		v := s
		edit(&v)
		if _, e := v.live(c, now); e == nil {
			t.Fatalf("invalid route admitted %+v", v)
		}
	}
	for _, text := range []string{"Relay-Read-Receipt: id-1", "<cross-session-message from=\"peer\">\nRelay-Read-Receipt: id-1\n</cross-session-message>"} {
		if readAcknowledgment(text) != "id-1" {
			t.Fatal("exact acknowledgment rejected")
		}
	}
	for _, text := range []string{"Please send Relay-Read-Receipt: id-1", "Relay-Read-Receipt: id-1\nmore", "Relay-Read-Receipt: ../escape", "<cross-session-message from=\"peer\">Relay-Read-Receipt: id-1</cross-session-message>extra"} {
		if readAcknowledgment(text) != "" {
			t.Fatal("non-exact acknowledgment admitted")
		}
	}
}
func TestWorkFrameBoundsAndDecodedIdentity(t *testing.T) {
	value := `{"type":"response","requestId":"req","method":"test","resultType":"success","result":{}}`
	frame := make([]byte, 4)
	binary.LittleEndian.PutUint32(frame, uint32(len(value)))
	frame = append(frame, []byte(value)...)
	got, e := readWorkFrame(bytes.NewReader(frame))
	if e != nil || got.ID != "req" || got.Method != "test" {
		t.Fatalf("decoded frame lost fields: %+v %v", got, e)
	}
	for i := 0; i < len(frame); i++ {
		if _, e := readWorkFrame(bytes.NewReader(frame[:i])); e == nil {
			t.Fatalf("truncated frame accepted at %d", i)
		}
	}
	for _, size := range []uint32{0, 8<<20 + 1, math.MaxUint32} {
		var prefix [4]byte
		binary.LittleEndian.PutUint32(prefix[:], size)
		if _, e := readWorkFrame(bytes.NewReader(prefix[:])); e == nil {
			t.Fatal("oversized prefix accepted")
		}
	}
}
func TestPlistLiteralValidation(t *testing.T) {
	r := &runtime{home: "/private/home", exe: "/Applications/Relay.app/Contents/MacOS/relayd"}
	label := "dev.vaklab.relay-desktop-test"
	path := r.root() + "/a.json"
	raw := serviceBytes(label, r.serviceArgs(path))
	if !r.serviceMatches(raw, label, path, false) {
		t.Fatal("native service rejected")
	}
	legacy := serviceBytes(label, []string{r.root() + "/venv/bin/python", r.root() + "/relay-desktop-route.py", "listen", "--config", path})
	if r.serviceMatches(legacy, label, path, false) || !r.serviceMatches(legacy, label, path, true) {
		t.Fatal("legacy readback escaped migration-only boundary")
	}
	for _, bad := range [][]byte{bytes.Replace(raw, []byte("<key>Label</key>"), []byte("<key>Label</key><string>x</string><key>Label</key>"), 1), raw[:len(raw)-15], serviceBytes(label, []string{"/bin/sh", "-c", "arbitrary"}), append(append([]byte{}, raw...), raw...)} {
		if r.serviceMatches(bad, label, path, true) {
			t.Fatal("changed service admitted")
		}
	}
}
func FuzzRouteJSON(f *testing.F) {
	b, _ := json.Marshal(configFixture())
	for _, s := range [][]byte{b, []byte(`{"host":"a","host":"b"}`), []byte(`{"id":"id","content":"hello"}`), []byte(`{"type":"message","id":"id","sender":"peer","content":"body"}`)} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		if len(b) > 1<<17 {
			return
		}
		if c, e := ParseConfig(b); e == nil {
			if c.Validate() != nil {
				t.Fatal("invalid accepted config")
			}
			out, _ := json.Marshal(c)
			again, e := ParseConfig(out)
			if e != nil || again != c {
				t.Fatal("config round trip")
			}
			if _, e := ParseConfig(out[:len(out)-1]); e == nil {
				t.Fatal("truncated canonical config accepted")
			}
		}
		if m, e := parseEnvelope(b, false); e == nil {
			out, _ := json.Marshal(m)
			again, e := parseEnvelope(out, false)
			if e != nil || again.ID != m.ID || again.Content != m.Content {
				t.Fatal("envelope round trip")
			}
		}
		if event, e := parseEvent(b); e == nil {
			out, _ := json.Marshal(event)
			again, e := parseEvent(out)
			if e != nil || again != event {
				t.Fatal("event round trip")
			}
		}
		var v any
		if decodeJSON(b, messageLimit, &v) == nil {
			canonical, e := json.Marshal(v)
			if e != nil {
				t.Fatal(e)
			}
			var again any
			if e = decodeJSON(canonical, 6*messageLimit, &again); e != nil {
				t.Fatal("valid decode cannot round trip", e)
			}
		}
	})
}
func FuzzWorkAndPlist(f *testing.F) {
	f.Add([]byte{0, 0, 0, 0})
	f.Add(serviceBytes("dev.vaklab.relay-desktop-test", []string{"/app/relayd", "desktop-route", "listen", "--config", "/config"}))
	f.Fuzz(func(t *testing.T, b []byte) {
		if len(b) > 1<<17 {
			return
		}
		if _, e := readWorkFrame(bytes.NewReader(b)); e == nil {
			if len(b) < 4 {
				t.Fatal("short prefix accepted")
			}
			n := int(binary.LittleEndian.Uint32(b))
			if n == 0 || n > 8<<20 || len(b) < n+4 {
				t.Fatal("frame bounds escaped")
			}
			if _, e = readWorkFrame(bytes.NewReader(b[:n+3])); e == nil {
				t.Fatal("truncation accepted")
			}
		}
		if p, e := parsePlist(b); e == nil {
			if p == nil {
				t.Fatal("nil root admitted")
			}
			if _, e = parsePlist(append(append([]byte{}, b...), []byte("<plist/>")...)); e == nil {
				t.Fatal("trailing root accepted")
			}
		}
	})
}

func FuzzGroupAndPeerFrames(f *testing.F) {
	f.Add([]byte(`{"type":"user","from":"uds:/socket","msg_id":"id","message":{"content":"body"}}`))
	b, _ := json.Marshal(desktopPlan())
	f.Add(b)
	f.Fuzz(func(t *testing.T, b []byte) {
		if len(b) > messageLimit {
			return
		}
		target := peerRecord{Name: "peer", Socket: "/socket"}
		auth := []byte(`{"type":"auth","token":"secret"}`)
		if m, e := parsePeerMessage(auth, b, "secret", target); e == nil {
			if !messageID.MatchString(m.ID) || m.Sender != "peer" {
				t.Fatal("peer identity escaped")
			}
			if _, e := parsePeerMessage(auth, b, "other", target); e == nil {
				t.Fatal("wrong key accepted")
			}
			changed := target
			changed.Socket = "/other"
			if _, e := parsePeerMessage(auth, b, "secret", changed); e == nil {
				t.Fatal("changed sender accepted")
			}
		}
		var p groupPlan
		if decodeJSON(b, messageLimit, &p) == nil {
			if edges, e := p.edges(); e == nil {
				if len(edges) == 0 || len(edges) > 28 {
					t.Fatal("unbounded topology")
				}
				seen := map[[2]string]bool{}
				for _, edge := range edges {
					key := [2]string{edge[0].identity(), edge[1].identity()}
					if seen[key] || key[0] == key[1] {
						t.Fatal("duplicate/self edge")
					}
					seen[key] = true
				}
				round, _ := json.Marshal(p)
				var q groupPlan
				if decodeJSON(round, 6*messageLimit, &q) != nil {
					t.Fatal("plan round trip")
				}
				again, e := q.edges()
				if e != nil || len(again) != len(edges) {
					t.Fatal("topology changed")
				}
			}
		}
	})
}

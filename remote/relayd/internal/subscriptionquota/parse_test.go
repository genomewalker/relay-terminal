package subscriptionquota

import (
	"bytes"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"math"
	"os"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"
)

var fixtureNow = time.Date(2026, 10, 25, 7, 0, 0, 123456000, time.UTC)

func TestStatuslineSignalExitUsesPythonConvention(t *testing.T) {
	if statusExitCode(7, syscall.WaitStatus(7<<8)) != 7 || statusExitCode(-1, syscall.WaitStatus(syscall.SIGTERM)) != -int(syscall.SIGTERM) {
		t.Fatal("statusline exit/signal result changed")
	}
	for raw := 0; raw < 256; raw++ {
		status := syscall.WaitStatus(raw)
		got := statusExitCode(-1, status)
		if status.Signaled() {
			if got != -int(status.Signal()) {
				t.Fatal("signal number was collapsed")
			}
		} else if got != -1 {
			t.Fatal("non-signal state invented signal")
		}
	}
}

func mustJSON(t testing.TB, v any) []byte {
	t.Helper()
	b, err := marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
func equalJSON(t testing.TB, got []byte, want any) {
	t.Helper()
	var a, b any
	if json.Unmarshal(got, &a) != nil || json.Unmarshal(mustJSON(t, want), &b) != nil || !reflect.DeepEqual(a, b) {
		t.Fatalf("JSON mismatch\ngot %s\nwant %s", got, mustJSON(t, want))
	}
}

func TestFrozenPythonOracleVectors(t *testing.T) {
	data, err := os.ReadFile("testdata/oracle-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	root, err := decodeObject(data, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if text(root["oracle_sha256"]) != "b36faaa9290d972ba4e7f5a4f9aaa0177304c3ffc24e84cb5674922f16d29a0b" {
		t.Fatal("oracle provenance changed")
	}
	for _, raw := range root["identity"].([]any) {
		v := object(raw)
		if got := identityDigest(v["identity"].([]any)); got != v["expected"] {
			t.Fatalf("identity digest changed: %s", v["provider"])
		}
	}
	for _, raw := range root["usage"].([]any) {
		v := object(raw)
		t.Run(text(v["name"]), func(t *testing.T) {
			got, err := parseUsage(mustJSON(t, v["input"]), v["plan"], v["scope"], fixtureNow)
			if (err != nil) != v["error"].(bool) {
				t.Fatalf("acceptance changed: %v", err)
			}
			equalJSON(t, mustJSON(t, got), v["expected"])
		})
	}
	for _, raw := range root["resets"].([]any) {
		v := object(raw)
		got, err := resetTimestamp(text(v["input"]))
		if (err != nil) != v["error"].(bool) {
			t.Fatalf("reset acceptance changed: %q %v", v["input"], err)
		}
		if err == nil {
			want, _ := v["expected"].(json.Number).Float64()
			if math.Abs(got-want) > 0.000001 {
				t.Fatalf("reset changed: %.9f %.9f", got, want)
			}
		}
	}
	for _, raw := range root["capture"].([]any) {
		v := object(raw)
		got, err := statusRecord(mustJSON(t, v["input"]), v["scope"], fixtureNow)
		if err != nil {
			t.Fatal(err)
		}
		equalJSON(t, mustJSON(t, got), v["expected"])
	}
}

func TestQuotaParserRejections(t *testing.T) {
	for _, b := range [][]byte{[]byte(`{"x":`), []byte(`{"x":1} false`), []byte(`[]`), []byte(`null`), []byte(`{"x":"` + strings.Repeat("x", Limit) + `"}`), {0xff}} {
		if _, err := decodeObject(b, Limit); err == nil {
			t.Fatalf("invalid object accepted: %.80q", b)
		}
	}
	for _, bad := range []string{"", "../escape", "a/b", "ABC\x00DEF", strings.Repeat("a", 111)} {
		if validID(bad) {
			t.Fatalf("path escaping identifier accepted: %q", bad)
		}
	}
	for _, bad := range []string{"a", "YQ", "/w==", strings.Repeat("a", (1<<20)+1)} {
		if _, err := decodeCommand(bad); err == nil {
			t.Fatal("invalid command encoding accepted")
		}
	}
	for _, empty := range []string{"!", "===="} {
		if got, err := decodeCommand(empty); err != nil || got != "" {
			t.Fatal("legacy permissive empty encoding changed")
		}
	}
	if got, err := decodeCommand("Y2F0\n"); err != nil || got != "cat" {
		t.Fatal("legacy base64 whitespace lost")
	}
}

func frame(op byte, data []byte) []byte {
	b := []byte{0x80 | op}
	if len(data) < 126 {
		b = append(b, byte(len(data)))
	} else if len(data) <= 65535 {
		b = append(b, 126, byte(len(data)>>8), byte(len(data)))
	} else {
		b = append(b, 127)
		b = binary.BigEndian.AppendUint64(b, uint64(len(data)))
	}
	return append(b, data...)
}
func upgrade(key string) []byte {
	sum := sha1.Sum([]byte(key + websocketGUID))
	return []byte("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + base64.StdEncoding.EncodeToString(sum[:]) + "\r\n\r\n")
}

func TestProtocolRejectsWrongAuthorityAndFrames(t *testing.T) {
	key := "synthetic-nonce"
	good := upgrade(key)
	if parseUpgrade(good, key) != nil {
		t.Fatal("valid handshake rejected")
	}
	for _, b := range [][]byte{good[:len(good)-1], upgrade("wrong"), bytes.Replace(good, []byte(" 101 "), []byte(" 200 "), 1), bytes.Repeat([]byte("x"), 8193)} {
		if parseUpgrade(b, key) == nil {
			t.Fatal("invalid handshake accepted")
		}
	}
	for _, b := range [][]byte{{0x81, 0x80}, {0x01, 0}, {0xc1, 0}, {0x82, 0}, {0x88, 0}, {0x81, 127, 0x80, 0, 0, 0, 0, 0, 0, 0}, frame(9, make([]byte, 126)), frame(1, make([]byte, Limit+1))} {
		if _, _, err := readFrame(bytes.NewReader(b)); err == nil {
			t.Fatalf("unsafe frame accepted: %.15v", b)
		}
	}
}

func FuzzQuotaObject(f *testing.F) {
	for _, seed := range []string{`{}`, `{"id":"exact-雪","n":1.0}`, `{"x":1,"x":2}`, `{"bad":`, `[]`, `{"token":"never-identity"}`} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		value, err := decodeObject(raw, Limit)
		if err != nil {
			return
		}
		if len(raw) > Limit {
			t.Fatal("input bound exceeded")
		}
		encoded := mustJSON(t, value)
		round, err := decodeObject(encoded, 6*Limit)
		if len(encoded) > 6*Limit || err != nil || !reflect.DeepEqual(value, round) {
			t.Fatal("JSON values/IDs changed")
		}
		trimmed := bytes.TrimSpace(raw)
		if _, err := decodeObject(trimmed[:len(trimmed)-1], Limit); err == nil {
			t.Fatal("truncated object accepted")
		}
		if _, err := decodeObject(append(bytes.Clone(raw), []byte(" false")...), Limit); err == nil {
			t.Fatal("trailing input accepted")
		}
	})
}

func assertWindows(t testing.TB, record map[string]any) {
	t.Helper()
	for _, raw := range object(record["rate_limits"]) {
		w := object(raw)
		used, ok := w["used_percentage"].(float64)
		if !ok || used < 0 || used > 100 || math.IsNaN(used) || math.IsInf(used, 0) {
			t.Fatal("unreported/invalid percentage admitted")
		}
		if reset := w["resets_at"]; reset != nil {
			switch n := reset.(type) {
			case json.Number:
				if !resetNumber(n) {
					t.Fatal("invalid reset admitted")
				}
			case float64:
				if n <= 0 || n >= 253402300800 {
					t.Fatal("invalid reset admitted")
				}
			default:
				t.Fatal("invalid reset type")
			}
		}
	}
}

func FuzzQuotaUsage(f *testing.F) {
	for _, seed := range []string{`{}`, `{"five_hour":{"utilization":25}}`, `{"five_hour":{"utilization":101}}`, `{"five_hour":{"utilization":true}}`, `{"five_hour":{"utilization":25,"resets_at":"2026-10-25T08:30:00Z"}}`, `{"limits":[{"percent":12,"scope":{"model":{"display_name":"Opus"}},"resets_at":"2026-10-25T08:30:00Z"}]}`} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		got, err := parseUsage(raw, "fixture", "digest-only", fixtureNow)
		if err != nil || got == nil {
			return
		}
		if len(raw) > Limit {
			t.Fatal("usage allocation bound")
		}
		obs := object(got["observation"])
		assertWindows(t, obs)
		if len(obs["additional_limits"].([]any)) > 32 {
			t.Fatal("scoped limit bound")
		}
		for _, raw := range obs["additional_limits"].([]any) {
			entry := object(raw)
			used, ok := entry["used_percentage"].(float64)
			reset, resetOK := entry["resets_at"].(float64)
			if !ok || used < 0 || used > 100 || !resetOK || reset <= 0 || reset >= 253402300800 {
				t.Fatal("invalid scoped window admitted")
			}
		}
		if got["account_scope"] != "digest-only" || got["provider"] != "claude" {
			t.Fatal("identity changed")
		}
		if _, err := decodeObject(mustJSON(t, got), 1<<20); err != nil {
			t.Fatal("invalid output")
		}
	})
}

func FuzzQuotaReset(f *testing.F) {
	for _, seed := range []string{"2026-10-25T08:30:00Z", "2026-10-25T08:30:00.123456+02:00", "2023-02-29T00:00:00Z", "2026-1-2T3:4:5+0000", "invalid"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, raw string) {
		stamp, err := resetTimestamp(raw)
		if err != nil {
			return
		}
		if math.IsNaN(stamp) || math.IsInf(stamp, 0) || stamp < -62135683200 || stamp > 253402387200 {
			t.Fatal("timestamp bounds")
		}
		if _, err := resetTimestamp(raw + "x"); err == nil {
			t.Fatal("trailing reset accepted")
		}
		if len(raw) > 80 {
			t.Fatal("reset input bound")
		}
		if raw == "2026-10-25T08:30:00.123456+02:00" {
			want := float64(time.Date(2026, 10, 25, 6, 30, 0, 0, time.UTC).Unix()) + .123456
			if math.Abs(stamp-want) > .000001 {
				t.Fatal("timezone/microsecond meaning changed")
			}
		}
	})
}

func FuzzQuotaStatus(f *testing.F) {
	for _, seed := range []string{`{"session_id":"abcdef","rate_limits":{"five_hour":{"used_percentage":25}}}`, `{"session_id":"../escape"}`, `{"session_id":"abcdef","rate_limits":{"five_hour":{"used_percentage":101}}}`, `{"session_id":"abcdef","rate_limits":{"seven_day":{"used_percentage":true}}}`} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		record, err := statusRecord(raw, "fixed-scope", fixtureNow)
		if err != nil || record == nil {
			return
		}
		if !validID(text(record["session_id"])) || strings.ContainsAny(text(record["session_id"]), "/\\") {
			t.Fatal("status path escaped root")
		}
		assertWindows(t, record)
		if len(record) != 4 || record["account_scope"] != "fixed-scope" {
			t.Fatal("status leaked extra/identity fields")
		}
	})
}

func FuzzQuotaFrame(f *testing.F) {
	for _, seed := range [][]byte{frame(1, []byte(`{"id":2,"result":{}}`)), frame(9, []byte("ping")), frame(1, make([]byte, Limit+1)), {0x81, 126, 0, 2, 'x'}, {0x81, 127, 255, 255, 255, 255, 255, 255, 255, 255}} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		r := bytes.NewReader(raw)
		op, data, err := readFrame(r)
		if err != nil {
			return
		}
		if len(data) > Limit || op != 1 && op != 9 || op == 9 && len(data) > 125 {
			t.Fatal("frame allocation/protocol bound")
		}
		encoded := frame(op, data)
		roundOp, round, err := readFrame(bytes.NewReader(encoded))
		if err != nil || roundOp != op || !bytes.Equal(round, data) {
			t.Fatal("frame round trip")
		}
		if _, _, err := readFrame(bytes.NewReader(encoded[:len(encoded)-1])); err == nil {
			t.Fatal("truncated frame accepted")
		}
		if len(raw)-r.Len() > Limit+10 {
			t.Fatal("unbounded frame consumption")
		}
	})
}

func FuzzQuotaUpgrade(f *testing.F) {
	for _, seed := range [][]byte{upgrade("fixture"), []byte("HTTP/1.1 101\r\n"), upgrade("wrong"), {}} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		if parseUpgrade(raw, "fixture") != nil {
			return
		}
		if len(raw) > 8192 {
			t.Fatal("upgrade allocation bound")
		}
		if parseUpgrade(raw[:len(raw)-1], "fixture") == nil {
			t.Fatal("truncated upgrade accepted")
		}
		if parseUpgrade(raw, "different-nonce") == nil {
			t.Fatal("handshake lost nonce authority")
		}
	})
}

func FuzzQuotaCommand(f *testing.F) {
	for _, seed := range []string{"Y2F0", "cHJpbnRmICJoaSI=", "invalid", "Y2F0\n"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, raw string) {
		command, err := decodeCommand(raw)
		if err != nil {
			return
		}
		if len(raw) > 1<<20 {
			t.Fatal("command allocation bound")
		}
		round, err := decodeCommand(base64.StdEncoding.EncodeToString([]byte(command)))
		if err != nil || round != command {
			t.Fatal("command round trip changed exact bytes")
		}
	})
}

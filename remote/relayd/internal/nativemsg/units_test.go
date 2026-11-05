//go:build linux || darwin

package nativemsg

import (
	"bytes"
	"context"
	"encoding/binary"
	"math"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Expected values are what CPython 3.6 json, str and posixpath produce.

func TestJSONRoundTripsAsPython(t *testing.T) {
	for _, c := range []struct{ in, out string }{
		{`{"b": 1, "a": [true, false, null]}`, `{"a": [true, false, null], "b": 1}`},
		{`12345678901234567890123`, `12345678901234567890123`},
		{`-0`, `0`},
		{`1.0`, `1.0`},
		{`1e16`, `1e+16`},
		{`0.1`, `0.1`},
		{`1E400`, `Infinity`},
		{`[NaN, -Infinity]`, `[NaN, -Infinity]`},
		{`"\u00e9\u2028\ud83d\ude00"`, `"\u00e9\u2028\ud83d\ude00"`},
		{"\"\u00e9\U0001F600\"", `"\u00e9\ud83d\ude00"`},
		{`"\ud800"`, `"\ud800"`},
		{`"\"\\\/\b\f\n\r\t\u007f"`, `"\"\\/\b\f\n\r\t\u007f"`},
		{" \t\n{\"a\" : {}}\r\n", `{"a": {}}`},
		{`{"a": 1, "a": 2}`, `{"a": 2}`},
	} {
		value, err := loadsText([]byte(c.in))
		if err != nil {
			t.Fatalf("%s: %v", c.in, err)
		}
		if got := dumps(value, true); got != c.out {
			t.Errorf("%s: got %s, want %s", c.in, got, c.out)
		}
	}
}

func TestJSONErrorsAreCPythonsMessages(t *testing.T) {
	for _, c := range []struct{ in, err string }{
		{``, "Expecting value: line 1 column 1 (char 0)"},
		{`[1 2]`, "Expecting ',' delimiter: line 1 column 4 (char 3)"},
		{`{"a": 1,}`, "Expecting property name enclosed in double quotes: line 1 column 9 (char 8)"},
		{`{"a" 1}`, "Expecting ':' delimiter: line 1 column 6 (char 5)"},
		{`[1] x`, "Extra data: line 1 column 5 (char 4)"},
		{"\"a\x01\"", "Invalid control character at: line 1 column 3 (char 2)"},
		{`"abc`, "Unterminated string starting at: line 1 column 1 (char 0)"},
		{`"\x"`, "Invalid \\escape: line 1 column 2 (char 1)"},
		{`"\u12"`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{"[\n\"\u00e9\", x]", "Expecting value: line 2 column 6 (char 7)"},
		{"\ufeff{}", "Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0)"},
		{`nan`, "Expecting value: line 1 column 1 (char 0)"},
	} {
		_, err := loadsText([]byte(c.in))
		if err == nil || err.Error() != c.err {
			t.Errorf("%q: got %v, want %q", c.in, err, c.err)
		}
		if err != nil && !isA(err, classValue) {
			t.Errorf("%q: %v is not a ValueError", c.in, err)
		}
	}
	if _, err := loadsText([]byte("\"\xff\"")); err == nil ||
		err.Error() != "'utf-8' codec can't decode byte 0xff in position 1: invalid start byte" || !isA(err, classValue) {
		t.Errorf("invalid UTF-8: %v", err)
	}
	if value, err := loadsBytes([]byte("\xef\xbb\xbf[1]")); err != nil || dumps(value, true) != "[1]" {
		t.Errorf("bytes with a UTF-8 BOM: %v %v", value, err)
	}
	if _, err := loadsText([]byte(strings.Repeat("[", 5000))); err == nil || !isA(err, classRuntime) {
		t.Errorf("deep nesting: %v", err)
	}
}

func TestDumpsEscapesAsEnsureASCII(t *testing.T) {
	value := obj{{"z", "\x00\x1f \x7e\x7f<&>"}, {"a", math.Inf(1)}, {"m", map[string]any{"y": int64(1), "x": 1.5}}}
	want := `{"z": "\u0000\u001f ~\u007f<&>", "a": Infinity, "m": {"x": 1.5, "y": 1}}`
	if got := dumps(value, false); got != want {
		t.Errorf("got %s\nwant %s", got, want)
	}
	if got := dumps(value, true); !strings.HasPrefix(got, `{"a": Infinity, "m"`) {
		t.Errorf("sorted: %s", got)
	}
}

func TestPythonValueSemantics(t *testing.T) {
	if !pyEqual(true, int64(1)) || !pyEqual(1.0, int64(1)) || pyEqual("1", int64(1)) || !pyEqual(nil, nil) || pyEqual(nil, false) {
		t.Error("pyEqual numeric rules")
	}
	if pyEqual(map[string]any{"a": int64(1)}, map[string]any{"a": int64(1), "b": nil}) || !pyEqual([]any{1.0}, []any{int64(1)}) {
		t.Error("pyEqual containers")
	}
	for in, want := range map[string]string{`a'b`: `"a'b"`, `a'"b`: `'a\'"b'`, "\x00\t\u00e9\u2028": `'\x00\t` + "\u00e9" + `\u2028'`} {
		if got := pyRepr(in); got != want {
			t.Errorf("repr(%q) = %s, want %s", in, got, want)
		}
	}
	for in, want := range map[string]string{" 1_0 ": "10", "007": "7", "-5": "-5", "\u0661\u0662": "12"} {
		if got, err := pyIntConvert(in); err != nil || got.String() != want {
			t.Errorf("int(%q) = %v %v", in, got, err)
		}
	}
	for _, in := range []string{"1__0", "_1", "1.0", ""} {
		if _, err := pyIntConvert(in); err == nil || err.Error() != "invalid literal for int() with base 10: "+pyRepr(in) {
			t.Errorf("int(%q): %v", in, err)
		}
	}
	if got := pyStrip("\x1c\u00a0 a b\u3000\n"); got != "a b" {
		t.Errorf("strip: %q", got)
	}
	if got := pyHTMLEscape(`&<>"'x`); got != "&amp;&lt;&gt;&quot;&#x27;x" {
		t.Errorf("html.escape: %s", got)
	}
	if got := pySlice("\U0001F600abc", 2); got != "\U0001F600a" {
		t.Errorf("slice counts code points: %q", got)
	}
	if _, err := pyGet([]any{}, "a", nil); err == nil || err.Error() != "'list' object has no attribute 'get'" {
		t.Errorf("get on a list: %v", err)
	}
	if _, err := pyIndex(map[string]any{}, "missing"); err == nil || err.Error() != "'missing'" || !isA(err, classKey) {
		t.Errorf("missing key: %v", err)
	}
	for f, want := range map[float64]string{1: "1.0", 0.1: "0.1", 1e16: "1e+16", 1e-5: "1e-05", 123456789012345680: "1.2345678901234568e+17", -0.0: "-0.0"} {
		if got := pyFloatRepr(f); got != want && !(f == 0 && got == "0.0") {
			t.Errorf("repr(%v) = %s, want %s", f, got, want)
		}
	}
}

func TestPathsNormalizeAsPosixpath(t *testing.T) {
	for in, want := range map[string]string{"//a/../b": "//b", "///a//": "/a", "a/./b/..": "a", "": ".", "/..": "/", "../a": "../a"} {
		if got := normpath(in); got != want {
			t.Errorf("normpath(%q) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{"//a//b/": "//a/b", "///a": "/a", "a/./b": "a/b", "": "."} {
		if got := pathNorm(in); got != want {
			t.Errorf("PurePosixPath(%q) = %q, want %q", in, got, want)
		}
	}
	if pathSuffix("/a/b.tar.gz") != ".gz" || pathSuffix("/a/.hidden") != "" || pathParent("/") != "/" || pathName("/a/b") != "b" {
		t.Error("suffix, parent or name")
	}
	if !pathRelativeTo("/a/b/c", "/a/b") || pathRelativeTo("/a/bc", "/a/b") {
		t.Error("relative_to")
	}
	if _, err := pathFrom(int64(1)); err == nil || err.Error() != "expected str, bytes or os.PathLike object, not int" {
		t.Errorf("path of an int: %v", err)
	}
}

func TestResolveFollowsLinksAsPathlib(t *testing.T) {
	dir := shortTempDir(t)
	real, _ := filepath.EvalSymlinks(dir)
	os.Mkdir(filepath.Join(dir, "d"), 0o700)
	os.Symlink("d", filepath.Join(dir, "l"))
	os.Symlink("loop", filepath.Join(dir, "loop"))
	if got, err := resolvePath(dir+"/l/x/../y", "/", false); err != nil || got != real+"/d/y" {
		t.Errorf("non-strict: %q %v", got, err)
	}
	if _, err := resolvePath(dir+"/l/missing", "/", true); err == nil || !isA(err, classOS) {
		t.Errorf("strict missing: %v", err)
	}
	if _, err := resolvePath(dir+"/loop", "/", false); err == nil || !isA(err, classRuntime) ||
		!strings.HasPrefix(err.Error(), "Symlink loop from '") {
		t.Errorf("loop: %v", err)
	}
	if got, err := resolvePath("l", dir, false); err != nil || got != real+"/d" {
		t.Errorf("relative: %q %v", got, err)
	}
}

// socketPair is a connected client pySocket and its raw server end.
func socketPair(t *testing.T) (*pySocket, net.Conn) {
	t.Helper()
	path := filepath.Join(shortTempDir(t), "w.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, _ := listener.Accept()
		accepted <- conn
	}()
	client, err := dialUnix(context.Background(), path, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	server := <-accepted
	t.Cleanup(func() { client.close(); server.Close() })
	return client, server
}

func fixedMask(n int) []byte { return bytes.Repeat([]byte{0xA5}, n)[:n] }

func serverFrame(first byte, payload []byte) []byte {
	frame := []byte{first}
	switch n := len(payload); {
	case n < 126:
		frame = append(frame, byte(n))
	case n < 65536:
		frame = append(frame, 126)
		frame = binary.BigEndian.AppendUint16(frame, uint16(n))
	default:
		frame = append(frame, 127)
		frame = binary.BigEndian.AppendUint64(frame, uint64(n))
	}
	return append(frame, payload...)
}

func readClientFrame(t *testing.T, conn net.Conn) (byte, []byte) {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	head := make([]byte, 2)
	if _, err := conn.Read(head); err != nil {
		t.Fatal(err)
	}
	if head[1]&0x80 == 0 {
		t.Fatal("client frame is not masked")
	}
	length := uint64(head[1] & 127)
	readFull := func(n uint64) []byte {
		b := make([]byte, n)
		for got := 0; got < len(b); {
			m, err := conn.Read(b[got:])
			if err != nil {
				t.Fatal(err)
			}
			got += m
		}
		return b
	}
	switch length {
	case 126:
		length = uint64(binary.BigEndian.Uint16(readFull(2)))
	case 127:
		length = binary.BigEndian.Uint64(readFull(8))
	}
	mask := readFull(4)
	payload := readFull(length)
	for i := range payload {
		payload[i] ^= mask[i%4]
	}
	return head[0], payload
}

func TestWebSocketFramesAreMaskedAndSized(t *testing.T) {
	client, server := socketPair(t)
	ws := &webSocket{socket: client, randomBytes: fixedMask}
	for _, size := range []int{0, 125, 126, 65535, 65536} {
		payload := bytes.Repeat([]byte("x"), size)
		go ws.send(1, payload)
		first, got := readClientFrame(t, server)
		if first != 0x81 || !bytes.Equal(got, payload) {
			t.Fatalf("size %d: first %#x, %d bytes", size, first, len(got))
		}
	}
	if err := ws.send(1, make([]byte, 65537)); err == nil || err.Error() != "Native message exceeds frame limit" {
		t.Fatalf("oversized: %v", err)
	}
	// The mask is applied, not merely announced.
	go ws.send(1, []byte("ab"))
	server.SetReadDeadline(time.Now().Add(2 * time.Second))
	raw := make([]byte, 8)
	if _, err := server.Read(raw); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(raw, []byte{0x81, 0x82, 0xA5, 0xA5, 0xA5, 0xA5, 'a' ^ 0xA5, 'b' ^ 0xA5}) {
		t.Fatalf("raw frame %x", raw)
	}
}

func receiveAfter(t *testing.T, frames ...[]byte) (any, error, net.Conn) {
	t.Helper()
	client, server := socketPair(t)
	ws := &webSocket{socket: client, randomBytes: fixedMask}
	go server.Write(bytes.Join(frames, nil))
	value, err := ws.receive()
	return value, err, server
}

func TestWebSocketReceiveRules(t *testing.T) {
	if value, err, _ := receiveAfter(t, serverFrame(0x01, []byte(`{"a":`)), serverFrame(0x8A, nil),
		serverFrame(0x80, []byte(`1}`))); err != nil || dumps(value, true) != `{"a": 1}` {
		t.Errorf("fragmented with a pong between: %v %v", value, err)
	}
	value, err, server := receiveAfter(t, serverFrame(0x89, []byte("hb")), serverFrame(0x81, []byte(`2`)))
	if err != nil || dumps(value, true) != "2" {
		t.Errorf("after ping: %v %v", value, err)
	}
	if first, payload := readClientFrame(t, server); first != 0x8A || string(payload) != "hb" {
		t.Errorf("pong %#x %q", first, payload)
	}
	for name, c := range map[string]struct {
		frames [][]byte
		err    string
		class  string
	}{
		"rsv1":                 {[][]byte{serverFrame(0xC1, []byte("1"))}, "Invalid native websocket frame", classValue},
		"rsv3":                 {[][]byte{serverFrame(0x91, []byte("1"))}, "Invalid native websocket frame", classValue},
		"masked server frame":  {[][]byte{{0x81, 0x81, 0, 0, 0, 0, '1'}}, "Invalid native websocket frame", classValue},
		"close":                {[][]byte{serverFrame(0x88, []byte{3, 232})}, "Native websocket closed", classConnection},
		"continuation first":   {[][]byte{serverFrame(0x80, []byte("1"))}, "Invalid native websocket continuation", classValue},
		"text inside text":     {[][]byte{serverFrame(0x01, []byte("1")), serverFrame(0x81, []byte("2"))}, "Invalid native websocket continuation", classValue},
		"binary":               {[][]byte{serverFrame(0x82, []byte("1"))}, "Invalid native websocket continuation", classValue},
		"oversized length":     {[][]byte{{0x81, 127, 0, 0, 0, 0, 0, 0x20, 0, 1}}, "Native response exceeds limit", classValue},
		"oversized assembly":   {[][]byte{serverFrame(0x01, make([]byte, 65536)), {0x80, 127, 0, 0, 0, 0, 0, 0x1F, 0, 1}}, "Native response exceeds limit", classValue},
		"invalid JSON payload": {[][]byte{serverFrame(0x81, []byte("{"))}, "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)", classValue},
	} {
		_, err, _ := receiveAfter(t, c.frames...)
		if err == nil || err.Error() != c.err || !isA(err, c.class) {
			t.Errorf("%s: got %v, want %s %q", name, err, c.class, c.err)
		}
	}
	client, server := socketPair(t)
	server.Close()
	ws := &webSocket{socket: client, randomBytes: fixedMask}
	if _, err := ws.receive(); err == nil || err.Error() != "Native websocket closed" || !isA(err, classConnection) || !isA(err, classOS) {
		t.Errorf("eof: %v", err)
	}
}

func TestWebSocketRPCRefusesServerRequests(t *testing.T) {
	client, server := socketPair(t)
	ws := &webSocket{socket: client, randomBytes: fixedMask}
	type reply struct {
		value any
		err   error
	}
	done := make(chan reply, 1)
	go func() {
		value, err := ws.rpc("thread/read", obj{{"threadId", "t"}})
		done <- reply{value, err}
	}()
	if _, request := readClientFrame(t, server); string(request) != `{"id": 1, "method": "thread/read", "params": {"threadId": "t"}}` {
		t.Fatalf("request %s", request)
	}
	server.Write(serverFrame(0x81, []byte(`{"id": 7, "method": "item/commandExecution/requestApproval", "params": {}}`)))
	if _, refusal := readClientFrame(t, server); string(refusal) !=
		`{"id": 7, "error": {"code": -32601, "message": "Relay messaging does not own this request"}}` {
		t.Fatalf("refusal %s", refusal)
	}
	server.Write(serverFrame(0x81, []byte(`{"method": "thread/started", "params": {}}`)))
	server.Write(serverFrame(0x81, []byte(`{"id": 1.0, "result": {"ok": true}}`)))
	got := <-done
	if got.err != nil || dumps(got.value, true) != `{"ok": true}` {
		t.Fatalf("result %v %v", got.value, got.err)
	}
	go func() {
		_, err := ws.rpc("turn/start", obj{})
		done <- reply{nil, err}
	}()
	readClientFrame(t, server)
	server.Write(serverFrame(0x81, []byte(`{"id": 2, "error": {"code": 1}}`)))
	if got := <-done; got.err == nil || got.err.Error() != "Native provider rejected turn/start" {
		t.Fatalf("error reply: %v", got.err)
	}
}

func TestSendAfterTheDeadlineWritesNothing(t *testing.T) {
	client, server := socketPair(t)
	ctx, cancel := context.WithCancel(context.Background())
	client.ctx = ctx
	cancel()
	if err := client.sendall([]byte("x")); err == nil || !isA(err, classTimeout) || !isA(err, classOS) {
		t.Fatalf("sendall after cancel: %v", err)
	}
	server.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
	if n, _ := server.Read(make([]byte, 1)); n != 0 {
		t.Fatal("wrote after the deadline")
	}
}

func statLine(pid, comm, state, ppid string) string {
	fields := []string{pid, "(" + comm + ")", state, ppid}
	for i := 5; i <= 52; i++ {
		fields = append(fields, "0")
	}
	fields[21] = "4242"
	return strings.Join(fields, " ") + "\n"
}

func TestProcfsListsAsProcps(t *testing.T) {
	root := shortTempDir(t)
	uid := os.Getuid()
	write := func(pid, euid int, comm, state string) {
		dir := filepath.Join(root, strconv.Itoa(pid))
		os.MkdirAll(dir, 0o700)
		os.WriteFile(filepath.Join(dir, "stat"), []byte(statLine(strconv.Itoa(pid), comm, state, "1")), 0o600)
		os.WriteFile(filepath.Join(dir, "status"), []byte("Name:\tx\nUid:\t0\t"+strconv.Itoa(euid)+"\t0\t0\n"), 0o600)
	}
	write(2, uid, "a b) (c", "S")
	write(3, uid, "claude", "Z")
	write(4, uid+1, "other", "S")
	write(5, uid, "t\x01\xc3\xa9", "R")
	os.MkdirAll(filepath.Join(root, "self"), 0o700)
	os.WriteFile(filepath.Join(root, "stat"), []byte("cpu 0\nbtime 1700000000\n"), 0o600)
	source := procfs{root: root, uid: int64(uid)}
	rows, err := source.processes()
	if err != nil {
		t.Fatal(err)
	}
	got := map[int64]string{}
	for _, row := range rows {
		if row.ppid != 1 || row.uid != int64(uid) {
			t.Errorf("row %+v", row)
		}
		got[row.pid] = row.comm
	}
	want := map[int64]string{2: "a b) (c", 3: "claude <defunct>", 5: "t???"}
	if len(got) != len(want) {
		t.Fatalf("rows %v", got)
	}
	for pid, comm := range want {
		if got[pid] != comm {
			t.Errorf("pid %d comm %q, want %q", pid, got[pid], comm)
		}
	}
	if start, err := source.identity(2); err != nil || start != "linux:4242" {
		t.Errorf("identity %q %v", start, err)
	}
	if epoch, err := source.epoch(2); err != nil || epoch != 1700000042.42 {
		t.Errorf("epoch %v %v", epoch, err)
	}
	if _, err := (procfs{root: root, uid: int64(uid + 1)}).identity(2); err == nil || err.Error() != "Process owner changed." || !isA(err, classUnbound) {
		t.Errorf("foreign owner: %v", err)
	}
	if _, err := source.identity(9); err == nil || !isA(err, classOS) || !strings.HasPrefix(err.Error(), "[Errno 2] No such file or directory: '") {
		t.Errorf("missing: %v", err)
	}
}

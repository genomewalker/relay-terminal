package daemon

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestHostVaultUnlockUsesHostAccountBoundaryWithoutEcho(t *testing.T) {
	secret := "FIXTURE_VAULT_PASSWORD_NOT_A_REAL_SECRET"
	request := map[string]any{"v": 1, "operation": "text_vault_unlock", "credential_secret": secret}
	called := false
	response, err := handleNodeHostAccountsRequest(context.Background(), accountEnvelope(t, request),
		func(_ context.Context, got hostRotationRequest, expected *string) (json.RawMessage, error) {
			called = got.Operation == "text_vault_unlock" && got.CredentialSecret == secret && expected == nil
			return json.RawMessage(`{"v":1,"status":"unlocked","storage":"linux_secret_service"}`), nil
		})
	if err != nil || !called || bytes.Contains(response, []byte(secret)) || bytes.Contains(response, []byte("credential_secret")) {
		t.Fatal("vault unlock was not a private host-account operation")
	}
	for _, extra := range []map[string]any{
		{"session_id": "untrusted-pane"}, {"credential_reference": strings.Repeat("a", 32)},
		{"credential_account_id": strings.Repeat("b", 32)}, {"id": strings.Repeat("c", 32)},
	} {
		q := map[string]any{"v": 1, "operation": "text_vault_unlock", "credential_secret": secret}
		for k, v := range extra {
			q[k] = v
		}
		raw, _ := json.Marshal(q)
		if _, err := decodeHostRotationRequest(raw); err == nil {
			t.Fatal("vault request accepted foreign authority or a credential identity")
		}
	}
	for _, value := range []string{"", "short", "contains a space in the password", strings.Repeat("x", 513)} {
		if validHostVaultPassword(value) {
			t.Fatal("invalid vault password accepted")
		}
	}
}

const (
	fakeVaultSecret = "FIXTURE_ONLY_VAULT_PASSWORD_123456"
	fakeOwner       = ":1.7"
	fakeLogin       = "/org/freedesktop/secrets/collection/login"
	fakeSession     = "/org/freedesktop/secrets/session/s1"
)

// fakeSecretBus is an in-process session bus with one Secret Service. It
// never touches the user's real bus.
type fakeSecretBus struct {
	authReply   string
	uid         uint32
	alias       string
	collections []string
	lockedAfter bool
	unlockError string
	replyHook   func(member string) []byte // replaces the reply when non-nil
	stall       string                     // a member that is never answered

	mu       sync.Mutex
	calls    []string
	password []byte
	unlocked string
	aliasSet string
	closed   bool
	wire     bytes.Buffer // every byte the client sent after authentication
}

func newFakeSecretBus() *fakeSecretBus {
	return &fakeSecretBus{authReply: "OK 0123456789abcdef0123456789abcdef\r\n", uid: uint32(os.Getuid()), alias: fakeLogin}
}

func (f *fakeSecretBus) install(t *testing.T) {
	directory, err := os.MkdirTemp("", "db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	socket := filepath.Join(directory, "bus")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(20 * time.Second))
		f.serve(t, conn)
	}()
	t.Cleanup(func() { _ = listener.Close(); <-done })
	saved := hostVaultDial
	hostVaultDial = func(ctx context.Context) (net.Conn, error) { return dbusDial(ctx, "unix:path="+socket+",guid=00") }
	t.Cleanup(func() { hostVaultDial = saved })
}

func (f *fakeSecretBus) serve(t *testing.T, conn net.Conn) {
	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	want := "\x00AUTH EXTERNAL " + hex.EncodeToString([]byte(strconv.Itoa(os.Getuid()))) + "\r\n"
	if err != nil || line != want {
		t.Errorf("auth line %q", line)
		return
	}
	_, _ = io.WriteString(conn, f.authReply)
	if !strings.HasPrefix(f.authReply, "OK ") {
		return
	}
	if line, err := reader.ReadString('\n'); err != nil || line != "BEGIN\r\n" {
		t.Errorf("begin line %q", line)
		return
	}
	for {
		call, raw, err := fakeReadCall(reader)
		if err != nil {
			return
		}
		f.mu.Lock()
		f.wire.Write(raw)
		f.calls = append(f.calls, call.member)
		f.mu.Unlock()
		if call.member == f.stall {
			continue
		}
		reply := f.answer(t, call)
		if f.replyHook != nil {
			if hooked := f.replyHook(call.member); hooked != nil {
				reply = hooked
			}
		}
		if _, err := conn.Write(reply); err != nil {
			return
		}
	}
}

type fakeCall struct {
	serial                                 uint32
	path, iface, member, destination, sign string
	body                                   []any
}

// fakeReadCall parses one method call with the package's generic decoder.
func fakeReadCall(reader io.Reader) (*fakeCall, []byte, error) {
	fixed := make([]byte, 16)
	if _, err := io.ReadFull(reader, fixed); err != nil {
		return nil, nil, err
	}
	if fixed[0] != 'l' || fixed[1] != dbusMethodCall || fixed[3] != 1 {
		return nil, nil, errors.New("not a little-endian method call")
	}
	fieldsLength := int(binary.LittleEndian.Uint32(fixed[12:]))
	headerLength := (16 + fieldsLength + 7) &^ 7
	data := make([]byte, headerLength+int(binary.LittleEndian.Uint32(fixed[4:])))
	copy(data, fixed)
	if _, err := io.ReadFull(reader, data[16:]); err != nil {
		return nil, nil, err
	}
	fields, err := (&dbusDecoder{data: data[:16+fieldsLength], pos: 12, order: binary.LittleEndian}).value("a(yv)")
	if err != nil {
		return nil, nil, err
	}
	call := &fakeCall{serial: binary.LittleEndian.Uint32(fixed[8:])}
	for _, item := range fields.([]any) {
		pair := item.([]any)
		value, _ := pair[1].(dbusVariant).value.(string)
		switch pair[0].(byte) {
		case dbusFieldPath:
			call.path = value
		case dbusFieldInterface:
			call.iface = value
		case dbusFieldMember:
			call.member = value
		case dbusFieldDestination:
			call.destination = value
		case dbusFieldSignature:
			call.sign = value
		}
	}
	decoder := &dbusDecoder{data: data[headerLength:], order: binary.LittleEndian}
	for signature := call.sign; signature != ""; {
		value, rest, err := decoder.next(signature, 0)
		if err != nil {
			return nil, nil, err
		}
		call.body = append(call.body, value)
		signature = rest
	}
	return call, data, nil
}

// fakeMessage is a reply or signal from the bus.
func fakeMessage(kind byte, replySerial uint32, errorName, signature string, body []byte) []byte {
	e := &dbusEncoder{}
	e.buf = append(e.buf, 'l', kind, 0, 1)
	e.uint32(uint32(len(body)))
	e.uint32(9000 + replySerial)
	e.uint32(0)
	e.align(8)
	start := len(e.buf)
	if kind == 4 {
		e.align(8)
		e.byte(dbusFieldPath)
		e.signature("o")
		e.string("/org/freedesktop/DBus")
		e.align(8)
		e.byte(dbusFieldMember)
		e.signature("s")
		e.string("NameAcquired")
	} else {
		e.align(8)
		e.byte(dbusFieldReplySerial)
		e.signature("u")
		e.uint32(replySerial)
	}
	if errorName != "" {
		e.align(8)
		e.byte(dbusFieldErrorName)
		e.signature("s")
		e.string(errorName)
	}
	if signature != "" {
		e.align(8)
		e.byte(dbusFieldSignature)
		e.signature("g")
		e.signature(signature)
	}
	binary.LittleEndian.PutUint32(e.buf[12:16], uint32(len(e.buf)-start))
	e.align(8)
	return append(e.buf, body...)
}

func fakeBody(build func(e *dbusEncoder)) []byte {
	e := &dbusEncoder{}
	build(e)
	return e.buf
}

func fakeObjectPaths(e *dbusEncoder, paths []string) {
	e.uint32(0)
	start := len(e.buf)
	for _, path := range paths {
		e.string(path)
	}
	binary.LittleEndian.PutUint32(e.buf[start-4:start], uint32(len(e.buf)-start))
}

func (f *fakeSecretBus) answer(t *testing.T, call *fakeCall) []byte {
	ok := func(signature string, body []byte) []byte {
		return fakeMessage(dbusMethodReturn, call.serial, "", signature, body)
	}
	fail := func(name string) []byte { return fakeMessage(dbusError, call.serial, name, "", nil) }
	if call.destination == "org.freedesktop.DBus" {
		switch call.member {
		case "Hello":
			return ok("s", fakeBody(func(e *dbusEncoder) { e.string(":1.42") }))
		case "GetNameOwner":
			if call.body[0] != secretsBus {
				t.Errorf("GetNameOwner(%v)", call.body)
			}
			// A signal and a reply to another serial come first.
			stray := append(fakeMessage(4, 0, "", "m", []byte{1, 2, 3, 4, 5, 6, 7, 8}),
				fakeMessage(dbusMethodReturn, call.serial+100, "", "", nil)...)
			return append(stray, ok("s", fakeBody(func(e *dbusEncoder) { e.string(fakeOwner) }))...)
		case "GetConnectionUnixUser":
			if call.body[0] != fakeOwner {
				t.Errorf("uid checked for %v", call.body)
			}
			return ok("u", fakeBody(func(e *dbusEncoder) { e.uint32(f.uid) }))
		}
		return fail("org.freedesktop.DBus.Error.UnknownMethod")
	}
	if call.destination != fakeOwner {
		t.Errorf("%s sent to %s, not the checked owner", call.member, call.destination)
		return fail("org.freedesktop.DBus.Error.AccessDenied")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	switch call.iface + "." + call.member {
	case "org.freedesktop.Secret.Service.ReadAlias":
		if call.sign != "s" || call.body[0] != "default" || call.path != secretsPath {
			t.Errorf("ReadAlias %+v", call)
		}
		return ok("o", fakeBody(func(e *dbusEncoder) { e.string(f.alias) }))
	case "org.freedesktop.DBus.Properties.Get":
		switch {
		case call.path == secretsPath && call.body[0] == secretService && call.body[1] == "Collections":
			return ok("v", fakeBody(func(e *dbusEncoder) { e.signature("ao"); fakeObjectPaths(e, f.collections) }))
		case call.path == f.unlocked && call.body[0] == "org.freedesktop.Secret.Collection" && call.body[1] == "Locked":
			locked := uint32(0)
			if f.lockedAfter {
				locked = 1
			}
			return ok("v", fakeBody(func(e *dbusEncoder) { e.signature("b"); e.uint32(locked) }))
		}
	case "org.freedesktop.Secret.Service.OpenSession":
		if call.sign != "sv" || call.body[0] != "plain" || call.body[1] != (dbusVariant{"s", ""}) {
			t.Errorf("OpenSession %+v", call.body)
		}
		return ok("vo", fakeBody(func(e *dbusEncoder) { e.signature("s"); e.string(""); e.string(fakeSession) }))
	case "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface.UnlockWithMasterPassword":
		master, _ := call.body[1].([]any)
		if call.sign != "o(oayays)" || len(master) != 4 || master[0] != fakeSession ||
			len(master[1].([]byte)) != 0 || master[3] != "text/plain" {
			t.Errorf("UnlockWithMasterPassword shape %s", call.sign)
			return fail("org.freedesktop.DBus.Error.InvalidArgs")
		}
		f.password = append([]byte(nil), master[2].([]byte)...)
		if f.unlockError != "" {
			return fail(f.unlockError)
		}
		f.unlocked = call.body[0].(string)
		return ok("", nil)
	case "org.freedesktop.Secret.Session.Close":
		f.closed = call.path == fakeSession
		return ok("", nil)
	case "org.freedesktop.Secret.Service.SetAlias":
		if call.body[0] == "default" {
			f.aliasSet, _ = call.body[1].(string)
		}
		return ok("", nil)
	}
	return fail("org.freedesktop.DBus.Error.UnknownMethod")
}

func (f *fakeSecretBus) unlock(t *testing.T) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	err := unlockSecretService(ctx, fakeVaultSecret)
	if err != nil && strings.Contains(err.Error(), fakeVaultSecret) {
		t.Fatal("error carries the password")
	}
	return err
}

func (f *fakeSecretBus) sentPassword() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return bytes.Contains(f.wire.Bytes(), []byte(fakeVaultSecret))
}

func TestHostVaultUnlockOverFakeSessionBus(t *testing.T) {
	bus := newFakeSecretBus()
	bus.install(t)
	if err := bus.unlock(t); err != nil {
		t.Fatal(err)
	}
	want := "Hello GetNameOwner GetConnectionUnixUser ReadAlias OpenSession UnlockWithMasterPassword Close Get SetAlias"
	if got := strings.Join(bus.calls, " "); got != want {
		t.Fatalf("calls %s", got)
	}
	if string(bus.password) != fakeVaultSecret || bus.unlocked != fakeLogin || !bus.closed || bus.aliasSet != fakeLogin {
		t.Fatalf("unlock %v collection %q closed %v alias %q", bus.password != nil, bus.unlocked, bus.closed, bus.aliasSet)
	}
}

func TestHostVaultUnlockFindsTheOnlyCollectionWithoutAnAlias(t *testing.T) {
	bus := newFakeSecretBus()
	bus.alias = "/"
	bus.collections = []string{"/org/freedesktop/secrets/collection/session", fakeLogin}
	bus.install(t)
	if err := bus.unlock(t); err != nil || bus.unlocked != fakeLogin || bus.aliasSet != fakeLogin {
		t.Fatalf("err %v unlocked %q alias %q", err, bus.unlocked, bus.aliasSet)
	}
}

// The password reaches the bus only after the owner and collection checks.
func TestHostVaultUnlockRefusalsNeverSendThePassword(t *testing.T) {
	for name, configure := range map[string]func(*fakeSecretBus){
		"foreign owner": func(f *fakeSecretBus) { f.uid++ },
		"two collections": func(f *fakeSecretBus) {
			f.alias = "/"
			f.collections = []string{fakeLogin, "/org/freedesktop/secrets/collection/b"}
		},
		"no collection": func(f *fakeSecretBus) { f.alias = "/"; f.collections = nil },
		"auth refused":  func(f *fakeSecretBus) { f.authReply = "REJECTED EXTERNAL\r\n" },
		"collections not ao": func(f *fakeSecretBus) {
			f.alias = "/"
			f.replyHook = replaceReply("Get", "v", func(e *dbusEncoder) { e.signature("s"); e.string(fakeLogin) })
		},
		"uid not uint32": func(f *fakeSecretBus) {
			f.replyHook = replaceReply("GetConnectionUnixUser", "s", func(e *dbusEncoder) { e.string("0") })
		},
		"oversized reply": func(f *fakeSecretBus) {
			f.replyHook = replaceReply("ReadAlias", "s", func(e *dbusEncoder) { e.string(strings.Repeat("x", dbusMessageLimit)) })
		},
		"truncated body": func(f *fakeSecretBus) { f.replyHook = truncatedReply("ReadAlias") },
		"session not a path": func(f *fakeSecretBus) {
			f.replyHook = replaceReply("OpenSession", "v", func(e *dbusEncoder) { e.signature("s"); e.string("") })
		},
		"owner lookup failed": func(f *fakeSecretBus) { f.replyHook = errorReply("GetNameOwner") },
	} {
		t.Run(name, func(t *testing.T) {
			bus := newFakeSecretBus()
			configure(bus)
			bus.install(t)
			if err := bus.unlock(t); err == nil {
				t.Fatal("unlock succeeded")
			}
			if bus.sentPassword() || bus.password != nil {
				t.Fatal("password sent before the checks passed")
			}
		})
	}
}

func TestHostVaultUnlockFailsClosedAfterTheUnlockCall(t *testing.T) {
	for name, configure := range map[string]func(*fakeSecretBus){
		"still locked":  func(f *fakeSecretBus) { f.lockedAfter = true },
		"unlock denied": func(f *fakeSecretBus) { f.unlockError = "org.freedesktop.DBus.Error.AccessDenied" },
		"locked not b": func(f *fakeSecretBus) {
			f.replyHook = replaceReplyAfter("Get", 0, "v", func(e *dbusEncoder) { e.signature("s"); e.string("false") })
		},
	} {
		t.Run(name, func(t *testing.T) {
			bus := newFakeSecretBus()
			configure(bus)
			bus.install(t)
			if err := bus.unlock(t); err == nil {
				t.Fatal("unlock reported success")
			}
			if bus.aliasSet != "" {
				t.Fatal("default alias moved without a confirmed unlock")
			}
		})
	}
}

// replaceReply answers the first call of member with signature and body.
func replaceReply(member, signature string, build func(*dbusEncoder)) func(string) []byte {
	return replaceReplyAfter(member, 0, signature, build)
}

// replaceReplyAfter replaces the reply to the call of member after skip
// earlier ones. Serials are counted from the client's sequence.
func replaceReplyAfter(member string, skip int, signature string, build func(*dbusEncoder)) func(string) []byte {
	serial := uint32(0)
	return func(got string) []byte {
		serial++
		if got != member {
			return nil
		}
		if skip > 0 {
			skip--
			return nil
		}
		return fakeMessage(dbusMethodReturn, serial, "", signature, fakeBody(build))
	}
}

func truncatedReply(member string) func(string) []byte {
	serial := uint32(0)
	return func(got string) []byte {
		serial++
		if got != member {
			return nil
		}
		message := fakeMessage(dbusMethodReturn, serial, "", "s", fakeBody(func(e *dbusEncoder) { e.string("/abc") }))
		binary.LittleEndian.PutUint32(message[len(message)-9:], 1000) // string length past the body
		return message
	}
}

func errorReply(member string) func(string) []byte {
	serial := uint32(0)
	return func(got string) []byte {
		serial++
		if got != member {
			return nil
		}
		return fakeMessage(dbusError, serial, "org.freedesktop.DBus.Error.NameHasNoOwner", "", nil)
	}
}

// The Hello call's bytes, assembled by hand from the D-Bus specification.
func TestDBusMethodCallWireFormat(t *testing.T) {
	var want []byte
	pad := func(n int) {
		for len(want)%n != 0 {
			want = append(want, 0)
		}
	}
	str := func(s string) {
		want = append(want, byte(len(s)), 0, 0, 0)
		want = append(append(want, s...), 0)
	}
	want = append(want, 'l', 1, 0, 1, 0, 0, 0, 0, 7, 0, 0, 0, 109, 0, 0, 0)
	want = append(want, 1, 1, 'o', 0)
	str("/org/freedesktop/DBus")
	pad(8)
	want = append(want, 2, 1, 's', 0)
	str("org.freedesktop.DBus")
	pad(8)
	want = append(want, 3, 1, 's', 0)
	str("Hello")
	pad(8)
	want = append(want, 6, 1, 's', 0)
	str("org.freedesktop.DBus")
	pad(8)
	if got := dbusMarshalCall(7, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", nil); !bytes.Equal(got, want) {
		t.Fatalf("Hello\n got %x\nwant %x", got, want)
	}
	// A body follows the 8-aligned header; SIGNATURE is a g-typed field.
	got := dbusMarshalCall(1, "d", "/", "", "M", "s", []byte{1, 0, 0, 0, 'x', 0})
	if !bytes.HasSuffix(got, []byte{8, 1, 'g', 0, 1, 's', 0, 0, 1, 0, 0, 0, 'x', 0}) || got[4] != 6 {
		t.Fatalf("call with body %x", got)
	}
}

func TestDBusDecoderRejectsMalformedMessages(t *testing.T) {
	ok := fakeMessage(dbusMethodReturn, 1, "", "ao", fakeBody(func(e *dbusEncoder) { fakeObjectPaths(e, []string{"/a", "/b"}) }))
	decode := func(data []byte) ([]any, error) {
		message, err := dbusReadMessage(bytes.NewReader(data))
		if err != nil {
			return nil, err
		}
		if message.replySerial != 1 {
			return nil, errors.New("reply serial lost")
		}
		return message.decodeBody()
	}
	if body, err := decode(ok); err != nil || len(body) != 1 || len(body[0].([]any)) != 2 {
		t.Fatalf("valid reply: %v %v", err, body)
	}
	for name, mutate := range map[string]func([]byte) []byte{
		"byte order": func(m []byte) []byte { m[0] = 'x'; return m },
		"version":    func(m []byte) []byte { m[3] = 2; return m },
		"short":      func(m []byte) []byte { return m[:len(m)-1] },
		"trailing bytes": func(m []byte) []byte {
			binary.LittleEndian.PutUint32(m[4:], binary.LittleEndian.Uint32(m[4:])+4)
			return append(m, 0, 0, 0, 0)
		},
		"array overrun": func(m []byte) []byte { binary.LittleEndian.PutUint32(m[len(m)-19:], 64); return m },
		"oversized":     func(m []byte) []byte { binary.LittleEndian.PutUint32(m[4:], dbusMessageLimit); return m },
	} {
		if _, err := decode(mutate(append([]byte(nil), ok...))); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	nested := strings.Repeat("(", dbusDepthLimit+2) + "y" + strings.Repeat(")", dbusDepthLimit+2)
	if _, err := (&dbusDecoder{data: make([]byte, 64), order: binary.LittleEndian}).value(nested); err == nil {
		t.Error("unbounded nesting accepted")
	}
}

func TestHostVaultUnlockRefusesBeforeDialingOffLinuxOrWithAnInvalidPassword(t *testing.T) {
	saved := hostVaultDial
	hostVaultDial = func(context.Context) (net.Conn, error) { t.Fatal("dialed the bus"); return nil, nil }
	t.Cleanup(func() { hostVaultDial = saved })
	if _, err := hostVaultUnlock(context.Background(), "short"); err == nil {
		t.Fatal("invalid password accepted")
	}
	if runtime.GOOS != "linux" {
		if _, err := hostVaultUnlock(context.Background(), fakeVaultSecret); err == nil {
			t.Fatal("vault unlock ran off Linux")
		}
	}
}

func TestHostVaultUnlockReceiptOnLinux(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("the vault is a Linux Secret Service")
	}
	bus := newFakeSecretBus()
	bus.install(t)
	receipt, err := hostVaultUnlock(context.Background(), fakeVaultSecret)
	if err != nil || string(receipt) != `{"v":1,"status":"unlocked","storage":"linux_secret_service"}` {
		t.Fatalf("receipt %s %v", receipt, err)
	}
	bus2 := newFakeSecretBus()
	bus2.lockedAfter = true
	bus2.install(t)
	if _, err := hostVaultUnlock(context.Background(), fakeVaultSecret); err == nil ||
		err.Error() != "host vault is locked or unavailable" {
		t.Fatalf("locked vault: %v", err)
	}
}

// decodeWithin decodes body by signature and fails the test if decoding does
// not finish promptly, so a non-terminating decoder fails instead of hanging.
func decodeWithin(t *testing.T, signature string, body []byte) error {
	t.Helper()
	done := make(chan error, 1)
	go func() {
		_, err := (&dbusMessage{signature: signature, body: body, order: binary.LittleEndian}).decodeBody()
		done <- err
	}()
	select {
	case err := <-done:
		return err
	case <-time.After(2 * time.Second):
		t.Fatalf("decoding %s did not terminate", signature)
		return nil
	}
}

func TestDBusDecoderRequiresProgressAndBoundedArrays(t *testing.T) {
	// Root's case: an a() body of length 1 whose element is an empty struct.
	if err := decodeWithin(t, "a()", []byte{1, 0, 0, 0, 0, 0, 0, 0, 0}); err == nil {
		t.Error("empty struct element accepted")
	}
	booleans := func(n int) []byte {
		body := binary.LittleEndian.AppendUint32(nil, uint32(4*n))
		return append(body, make([]byte, 4*n)...)
	}
	if err := decodeWithin(t, "ab", booleans(dbusArrayLimit)); err != nil {
		t.Errorf("array at the element limit refused: %v", err)
	}
	for name, c := range map[string]struct {
		signature string
		body      []byte
	}{
		"empty struct":         {"()", nil},
		"empty dict entry":     {"a{}", []byte{1, 0, 0, 0, 0, 0, 0, 0, 0}},
		"one-member dict":      {"a{y}", []byte{1, 0, 0, 0, 0, 0, 0, 0, 7}},
		"dict outside array":   {"{yy}", []byte{1, 2}},
		"too many elements":    {"ab", booleans(dbusArrayLimit + 1)},
		"element past the end": {"at", append([]byte{4, 0, 0, 0, 0, 0, 0, 0}, make([]byte, 8)...)},
		"string past the end":  {"as", append([]byte{5, 0, 0, 0}, 9, 0, 0, 0, 'a', 'b', 'c', 'd', 0)},
		"variant of nothing":   {"v", []byte{0, 0}},
		"unterminated struct":  {"(y", []byte{1}},
	} {
		if err := decodeWithin(t, c.signature, c.body); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

// Root's wire case: the ReadAlias reply is the 9-byte a() body.
func TestHostVaultUnlockRefusesANonProgressingReplyPromptly(t *testing.T) {
	bus := newFakeSecretBus()
	bus.replyHook = replaceReply("ReadAlias", "a()", func(e *dbusEncoder) { e.uint32(1); e.align(8); e.byte(0) })
	bus.install(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- unlockSecretService(ctx, fakeVaultSecret) }()
	select {
	case err := <-done:
		if err == nil || bus.sentPassword() {
			t.Fatalf("malformed reply accepted (%v) or password sent", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("unlock did not stop on a malformed reply")
	}
}

// A bus that never answers holds the unlock only until the context ends:
// a deadline through the connection deadline, a cancellation by closing it.
func TestHostVaultUnlockStopsWhenTheContextEnds(t *testing.T) {
	for _, deadline := range []bool{true, false} {
		bus := newFakeSecretBus()
		bus.stall = "ReadAlias"
		bus.install(t)
		ctx, cancel := context.WithCancel(context.Background())
		if deadline {
			ctx, cancel = context.WithTimeout(context.Background(), 40*time.Millisecond)
		} else {
			time.AfterFunc(40*time.Millisecond, cancel)
		}
		started := time.Now()
		done := make(chan error, 1)
		go func() { done <- unlockSecretService(ctx, fakeVaultSecret) }()
		select {
		case err := <-done:
			if err == nil || bus.sentPassword() {
				t.Fatalf("deadline %v: stalled unlock succeeded (%v) or sent the password", deadline, err)
			}
			if elapsed := time.Since(started); elapsed > 140*time.Millisecond {
				t.Errorf("deadline %v: unlock returned %v after start, more than 100ms after the context ended", deadline, elapsed)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("deadline %v: unlock ignored the ended context", deadline)
		}
		cancel()
	}
}

func FuzzDBusDecodeBody(f *testing.F) {
	f.Add("a()", []byte{1, 0, 0, 0, 0, 0, 0, 0, 0})
	f.Add("a(yv)", []byte{8, 0, 0, 0, 0, 0, 0, 0, 5, 1, 'u', 0, 7, 0, 0, 0})
	f.Add("ao", []byte{7, 0, 0, 0, 2, 0, 0, 0, '/', 'a', 0})
	f.Add("v", []byte{2, 'a', 'b', 0, 1, 0, 0, 0, 1, 0, 0, 0})
	f.Add("a{sv}", []byte{0, 0, 0, 0, 0, 0, 0, 0})
	f.Add("vo", []byte{1, 's', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, '/', 0})
	f.Fuzz(func(t *testing.T, signature string, body []byte) {
		if len(signature) > 255 || len(body) > dbusMessageLimit {
			return
		}
		start := time.Now()
		values, err := (&dbusMessage{signature: signature, body: body, order: binary.LittleEndian}).decodeBody()
		if time.Since(start) > time.Second {
			t.Fatalf("decoding took %v", time.Since(start))
		}
		if err == nil && signature != "" && len(values) == 0 {
			t.Fatal("a non-empty signature decoded to no values")
		}
	})
}

func FuzzDBusReadMessage(f *testing.F) {
	f.Add(fakeMessage(dbusMethodReturn, 1, "", "a()", []byte{1, 0, 0, 0, 0, 0, 0, 0, 0}))
	f.Add(fakeMessage(dbusMethodReturn, 1, "", "s", []byte{1, 0, 0, 0, 'x', 0}))
	f.Add(fakeMessage(dbusError, 3, "org.example.Error", "", nil))
	f.Fuzz(func(t *testing.T, data []byte) {
		message, err := dbusReadMessage(bytes.NewReader(data))
		if err == nil {
			_, _ = message.decodeBody()
		}
	})
}

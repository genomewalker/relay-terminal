package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"runtime"
	"strings"
	"time"
)

// This host-account operation accepts an authorized vault password over the
// authenticated node channel. It is never a workspace job or a credential read.
// The password goes only to the user's own Secret Service over a private
// connection to the user's authenticated D-Bus session; it never appears in a
// process argument, environment, file or error.

const (
	secretsBus         = "org.freedesktop.secrets"
	secretsPath        = "/org/freedesktop/secrets"
	secretService      = "org.freedesktop.Secret.Service"
	dbusProperties     = "org.freedesktop.DBus.Properties"
	vaultUnlockTimeout = 5 * time.Second
)

func validHostVaultPassword(secret string) bool {
	if len(secret) < 16 || len(secret) > 512 {
		return false
	}
	for _, c := range []byte(secret) {
		if c <= 32 || c >= 127 {
			return false
		}
	}
	return true
}

// hostVaultDial is replaced by tests with an in-process fake bus.
var hostVaultDial = func(ctx context.Context) (net.Conn, error) {
	return dbusDial(ctx, dbusSessionAddress())
}

func hostVaultUnlock(ctx context.Context, secret string) (json.RawMessage, error) {
	if runtime.GOOS != "linux" || !validHostVaultPassword(secret) {
		return nil, errors.New("vault unlock is unavailable on this host")
	}
	if err := unlockSecretService(ctx, secret); err != nil {
		return nil, errors.New("host vault is locked or unavailable")
	}
	return json.Marshal(struct {
		Version int    `json:"v"`
		Status  string `json:"status"`
		Storage string `json:"storage"`
	}{1, "unlocked", "linux_secret_service"})
}

// unlockSecretService unlocks the default collection with gnome-keyring's
// master-password interface, only when the service is owned by this user,
// and succeeds only when the collection then reports itself unlocked.
func unlockSecretService(ctx context.Context, secret string) error {
	conn, err := hostVaultDial(ctx)
	if err != nil {
		return err
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	defer conn.Close()
	bus, err := dbusConnect(ctx, conn)
	if err != nil {
		return err
	}
	call := func(destination, path, iface, member, signature string, body []byte, timeout time.Duration) ([]any, error) {
		return bus.call(ctx, destination, path, iface, member, signature, body, timeout)
	}
	text := func(values ...string) []byte {
		e := &dbusEncoder{}
		for _, value := range values {
			e.string(value)
		}
		return e.buf
	}
	// Every later call goes to the unique connection whose owner was checked.
	reply, err := call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", text(secretsBus), dbusCallTimeout)
	if err != nil {
		return err
	}
	owner, ok := dbusSingle[string](reply)
	if !ok {
		return errors.New("secret service owner unavailable")
	}
	reply, err = call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixUser", "s", text(owner), dbusCallTimeout)
	if err != nil {
		return err
	}
	if uid, ok := dbusSingle[uint32](reply); !ok || int64(uid) != int64(os.Getuid()) {
		return errors.New("secret service belongs to another user")
	}
	reply, err = call(owner, secretsPath, secretService, "ReadAlias", "s", text("default"), dbusCallTimeout)
	if err != nil {
		return err
	}
	collection, ok := dbusSingle[string](reply)
	if !ok {
		return errors.New("default collection unavailable")
	}
	if collection == "/" {
		reply, err = call(owner, secretsPath, dbusProperties, "Get", "ss", text(secretService, "Collections"), dbusCallTimeout)
		if err != nil {
			return err
		}
		variant, ok := dbusSingle[dbusVariant](reply)
		paths, isArray := variant.value.([]any)
		if !ok || variant.signature != "ao" || !isArray {
			return errors.New("collections unavailable")
		}
		var candidates []string
		for _, path := range paths {
			if !strings.HasSuffix(path.(string), "/session") {
				candidates = append(candidates, path.(string))
			}
		}
		if len(candidates) != 1 {
			return errors.New("no single collection to unlock")
		}
		collection = candidates[0]
	}
	open := &dbusEncoder{}
	open.string("plain")
	open.signature("s")
	open.string("")
	reply, err = call(owner, secretsPath, secretService, "OpenSession", "sv", open.buf, dbusCallTimeout)
	if err != nil {
		return err
	}
	if len(reply) != 2 {
		return errors.New("secret session unavailable")
	}
	session, ok := reply[1].(string)
	if !ok {
		return errors.New("secret session unavailable")
	}
	// UnlockWithMasterPassword(o collection, (oayays) master): a plain
	// secret with empty parameters, the password bytes and its content type.
	unlock := &dbusEncoder{}
	unlock.string(collection)
	unlock.align(8)
	unlock.string(session)
	unlock.bytes(nil)
	unlock.bytes([]byte(secret))
	unlock.string("text/plain")
	_, err = call(owner, secretsPath, "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface", "UnlockWithMasterPassword",
		"o(oayays)", unlock.buf, vaultUnlockTimeout)
	clear(unlock.buf)
	if err != nil {
		return err
	}
	if _, err := call(owner, session, "org.freedesktop.Secret.Session", "Close", "", nil, dbusCallTimeout); err != nil {
		return err
	}
	reply, err = call(owner, collection, dbusProperties, "Get", "ss", text("org.freedesktop.Secret.Collection", "Locked"), dbusCallTimeout)
	if err != nil {
		return err
	}
	locked, ok := dbusSingle[dbusVariant](reply)
	if !ok || locked.value != false {
		return errors.New("collection is still locked")
	}
	alias := &dbusEncoder{}
	alias.string("default")
	alias.string(collection)
	_, err = call(owner, secretsPath, secretService, "SetAlias", "so", alias.buf, dbusCallTimeout)
	return err
}

// dbusSingle is a reply body of exactly one value of type T.
func dbusSingle[T any](body []any) (T, bool) {
	var zero T
	if len(body) != 1 {
		return zero, false
	}
	value, ok := body[0].(T)
	return value, ok
}

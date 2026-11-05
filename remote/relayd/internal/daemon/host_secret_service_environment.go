package daemon

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// Noninteractive host connections need not inherit the user's bus address.
// Discover only an owned socket inside a private owned runtime directory.
func hostVerifiedUserBus(directory string) string {
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return ""
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() {
		return ""
	}
	path := filepath.Join(directory, "bus")
	info, err = os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return ""
	}
	owner, ok = info.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() {
		return ""
	}
	return "unix:path=" + path
}

func hostSecretServiceEnvironment() []string {
	values := map[string]string{}
	for _, key := range []string{"HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR"} {
		if value, ok := os.LookupEnv(key); ok {
			values[key] = value
		}
	}
	if values["DBUS_SESSION_BUS_ADDRESS"] == "" {
		for _, directory := range []string{values["XDG_RUNTIME_DIR"], fmt.Sprintf("/run/user/%d", os.Getuid())} {
			if directory != "" {
				if address := hostVerifiedUserBus(directory); address != "" {
					values["DBUS_SESSION_BUS_ADDRESS"] = address
					break
				}
			}
		}
	}
	result := make([]string, 0, len(values))
	for key, value := range values {
		result = append(result, key+"="+value)
	}
	return result
}

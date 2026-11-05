package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

func (spec *peerListenerSpec) legacyPython() bool {
	return spec != nil && spec.Executable == "" && strings.HasPrefix(strings.ToLower(filepath.Base(spec.Interpreter)), "python")
}

// The home-relative native token is resolved on the authenticated execution
// host. Neither a focused project directory nor a request-supplied Cwd or Env
// can redirect the Relay helper to a project-local executable.
func resolveNativeHostArgv(argv []string) ([]string, error) {
	if len(argv) == 0 {
		return nil, errors.New("missing executable")
	}
	result := append([]string(nil), argv...)
	if result[0] == ".local/bin/relayd" {
		home, err := os.UserHomeDir()
		if err != nil || !filepath.IsAbs(home) {
			return nil, errors.New("native host home is unavailable")
		}
		result[0] = filepath.Join(home, ".local/bin/relayd")
	}
	return result, nil
}

// The exact shipped predecessor is allowed to migrate only after its clean
// drain. The registry keeps the route/owner binding and records a new job and
// successor; arbitrary retained interpreter text is never executed.
func nativePeerListenerSuccessor(previous *peerListenerSpec) (*peerListenerSpec, error) {
	if previous == nil {
		return nil, errors.New("missing peer listener")
	}
	hash := sha256.Sum256([]byte(previous.Script))
	return nativePeerListenerSuccessorDigest(previous, hex.EncodeToString(hash[:]))
}

// The digest is supplied by the SHA256 computation above. Separating this
// bounded policy decision lets tests enumerate every identity/format state
// without retaining an executable copy of the removed interpreter source.
func nativePeerListenerSuccessorDigest(previous *peerListenerSpec, digest string) (*peerListenerSpec, error) {
	if previous == nil {
		return nil, errors.New("missing peer listener")
	}
	if err := previous.validate(); err != nil {
		return nil, err
	}
	if !previous.legacyPython() {
		copy := *previous
		return &copy, nil
	}
	if digest != "a9cd94eeb34dad40a5b9a65feb1e1e4d59a765e079afd26e5cdd22573bb24918" {
		return nil, errors.New("unrecognized legacy peer listener remains suspended")
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	result := *previous
	result.Executable, result.Interpreter, result.Script = executable, "", ""
	return &result, result.validate()
}

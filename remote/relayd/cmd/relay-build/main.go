// relay-build contains the offline release helpers. It never starts Relay or
// reads provider credentials, and is not shipped as part of the runtime.
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/relay-terminal/relayd/internal/helperbundle"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

func provenance(data []byte) (string, error) {
	if len(data) > 1<<20 {
		return "", errors.New("provenance exceeds limit")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return "", err
	}
	// The original provenance reader selects this exact JSON key. Decoding
	// into a Go struct would also accept case-folded spellings of the field.
	var library string
	if err := json.Unmarshal(fields["library_sha256"], &library); err != nil {
		return "", err
	}
	b, err := hex.DecodeString(library)
	if err != nil || len(b) != sha256.Size || strings.ToLower(library) != library {
		return "", errors.New("build-provenance.json names no valid library_sha256")
	}
	return library, nil
}

// quote preserves the existing release-manifest byte format: ASCII JSON,
// lowercase escapes, surrogate pairs, and no HTML escaping.
func quote(s string) (string, error) {
	if !utf8.ValidString(s) {
		return "", errors.New("invalid UTF-8")
	}
	var out strings.Builder
	out.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"', '\\':
			out.WriteByte('\\')
			out.WriteRune(r)
		case '\b':
			out.WriteString(`\b`)
		case '\f':
			out.WriteString(`\f`)
		case '\n':
			out.WriteString(`\n`)
		case '\r':
			out.WriteString(`\r`)
		case '\t':
			out.WriteString(`\t`)
		default:
			if r < 0x20 || r >= 0x7f {
				if r > 0xffff {
					hi, lo := utf16.EncodeRune(r)
					fmt.Fprintf(&out, `\u%04x\u%04x`, hi, lo)
				} else {
					fmt.Fprintf(&out, `\u%04x`, r)
				}
			} else {
				out.WriteRune(r)
			}
		}
	}
	out.WriteByte('"')
	return out.String(), nil
}

func manifest(app string, fields []string, digest string, hasDigest bool) error {
	if len(fields) != 3 {
		return errors.New("manifest requires app, daemon and build versions")
	}
	q := make([]string, 3)
	for i, s := range fields {
		var err error
		q[i], err = quote(s)
		if err != nil {
			return err
		}
	}
	d := "null"
	if hasDigest {
		var err error
		d, err = quote(digest)
		if err != nil {
			return err
		}
	}
	root := filepath.Join(app, "Contents", "Resources")
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	var payloads []string
	for _, entry := range entries {
		if !strings.Contains(entry.Name(), "-linux-") {
			continue
		}
		path := filepath.Join(root, entry.Name())
		info, e := os.Stat(path)
		if e != nil {
			return e
		}
		if !info.Mode().IsRegular() {
			continue
		}
		name, e := quote("Resources/" + entry.Name())
		if e != nil {
			return e
		}
		file, e := os.Open(path)
		if e != nil {
			return e
		}
		h := sha256.New()
		_, e = io.Copy(h, file)
		closeErr := file.Close()
		if e != nil {
			return e
		}
		if closeErr != nil {
			return closeErr
		}
		payloads = append(payloads, fmt.Sprintf("    %s: \"%x\"", name, h.Sum(nil)))
	}
	hashes := "{}"
	if len(payloads) > 0 {
		hashes = "{\n" + strings.Join(payloads, ",\n") + "\n  }"
	}
	data := fmt.Sprintf("{\n  \"app_version\": %s,\n  \"daemon_version\": %s,\n  \"build_number\": %s,\n  \"source_digest\": %s,\n  \"sha256\": %s\n}\n", q[0], q[1], q[2], d, hashes)
	return os.WriteFile(filepath.Join(root, "relay-release.json"), []byte(data), 0644)
}

func running(target string, input io.Reader) (bool, error) {
	resolved, err := filepath.EvalSymlinks(target)
	if err != nil {
		return false, err
	}
	resolved, err = filepath.Abs(resolved)
	if err != nil {
		return false, err
	}
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	for scanner.Scan() {
		path := strings.TrimSpace(scanner.Text())
		if p, e := filepath.EvalSymlinks(path); e == nil {
			path = p
		}
		if path == resolved {
			return true, nil
		}
	}
	return false, scanner.Err()
}

var rotationReferences = map[string]string{
	"Sources/Relay/Resources/Rotation/miko_tool_catalog.json":                        "279962916cb2d1f7e29fd129cf8704f7a8dc1022b63ec81696ba33d41a19975f",
	"remote/relayd/internal/daemon/testdata/host_rotation_policy/golden.json":        "4d61896b546f9d82fa3d8cc5ca32054560c6d6e7454d29f1b01b381a4d21d7b2",
	"remote/relayd/internal/daemon/testdata/host_pane_health_controller/golden.json": "137a51a9ae015fb7f5e7d54a19dfa711d9b7d99dddb7c30242dc1328401c0ec8",
}

func noInterpreterAssets(root string) error {
	return filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		name := strings.ToLower(entry.Name())
		if name == "__pycache__" || strings.HasSuffix(name, ".py") || strings.HasSuffix(name, ".pyc") || strings.HasSuffix(name, ".pyo") {
			return fmt.Errorf("legacy interpreter asset: %s", path)
		}
		return nil
	})
}

func rotationResources(root string) error {
	for path, expected := range rotationReferences {
		file, err := os.Open(filepath.Join(root, path))
		if err != nil {
			return err
		}
		h := sha256.New()
		_, err = io.Copy(h, file)
		closeErr := file.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
		if fmt.Sprintf("%x", h.Sum(nil)) != expected {
			return fmt.Errorf("native reference drift: %s", path)
		}
	}
	if err := noInterpreterAssets(filepath.Join(root, "Sources", "Relay", "Resources")); err != nil {
		return err
	}
	legacy := filepath.Join(root, "remote", "relayd", "internal", "daemon", "communication_runtime")
	if _, err := os.Stat(legacy); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	return noInterpreterAssets(legacy)
}

func descriptorToken(data []byte) (string, error) {
	if len(data) > 1<<20 {
		return "", errors.New("httpgd descriptor exceeds limit")
	}
	var v struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		return "", errors.New("invalid httpgd descriptor")
	}
	if v.Token == "" || len(v.Token) > 4096 {
		return "", errors.New("httpgd descriptor has no valid token")
	}
	return v.Token, nil
}

func containsToken(input io.Reader, token string) (bool, error) {
	if token == "" {
		return false, errors.New("empty token")
	}
	buffer := make([]byte, 64<<10)
	var pending []byte
	for {
		n, err := input.Read(buffer)
		pending = append(pending, buffer[:n]...)
		if bytes.Contains(pending, []byte(token)) {
			return true, nil
		}
		keep := len(token) - 1
		if len(pending) > keep {
			pending = append([]byte{}, pending[len(pending)-keep:]...)
		}
		if err == io.EOF {
			return false, nil
		}
		if err != nil {
			return false, err
		}
	}
}

func run(args []string, in io.Reader) error {
	if len(args) < 1 {
		return errors.New("expected provenance, manifest or running")
	}
	switch args[0] {
	case "check-httpgd-log":
		if len(args) != 3 {
			return errors.New("check-httpgd-log requires descriptor and log")
		}
		file, err := os.Open(args[1])
		if err != nil {
			return err
		}
		data, err := io.ReadAll(io.LimitReader(file, (1<<20)+1))
		file.Close()
		if err != nil {
			return err
		}
		token, err := descriptorToken(data)
		if err != nil {
			return err
		}
		log, err := os.Open(args[2])
		if err != nil {
			return err
		}
		defer log.Close()
		leaked, err := containsToken(log, token)
		if err != nil {
			return err
		}
		if leaked {
			return errors.New("token leaked into console output")
		}
		return nil
	case "rotation-check":
		if len(args) != 2 {
			return errors.New("rotation-check requires a source root")
		}
		return rotationResources(args[1])
	case "helper-names":
		if len(args) != 1 {
			return errors.New("helper-names takes no arguments")
		}
		for _, name := range helperbundle.Names {
			fmt.Println(name)
		}
		return nil
	case "assets-check":
		if len(args) != 2 {
			return errors.New("assets-check requires a resource directory")
		}
		return noInterpreterAssets(args[1])
	case "provenance":
		if len(args) != 2 {
			return errors.New("provenance requires a path")
		}
		file, err := os.Open(args[1])
		if err != nil {
			return err
		}
		defer file.Close()
		data, err := io.ReadAll(io.LimitReader(file, (1<<20)+1))
		if err != nil {
			return err
		}
		value, err := provenance(data)
		if err != nil {
			return err
		}
		fmt.Print(value)
		return nil
	case "manifest":
		if len(args) != 5 {
			return errors.New("manifest requires app, daemon and build versions")
		}
		d, ok := os.LookupEnv("RELAY_SOURCE_DIGEST")
		return manifest(args[1], args[2:], d, ok)
	case "running":
		if len(args) != 2 {
			return errors.New("running requires an executable")
		}
		found, err := running(args[1], in)
		if err != nil {
			return err
		}
		if !found {
			return errors.New("executable is not running")
		}
		return nil
	default:
		return errors.New("unknown build operation")
	}
}

func main() {
	if err := run(os.Args[1:], os.Stdin); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

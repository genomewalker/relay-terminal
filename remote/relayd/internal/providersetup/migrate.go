package providersetup

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const legacyQuotaPath = ".local/share/relay/subscription-quotas/subscription_quota.py"

func shellLiteral(v string) string { return "'" + strings.ReplaceAll(v, "'", "'\"'\"'") + "'" }

func nativeQuotaPrefix(home string) string {
	return shellLiteral(filepath.Join(home, ".local/bin/relayd")) + " subscription-quota-statusline "
}

func quotaRendererBytes(encoded string) ([]byte, error) {
	decoded, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || len(decoded) == 0 || !utf8.Valid(decoded) || strings.ContainsRune(string(decoded), 0) || base64.StdEncoding.EncodeToString(decoded) != encoded {
		return nil, errors.New("invalid renderer encoding")
	}
	return decoded, nil
}

// Recognition is bound to the same home as the destination store. This is a
// literal command format, not a general shell parser or executable lookup.
func nativeQuotaEncoded(command, home string) (string, error) {
	if home == "" || !strings.HasPrefix(command, nativeQuotaPrefix(home)) {
		return "", errors.New("unrecognized native status line")
	}
	tail := strings.TrimPrefix(command, nativeQuotaPrefix(home))
	if len(tail) < 2 || tail[0] != '\'' || tail[len(tail)-1] != '\'' {
		return "", errors.New("unrecognized native status line")
	}
	encoded := tail[1 : len(tail)-1]
	if _, err := quotaRendererBytes(encoded); err != nil {
		return "", err
	}
	return encoded, nil
}

// MigrateQuotaSettings recognizes only the managed four-token legacy command,
// or its exact native successor. It never evaluates or rewrites the renderer.
func MigrateQuotaSettings(raw []byte, home string) ([]byte, error) {
	if !filepath.IsAbs(home) || filepath.Clean(home) != home || strings.ContainsAny(home, "\x00\r\n") {
		return nil, errors.New("invalid managed home")
	}
	data, err := object(raw)
	if err != nil {
		return nil, err
	}
	status, ok := data["statusLine"].(map[string]any)
	if !ok || status["type"] != "command" {
		return nil, errors.New("existing command status line required")
	}
	command, ok := status["command"].(string)
	if !ok {
		return nil, errors.New("status command must be text")
	}
	legacy := "python3 " + filepath.Join(home, legacyQuotaPath) + " --statusline "
	native := nativeQuotaPrefix(home)
	var encoded string
	switch {
	case strings.HasPrefix(command, legacy):
		// The old installer emitted an unquoted path: accept only literal-safe
		// path bytes, so shell syntax cannot be mistaken for a managed command.
		for _, c := range home {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("/._-", c)) {
				return nil, errors.New("unrecognized legacy path quoting")
			}
		}
		// Older managed installers leave horizontal whitespace after the last
		// shell word. It is not part of the renderer argument. Newlines remain
		// rejected, as do extra words or shell operators.
		encoded = strings.TrimRight(strings.TrimPrefix(command, legacy), " \t")
	case strings.HasPrefix(command, native):
		encoded, err = nativeQuotaEncoded(command, home)
		if err != nil {
			return nil, err
		}
	default:
		return nil, errors.New("unrecognized managed quota status line")
	}
	if _, err := quotaRendererBytes(encoded); err != nil {
		return nil, err
	}
	updated := native + shellLiteral(encoded)
	if command == updated {
		return append([]byte(nil), raw...), nil
	}
	status["command"] = updated
	out, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return nil, err
	}
	if len(out)+1 > FileLimit {
		return nil, errors.New("migrated settings exceed bound")
	}
	return append(out, '\n'), nil
}

func digestArgument(v string) bool {
	b, err := hex.DecodeString(v)
	return err == nil && len(b) == 32 && strings.ToLower(v) == v
}

// MigrateQuotaStatusline changes only settings. The reviewed hashes bind both
// its preimage and the managed legacy source; replace retains a private backup
// and checks the settings snapshot again immediately before committing.
func (s *Store) MigrateQuotaStatusline(home, settingsSHA, legacySHA string) error {
	if !digestArgument(settingsSHA) || !digestArgument(legacySHA) {
		return errors.New("two reviewed sha256 values required")
	}
	return s.locked(func() error {
		old, err := s.read(settingsPath)
		if err != nil {
			return err
		}
		if old == nil || hash(old.raw) != settingsSHA {
			return errors.New("settings preimage changed")
		}
		updated, err := MigrateQuotaSettings(old.raw, home)
		if err != nil {
			return err
		}
		if string(updated) == string(old.raw) {
			return nil
		}
		legacy, err := s.read(legacyQuotaPath)
		if err != nil {
			return err
		}
		if legacy == nil || hash(legacy.raw) != legacySHA {
			return errors.New("legacy source preimage changed")
		}
		return s.replace(settingsPath, updated, old, 0600, "")
	})
}

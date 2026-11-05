package rotationtext

import (
	"errors"
	"strconv"
	"strings"
	"testing"
)

const canonicalReplyLimit = 1 << 20

func canonicalCLIDigest(raw []byte) (string, error) {
	if len(raw) > canonicalReplyLimit {
		return "", errors.New("fixture response too large")
	}
	matches := referenceDigestPattern.FindAllString(string(raw), -1)
	if len(matches) != 1 {
		return "", errors.New("canonical fake CLI fingerprint missing")
	}
	return matches[0], nil
}
func legacySQLResult(raw []byte, failed bool) (string, error) {
	if len(raw) > 1024 {
		return "", errors.New("legacy SQLite response too large")
	}
	if failed {
		if strings.Contains(string(raw), "database is locked") {
			return "error database is locked", nil
		}
		return "", errors.New("legacy SQLite command failed")
	}
	value := strings.TrimPrefix(strings.TrimSpace(string(raw)), "delete\n")
	if value == "committed" {
		return value, nil
	}
	if count, ok := strings.CutPrefix(value, "read "); ok {
		if _, err := strconv.ParseUint(count, 10, 64); err == nil && count != "" && count[0] != '+' {
			return value, nil
		}
	}
	return "", errors.New("unexpected legacy SQLite response")
}
func TestCanonicalFixtureReplyRejections(t *testing.T) {
	digest := "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"
	for _, raw := range []string{"", "no fingerprint", digest + " " + digest, strings.Repeat("x", canonicalReplyLimit) + digest} {
		if _, err := canonicalCLIDigest([]byte(raw)); err == nil {
			t.Fatal("invalid fake CLI fingerprint accepted")
		}
	}
	if got, err := canonicalCLIDigest([]byte(`{"summary":"` + digest + `"}`)); err != nil || got != digest {
		t.Fatal("canonical fingerprint changed")
	}
	for _, raw := range []string{"", "database is locked", "read -1", "read +1", "read 1 trailing", "delete\ncommitted\nextra", strings.Repeat("x", 1025)} {
		if _, err := legacySQLResult([]byte(raw), false); err == nil {
			t.Fatalf("invalid SQLite reply accepted: %q", raw)
		}
	}
	if got, err := legacySQLResult([]byte("Runtime error near line 5: database is locked (5)"), true); err != nil || got != "error database is locked" {
		t.Fatal("SQLite lock failure lost")
	}
	if got, err := legacySQLResult([]byte("delete\nread 13\n"), false); err != nil || got != "read 13" {
		t.Fatal("SQLite row count changed")
	}
}
func FuzzCanonicalFixtureReplies(f *testing.F) {
	for _, raw := range []string{"delete\nread 13\n", "delete\ncommitted\n", "Runtime error: database is locked (5)", "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881", ""} {
		f.Add([]byte(raw), false)
		f.Add([]byte(raw), true)
	}
	f.Fuzz(func(t *testing.T, raw []byte, failed bool) {
		if got, err := canonicalCLIDigest(raw); err == nil {
			if len(raw) > canonicalReplyLimit || len(got) != 64 {
				t.Fatal("unbounded or changed fingerprint")
			}
			again, err := canonicalCLIDigest([]byte(got))
			if err != nil || again != got {
				t.Fatal("fingerprint ID roundtrip changed")
			}
		}
		if got, err := legacySQLResult(raw, failed); err == nil {
			if len(raw) > 1024 {
				t.Fatal("unbounded SQLite response")
			}
			if failed {
				if got != "error database is locked" {
					t.Fatal("SQLite failure became success")
				}
			} else {
				again, err := legacySQLResult([]byte(got), false)
				if err != nil || again != got {
					t.Fatal("SQLite result roundtrip changed")
				}
			}
		}
	})
}

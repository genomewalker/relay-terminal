//go:build linux

package daemon

import "testing"

func TestParseForegroundProcessGroupHandlesCommandSpaces(t *testing.T) {
	group, err := parseForegroundProcessGroup(
		"123 (shell with spaces) S 1 123 123 34816 456 0 0 0 0",
	)
	if err != nil {
		t.Fatal(err)
	}
	if group != 456 {
		t.Fatalf("foreground process group = %d, want 456", group)
	}
}

func TestParseForegroundProcessGroupRejectsMalformedStat(t *testing.T) {
	if _, err := parseForegroundProcessGroup("malformed"); err == nil {
		t.Fatal("malformed proc stat was accepted")
	}
}

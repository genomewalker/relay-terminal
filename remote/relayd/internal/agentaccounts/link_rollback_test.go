package agentaccounts

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// bc08 review of 0.5.27: linkShared moved an account's own file to its
// backup and then, if the link could not be created, left the account without
// that file, so its live agents lost their settings. The backup is now moved
// back and the item reported unsupported.
func TestLinkSharedRestoresTheOwnFileWhenTheLinkFails(t *testing.T) {
	home := t.TempDir()
	main, root := filepath.Join(home, ".claude"), filepath.Join(home, ".claude-team")
	for _, dir := range []string{main, root} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeFile(t, filepath.Join(main, "settings.json"), `{"statusLine":{}}`)
	own := filepath.Join(root, "settings.json")
	writeFile(t, own, `{"crossSessionInbound":"accept"}`)

	saved := createLink
	createLink = func(string, string) error { return errors.New("link refused") }
	defer func() { createLink = saved }()

	result := linkShared(filepath.Join(main, "settings.json"), own, observe(own), "20261108T080000Z")
	if result.State != LinkUnsupported || result.Backup != "" {
		t.Fatalf("result = %+v, want unsupported with no backup", result)
	}
	info, err := os.Lstat(own)
	if err != nil || info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("own file not restored: %v %v", info, err)
	}
	if data, _ := os.ReadFile(own); string(data) != `{"crossSessionInbound":"accept"}` {
		t.Fatalf("own file content changed: %s", data)
	}
	if left, _ := filepath.Glob(own + ".relay-backup-*"); len(left) != 0 {
		t.Fatalf("backup left behind: %v", left)
	}

	// An absent destination whose link fails stays absent.
	missing := filepath.Join(root, "CLAUDE.md")
	writeFile(t, filepath.Join(main, "CLAUDE.md"), "rules")
	if r := linkShared(filepath.Join(main, "CLAUDE.md"), missing, observe(missing), "20261108T080000Z"); r.State != LinkUnsupported {
		t.Fatalf("missing item result = %+v", r)
	}
	if _, err := os.Lstat(missing); !os.IsNotExist(err) {
		t.Fatalf("failed link left something behind: %v", err)
	}
}

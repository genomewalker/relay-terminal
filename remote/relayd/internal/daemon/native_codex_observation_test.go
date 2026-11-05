package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCodexObservationReadsMetadataWithoutRescanningGrowingTranscript(t *testing.T) {
	id := "01a18b32-f284-7220-91a2-6a81cde6db14"
	path := filepath.Join(t.TempDir(), "session.jsonl")
	header := `{"type":"session_meta","payload":{"id":"` + id + `","cwd":"/project","source":"cli"}}` + "\n"
	if err := os.WriteFile(path, []byte(header+"an arbitrary unfinished append"), 0600); err != nil {
		t.Fatal(err)
	}
	if cwd, _, err := readCodexObservationHeader(path, id); err != nil || cwd != "/project" {
		t.Fatalf("read %q %v", cwd, err)
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.WriteString("another append")
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := readCodexObservationHeader(path, id); err != nil {
		t.Fatal("ordinary output blocked observation", err)
	}
	if _, _, err := readCodexObservationHeader(path, "01a18b32-f284-7220-91a2-6a81cde6db15"); err == nil {
		t.Fatal("accepted wrong session")
	}
	link := filepath.Join(filepath.Dir(path), "link.jsonl")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, _, err := readCodexObservationHeader(link, id); err == nil {
		t.Fatal("followed final symlink")
	}
	if err := os.WriteFile(path, []byte(`{"type":"session_meta","payload":{"id":"`+id+`","cwd":"relative","source":"cli"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := readCodexObservationHeader(path, id); err == nil {
		t.Fatal("accepted relative project")
	}
}

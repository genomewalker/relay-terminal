//go:build darwin

package daemon

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDarwinNativeTranscriptDescriptorFields(t *testing.T) {
	path := "/private/tmp/fixture sessions/rollout α.jsonl"
	raw := "p42\nf12w\ntREG\nD0x1000014\ni98765\nn" + path + "\nf13u\ntIPv4\nn127.0.0.1:80\n"
	got, err := darwinNativeTranscriptDescriptors(raw, 42)
	if err != nil || len(got) != 1 || got[0] != (darwinNativeTranscriptDescriptor{12, path, 0x1000014, 98765}) {
		t.Fatalf("descriptor identity lost: %#v %v", got, err)
	}
	for name, value := range map[string]string{
		"missing_process":      strings.TrimPrefix(raw, "p42\n"),
		"other_process":        strings.Replace(raw, "p42", "p43", 1),
		"repeated_process":     raw + "p42\n",
		"duplicate_path":       strings.Replace(raw, "n"+path+"\n", "n"+path+"\nn"+path+"\n", 1),
		"invalid_inode":        strings.Replace(raw, "i98765", "iNaN", 1),
		"invalid_device":       strings.Replace(raw, "D0x1000014", "Dunknown", 1),
		"zero_inode":           strings.Replace(raw, "i98765", "i0", 1),
		"relative_path":        strings.Replace(raw, "n"+path, "nrelative.jsonl", 1),
		"unknown_field":        raw + "zunknown\n",
		"large_inventory":      strings.Repeat("x", 1<<20+1),
		"too_many_descriptors": "p42\n" + strings.Repeat("f1w\ntREG\nD0x1000014\ni98765\nn"+path+"\n", 4097),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := darwinNativeTranscriptDescriptors(value, 42); err == nil {
				t.Fatal("ambiguous native descriptor accepted")
			}
		})
	}
	if records, err := darwinNativeTranscriptDescriptors("p42\nfmem\ntREG\nD0x1000014\ni98765\nn"+path+"\n", 42); err != nil || len(records) != 0 {
		t.Fatal("non-descriptor mapping accepted", records, err)
	}
}

func TestDarwinOpenCodexTranscriptKernelIdentityAndAmbiguity(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("CODEX_HOME", root)
	directory := filepath.Join(root, "sessions")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "rollout.jsonl")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	row := `{"type":"session_meta","payload":{"id":"01a10251-94a1-7d91-acc4-34493b16342b"}}` + "\n"
	if _, err := file.WriteString(row); err != nil {
		t.Fatal(err)
	}
	observe := func() (string, string, string, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return darwinOpenCodexTranscript(ctx, os.Getpid())
	}
	actual, sid, identity, err := observe()
	if err != nil || actual != path || sid != "01a10251-94a1-7d91-acc4-34493b16342b" || identity == "" {
		t.Fatalf("actual descriptor not observed: %q %q %q %v", actual, sid, identity, err)
	}
	if _, err := file.WriteString(`{"type":"event_msg"}` + "\n"); err != nil {
		t.Fatal(err)
	}
	_, _, after, err := observe()
	if err != nil || identity != after {
		t.Fatalf("append changed identity: %q %q %v", identity, after, err)
	}
	second, err := os.OpenFile(filepath.Join(directory, "second.jsonl"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := second.WriteString(row); err != nil {
		second.Close()
		t.Fatal(err)
	}
	if _, _, _, err := observe(); err == nil {
		second.Close()
		t.Fatal("multiple live transcripts accepted")
	}
	second.Close()
	if _, _, _, err := observe(); err != nil {
		t.Fatal("single descriptor not restored", err)
	}
	if err := os.Rename(path, filepath.Join(directory, "retired")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(row), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := observe(); err == nil {
		t.Fatal("replacement named file recreated ownership")
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	malformed, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer malformed.Close()
	if _, err := fmt.Fprintln(malformed, `{"type":"session_meta","payload":{"id":"01a10251-94a1-7d91-acc4-34493b16342b","id":"01a10251-94a1-7d91-acc4-34493b16342b"}}`); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := observe(); err == nil {
		t.Fatal("duplicate metadata field accepted")
	}
}

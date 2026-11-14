package daemon

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type directoryScanProbe struct {
	t     *testing.T
	path  string
	start int64
}

func newDirectoryScanProbe(t *testing.T) *directoryScanProbe {
	p := &directoryScanProbe{t: t, path: filepath.Join(t.TempDir(), "transcript.jsonl"), start: -1}
	nativeDirectoryScanStarted = func(path string, start int64) {
		if path == p.path {
			p.start = start
		}
	}
	t.Cleanup(func() { nativeDirectoryScanStarted = nil })
	return p
}

// scan runs the incremental scan and checks it against a whole-file parse.
func (p *directoryScanProbe) scan() (string, []string, error) {
	p.t.Helper()
	return p.scanWith(true)
}

func (p *directoryScanProbe) scanWith(resume bool) (string, []string, error) {
	p.t.Helper()
	file, err := os.Open(p.path)
	if err != nil {
		p.t.Fatal(err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		p.t.Fatal(err)
	}
	cwd, dirs, err := scanHostRotationNativeDirectory(context.Background(), file, info, p.path, "claude", "fixture-session", resume)
	whole, err2 := os.ReadFile(p.path)
	if err2 != nil {
		p.t.Fatal(err2)
	}
	wantCWD, wantDirs, wantErr := parseHostRotationNativeDirectoryEvidence(context.Background(), strings.NewReader(string(whole)), "claude", "fixture-session")
	if (err == nil) != (wantErr == nil) || cwd != wantCWD || strings.Join(dirs, "|") != strings.Join(wantDirs, "|") {
		p.t.Fatalf("incremental (%q %v %v) differs from whole-file (%q %v %v)", cwd, dirs, err, wantCWD, wantDirs, wantErr)
	}
	return cwd, dirs, err
}

func (p *directoryScanProbe) write(content string) {
	p.t.Helper()
	if err := os.WriteFile(p.path, []byte(content), 0o600); err != nil {
		p.t.Fatal(err)
	}
}

func (p *directoryScanProbe) append(content string) {
	p.t.Helper()
	file, err := os.OpenFile(p.path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		p.t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(content); err != nil {
		p.t.Fatal(err)
	}
}

func (p *directoryScanProbe) size() int64 {
	info, err := os.Stat(p.path)
	if err != nil {
		p.t.Fatal(err)
	}
	return info.Size()
}

func directoryRow(id, cwd string) string {
	return rotationClaudeFixtureRow("user", id, "", strings.Repeat("x", 300), map[string]any{"cwd": cwd})
}

func TestNativeDirectoryScanReadsOnlyAppendedLines(t *testing.T) {
	p := newDirectoryScanProbe(t)
	p.write(directoryRow("a", "/project"))
	if _, _, err := p.scan(); err != nil || p.start != 0 {
		t.Fatalf("first scan err=%v start=%d", err, p.start)
	}
	before := p.size()
	p.append(directoryRow("b", "/project/hooks"))
	root, dirs, err := p.scan()
	if err != nil || p.start != before || root != "/project" || len(dirs) != 2 {
		t.Fatalf("append resumed at %d (want %d): %q %v %v", p.start, before, root, dirs, err)
	}
	// An escaping directory appended later is refused as by a full scan.
	p.append(directoryRow("c", "/elsewhere"))
	if _, _, err := p.scan(); err == nil {
		t.Fatal("appended escaping directory accepted")
	}
}

func TestNativeDirectoryScanDoesNotCommitAnUnfinishedLine(t *testing.T) {
	p := newDirectoryScanProbe(t)
	p.write(directoryRow("a", "/project"))
	if _, _, err := p.scan(); err != nil {
		t.Fatal(err)
	}
	complete := p.size()
	row := directoryRow("b", "/project/hooks")
	p.append(row[:len(row)/2])
	if _, _, err := p.scan(); err == nil {
		t.Fatal("half-written line accepted")
	}
	p.append(row[len(row)/2:])
	if _, dirs, err := p.scan(); err != nil || p.start != complete || len(dirs) != 2 {
		t.Fatalf("completed line resumed at %d (want %d): %v %v", p.start, complete, dirs, err)
	}
}

func TestNativeDirectoryScanRestartsForAReplacedFile(t *testing.T) {
	p := newDirectoryScanProbe(t)
	p.write(directoryRow("a", "/project") + directoryRow("b", "/project/hooks"))
	if _, _, err := p.scan(); err != nil {
		t.Fatal(err)
	}
	replacement := p.path + ".new"
	content := directoryRow("a", "/other") + directoryRow("b", "/other/x") + directoryRow("c", "/other/y")
	if err := os.WriteFile(replacement, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, p.path); err != nil {
		t.Fatal(err)
	}
	if root, dirs, err := p.scan(); err != nil || p.start != 0 || root != "/other" || len(dirs) != 3 {
		t.Fatalf("replaced file resumed at %d: %q %v %v", p.start, root, dirs, err)
	}
}

func TestNativeDirectoryScanRestartsForAShrunkFile(t *testing.T) {
	p := newDirectoryScanProbe(t)
	p.write(directoryRow("a", "/project") + directoryRow("b", "/project/hooks"))
	if _, _, err := p.scan(); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(p.path, int64(len(directoryRow("a", "/project")))); err != nil {
		t.Fatal(err)
	}
	if _, dirs, err := p.scan(); err != nil || p.start != 0 || len(dirs) != 1 {
		t.Fatalf("shrunk file resumed at %d: %v %v", p.start, dirs, err)
	}
}

func TestNativeDirectoryScanRestartsForARewriteInPlace(t *testing.T) {
	// Rows of about 450 bytes: the first row is inside the head fingerprint
	// and, with 20 rows, the last ones are in the tail fingerprint only.
	rows := []string{}
	for i := 0; i < 20; i++ {
		rows = append(rows, directoryRow(string(rune('a'+i)), "/project"))
	}
	for name, edit := range map[string]func(string) string{
		"head": func(s string) string { return strings.Replace(s, "/project", "/projecX", 1) },
		"tail": func(s string) string {
			i := strings.LastIndex(s, "/project")
			return s[:i] + "/projecY" + s[i+len("/projecY"):]
		},
	} {
		t.Run(name, func(t *testing.T) {
			p := newDirectoryScanProbe(t)
			original := strings.Join(rows, "")
			p.write(original)
			if _, _, err := p.scan(); err != nil {
				t.Fatal(err)
			}
			file, err := os.OpenFile(p.path, os.O_WRONLY, 0)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := file.WriteAt([]byte(edit(original)), 0); err != nil {
				t.Fatal(err)
			}
			file.Close()
			p.append(directoryRow("z", "/project"))
			// The whole-file comparison in scan() fails if stale state was reused.
			p.scan()
			if p.start != 0 {
				t.Fatalf("rewritten %s resumed at %d", name, p.start)
			}
		})
	}
}

// A rewrite between the fingerprints is not seen by a resumed observation
// scan (transcripts are append-only), but rotation admission never resumes:
// it rereads every line and refuses the rewritten one.
func TestNativeDirectoryScanRotationRereadsAMiddleRewrite(t *testing.T) {
	rows := []string{}
	for i := 0; i < 40; i++ {
		rows = append(rows, directoryRow(string(rune('A'+i)), "/project"))
	}
	p := newDirectoryScanProbe(t)
	original := strings.Join(rows, "")
	p.write(original)
	if _, _, err := p.scan(); err != nil {
		t.Fatal(err)
	}
	middle := len(original) / 2
	i := middle + strings.Index(original[middle:], "/project")
	file, err := os.OpenFile(p.path, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteAt([]byte("/elsewhe"), int64(i)); err != nil {
		t.Fatal(err)
	}
	file.Close()
	if i < nativeDirectoryFingerprintBytes || len(original)-i < nativeDirectoryFingerprintBytes {
		t.Fatalf("edit at %d is inside a fingerprint", i)
	}
	if _, _, err := p.scanWith(false); err == nil || p.start != 0 {
		t.Fatalf("rotation scan started at %d and returned %v; want a full reread that refuses the rewrite", p.start, err)
	}
}

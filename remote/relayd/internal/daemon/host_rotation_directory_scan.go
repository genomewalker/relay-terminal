package daemon

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"unicode/utf8"
)

// Directory discovery runs for every agent pane on each capacity check (once
// a minute). Rereading a whole transcript each time cost the node several
// cores for seconds on hosts with transcripts of hundreds of MB. Transcripts
// only grow, so the node keeps each file's scan state and reads only the
// lines added since; every line is still checked exactly as before. Only
// capacity observation resumes: rotation and restore admission always pass
// resume=false and reread every line (the result refreshes the saved scan).

// nativeDirectoryScan is the per-line state of a directory scan.
type nativeDirectoryScan struct {
	provider, session string
	cwd               string
	identified        bool
	records           int
	directories       []string
	seen              map[string]bool
}

func newNativeDirectoryScan(provider, session string) (*nativeDirectoryScan, error) {
	if provider != "codex" && provider != "claude" {
		return nil, errors.New("unsupported native provider")
	}
	return &nativeDirectoryScan{provider: provider, session: session, directories: []string{}, seen: map[string]bool{}}, nil
}

func (s *nativeDirectoryScan) clone() *nativeDirectoryScan {
	c := *s
	c.directories = append([]string{}, s.directories...)
	c.seen = make(map[string]bool, len(s.seen))
	for k, v := range s.seen {
		c.seen[k] = v
	}
	return &c
}

func (s *nativeDirectoryScan) line(line []byte) error {
	s.records++
	if s.records > 200000 {
		return errors.New("native directory record limit exceeded")
	}
	if !utf8.Valid(line) || !rotationSourceJSONUnambiguous(line) {
		return errors.New("invalid native directory metadata")
	}
	var row rotationSourceRow
	if json.Unmarshal(line, &row) != nil {
		return errors.New("invalid native directory record")
	}
	observed := ""
	if s.provider == "codex" {
		if row.Type == "response_item" && !s.identified {
			return errors.New("native directory identity must precede messages")
		}
		if row.Type != "session_meta" {
			return nil
		}
		var meta struct {
			ID           string          `json:"id"`
			CWD          string          `json:"cwd"`
			ThreadSource string          `json:"thread_source"`
			Source       json.RawMessage `json:"source"`
		}
		if s.identified || json.Unmarshal(row.Payload, &meta) != nil || meta.ID != s.session ||
			(meta.ThreadSource != "" && meta.ThreadSource != "user") ||
			(meta.ThreadSource == "" && string(meta.Source) != `"cli"`) {
			return errors.New("native directory session identity mismatch")
		}
		observed = meta.CWD
	} else {
		if (row.Type != "user" && row.Type != "assistant") || row.Sidechain {
			return nil
		}
		if row.SessionID != s.session {
			return errors.New("native directory session identity mismatch")
		}
		observed = row.CWD
	}
	if !filepath.IsAbs(observed) || len(observed) > 4096 || strings.ContainsRune(observed, 0) || filepath.Clean(observed) != observed ||
		(s.identified && !nativeDirectoryWithin(s.cwd, observed)) {
		return errors.New("native session directory is missing or outside the original project root")
	}
	if !s.identified {
		s.cwd, s.identified = observed, true
	}
	if !s.seen[observed] {
		if len(s.directories) >= 256 {
			return errors.New("native session directory inventory exceeds bound")
		}
		s.seen[observed] = true
		s.directories = append(s.directories, observed)
	}
	return nil
}

func (s *nativeDirectoryScan) result() (string, []string, error) {
	if !s.identified {
		return "", nil, errors.New("native session directory metadata unavailable")
	}
	return s.cwd, append([]string{}, s.directories...), nil
}

// scanNativeDirectoryLines feeds every line of reader to scan, starting at a
// line boundary. Complete (newline-terminated) lines advance scan and the
// returned count of consumed bytes; a final unterminated line is checked on a
// copy, exactly as a whole-file scan would, without being committed. When a
// complete line is refused, consumed includes that line and permanent is set:
// appending to the file cannot change the result.
func scanNativeDirectoryLines(ctx context.Context, reader io.Reader, scan *nativeDirectoryScan) (final *nativeDirectoryScan, consumed int64, permanent bool, err error) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64<<10), rotationSourceLineLimit)
	complete, lastAdvance := false, 0
	scanner.Split(func(data []byte, atEOF bool) (int, []byte, error) {
		advance, token, err := bufio.ScanLines(data, atEOF)
		if token != nil {
			complete, lastAdvance = advance > 0 && data[advance-1] == '\n', advance
		}
		return advance, token, err
	})
	final = scan
	for scanner.Scan() {
		if ctx.Err() != nil {
			return nil, 0, false, ctx.Err()
		}
		line := scanner.Bytes()
		if complete {
			if err := scan.line(line); err != nil {
				return nil, consumed + int64(lastAdvance), true, err
			}
			consumed += int64(lastAdvance)
			final = scan
			continue
		}
		partial := scan.clone()
		if err := partial.line(line); err != nil {
			return nil, 0, false, err
		}
		final = partial
	}
	if scanner.Err() != nil {
		return nil, 0, false, errors.New("native directory line limit or read failure")
	}
	if ctx.Err() != nil {
		return nil, 0, false, ctx.Err()
	}
	return final, consumed, false, nil
}

const nativeDirectoryFingerprintBytes = 4096

type nativeDirectoryCacheEntry struct {
	dev, ino          uint64
	provider, session string
	// offset is the end of the last complete line in scan.
	offset int64
	// head and tail are the file's first bytes and the bytes ending at
	// offset when the scan was saved; a replaced or rewritten file whose
	// identity survived differs in one of them.
	head, tail []byte
	// Exactly one of scan and failure is set; failure is a refused complete
	// line ending at offset.
	scan    *nativeDirectoryScan
	failure error
	used    uint64
}

var nativeDirectoryCache = struct {
	sync.Mutex
	entries map[string]*nativeDirectoryCacheEntry
	clock   uint64
}{entries: map[string]*nativeDirectoryCacheEntry{}}

const nativeDirectoryCacheLimit = 256

// nativeDirectoryScanStarted observes where each scan starts (tests only).
var nativeDirectoryScanStarted func(path string, start int64)

func fileIdentity(info os.FileInfo) (uint64, uint64, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, false
	}
	return uint64(stat.Dev), uint64(stat.Ino), true
}

func readFingerprint(file *os.File, end int64) ([]byte, bool) {
	start := end - nativeDirectoryFingerprintBytes
	if start < 0 {
		start = 0
	}
	buffer := make([]byte, end-start)
	if _, err := file.ReadAt(buffer, start); err != nil && !(errors.Is(err, io.EOF) && end == start) {
		return nil, false
	}
	return buffer, true
}

// scanHostRotationNativeDirectory returns the same evidence as a whole-file
// parseHostRotationNativeDirectoryEvidence of the first size bytes of file,
// resuming from this node's saved scan of the same file when its identity,
// first bytes and bytes before the saved offset are unchanged and resume is set.
func scanHostRotationNativeDirectory(ctx context.Context, file *os.File, info os.FileInfo, path, provider, session string, resume bool) (string, []string, error) {
	size := info.Size()
	dev, ino, identified := fileIdentity(info)
	headLength := int64(nativeDirectoryFingerprintBytes)
	if size < headLength {
		headLength = size
	}
	head, ok := readFingerprint(file, headLength)
	if !ok {
		return "", nil, errors.New("native transcript unavailable")
	}
	var scan *nativeDirectoryScan
	var start int64
	nativeDirectoryCache.Lock()
	entry := nativeDirectoryCache.entries[path]
	nativeDirectoryCache.Unlock()
	if resume && entry != nil && identified && entry.dev == dev && entry.ino == ino && entry.provider == provider &&
		entry.session == session && entry.offset <= size && len(head) >= len(entry.head) && bytes.HasPrefix(head, entry.head) {
		if tail, ok := readFingerprint(file, entry.offset); ok && bytes.Equal(tail, entry.tail) {
			if entry.failure != nil {
				if nativeDirectoryScanStarted != nil {
					nativeDirectoryScanStarted(path, entry.offset)
				}
				return "", nil, entry.failure
			}
			scan, start = entry.scan.clone(), entry.offset
		}
	}
	if scan == nil {
		fresh, err := newNativeDirectoryScan(provider, session)
		if err != nil {
			return "", nil, err
		}
		scan = fresh
	}
	if nativeDirectoryScanStarted != nil {
		nativeDirectoryScanStarted(path, start)
	}
	final, consumed, permanent, err := scanNativeDirectoryLines(ctx, io.NewSectionReader(file, start, size-start), scan)
	if err != nil {
		if permanent {
			saveNativeDirectoryScan(file, path, &nativeDirectoryCacheEntry{dev: dev, ino: ino, provider: provider,
				session: session, offset: start + consumed, head: head, failure: err}, identified)
		}
		return "", nil, err
	}
	cwd, directories, err := final.result()
	if err != nil {
		return "", nil, err
	}
	saveNativeDirectoryScan(file, path, &nativeDirectoryCacheEntry{dev: dev, ino: ino, provider: provider,
		session: session, offset: start + consumed, head: head, scan: scan.clone()}, identified)
	return cwd, directories, nil
}

func saveNativeDirectoryScan(file *os.File, path string, entry *nativeDirectoryCacheEntry, identified bool) {
	if !identified {
		return
	}
	tail, ok := readFingerprint(file, entry.offset)
	if !ok {
		return
	}
	entry.tail = tail
	nativeDirectoryCache.Lock()
	defer nativeDirectoryCache.Unlock()
	nativeDirectoryCache.clock++
	entry.used = nativeDirectoryCache.clock
	nativeDirectoryCache.entries[path] = entry
	evictNativeDirectoryCacheLocked()
}

func evictNativeDirectoryCacheLocked() {
	for len(nativeDirectoryCache.entries) > nativeDirectoryCacheLimit {
		oldest, oldestUse := "", ^uint64(0)
		for path, entry := range nativeDirectoryCache.entries {
			if entry.used < oldestUse {
				oldest, oldestUse = path, entry.used
			}
		}
		delete(nativeDirectoryCache.entries, oldest)
	}
}

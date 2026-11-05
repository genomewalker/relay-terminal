package rotationtext

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unicode/utf8"
)

// Ledger is the Go-native text journal store, replacing the sqlite database
// text_backend.py kept. It lives beside it in rotation-text/:
//
//	ledger.lock  flock target: LOCK_EX is BEGIN IMMEDIATE (5 s busy timeout)
//	ledger.read  flock target: the commit gate, sqlite's PENDING/EXCLUSIVE
//	ledger.log   append-only frames: "RTL1" | u32 length | u32 CRC-32C | JSON
//
// The first frame is a snapshot of the whole journal; each later frame is one
// committed transaction. A commit is durable before Commit returns (fsync, as
// synchronous=FULL). A crash can leave only an incomplete last frame, which the
// next writer truncates; damage anywhere else is reported, never repaired.
// Readers outside a transaction are not blocked by an open transaction, only
// by a commit: they read holding the gate shared, and a writer holds it
// exclusively from appending its frame until the fsync returned (or the frame
// of a failed fsync is truncated), so a reader sees committed frames only.
// The log is capped like open_journal's max_page_count (16384 4 KiB pages);
// a commit that would pass the cap first compacts the log into one snapshot.
//
// The first open imports operations.sqlite3 once, under the lock: its state
// becomes the first snapshot, which records the import, and the log appears
// by an atomic rename, so a crash before it leaves nothing to undo. The sqlite
// file is only read; it stays as the rollback path. While open, the ledger
// holds sqlite's SHARED lock on it (legacy_hold.go), and an open refuses a
// legacy journal that changed after the import (journal_diverged).
type Ledger struct {
	root     string
	ctx      context.Context // the operation's: lock waits end with it
	lock     *os.File
	gate     *os.File
	log      *os.File
	logInfo  os.FileInfo
	offset   int64 // end of the last whole frame
	state    *ledgerState
	imported *LedgerImport
	saved    *ledgerState // state at Begin, restored by Rollback
	pending  []ledgerOp
	inTx     bool
	stale    bool        // reopen the log before the next read
	legacy   *legacyHold // SHARED on operations.sqlite3 while open; nil without one
}

const (
	ledgerLogName     = "ledger.log"
	ledgerLockName    = "ledger.lock"
	ledgerGateName    = "ledger.read"
	ledgerTempName    = "ledger.log.tmp"
	legacyJournalName = "operations.sqlite3"
	ledgerLockTimeout = 5 * time.Second
	ledgerFrameHeader = 12
)

// ledgerCap is open_journal's max_page_count (16384) of 4 KiB pages; a
// variable only so tests can reach it quickly.
var ledgerCap int64 = 16384 * 4096

// ledgerSync is synchronous=FULL: every commit, truncation, snapshot and
// directory entry reaches stable storage before the lock is released. On
// darwin File.Sync is F_FULLFSYNC. Tests observe it.
var ledgerSync = func(file *os.File) error { return file.Sync() }

// ledgerTruncate removes a failed commit's frame; tests observe it.
var ledgerTruncate = func(file *os.File, size int64) error { return file.Truncate(size) }

var (
	ledgerMagic       = []byte("RTL1")
	ledgerCRC         = crc32.MakeTable(crc32.Castagnoli)
	errLedgerCorrupt  = errors.New("text ledger is corrupt")
	errLedgerFull     = errors.New("text ledger is full")
	errLedgerLocked   = errors.New("text ledger is locked")
	errLedgerNoWriter = errors.New("text ledger write outside a transaction")
)

// LedgerImport records the one-time import in the first snapshot. Source is
// empty when no legacy journal existed.
type LedgerImport struct {
	Source          string `json:"source"`
	SHA256          string `json:"sha256"`
	Size            int64  `json:"size"`
	MTime           int64  `json:"mtime_ns"`
	HotJournalPages int    `json:"hot_journal_pages"`
	// RolledBackSHA256 is the file sqlite leaves after rolling back the hot
	// journal that was applied in memory; empty without one.
	RolledBackSHA256     string `json:"rolled_back_sha256,omitempty"`
	Operations           int    `json:"operations"`
	ConfigurationChanges int    `json:"configuration_changes"`
}

type ledgerChange struct {
	ID    string `json:"id"`
	Value string `json:"value"`
}

type ledgerSettings struct {
	OperationID string `json:"operation_id"`
	Value       string `json:"value"`
}

// ledgerOp is one effective write of a committed transaction.
type ledgerOp struct {
	Op      string     `json:"op"` // settings_init, settings, change, insert, finish, abandon
	ID      string     `json:"id"`
	Value   string     `json:"value"`
	Row     *Operation `json:"row,omitempty"`
	State   string     `json:"state"`
	Charged int64      `json:"charged"`
	Result  *string    `json:"result"`
}

type ledgerFrame struct {
	V          int             `json:"v"`
	Kind       string          `json:"kind"` // snapshot or commit
	Import     *LedgerImport   `json:"import,omitempty"`
	Settings   *ledgerSettings `json:"settings,omitempty"`
	Changes    []ledgerChange  `json:"changes,omitempty"`
	Operations []Operation     `json:"operations,omitempty"`
	Ops        []ledgerOp      `json:"ops,omitempty"`
}

// ledgerState is the journal's three tables, rows in insertion order.
type ledgerState struct {
	HasSettings               bool
	SettingsID, SettingsValue string
	Changes                   []ledgerChange
	Rows                      []Operation
	changes                   map[string]int
	ids, fingerprints         map[string]int
}

func newLedgerState() *ledgerState {
	return &ledgerState{changes: map[string]int{}, ids: map[string]int{}, fingerprints: map[string]int{}}
}

func (s *ledgerState) clone() *ledgerState {
	out := &ledgerState{HasSettings: s.HasSettings, SettingsID: s.SettingsID, SettingsValue: s.SettingsValue,
		Changes: append([]ledgerChange(nil), s.Changes...), Rows: append([]Operation(nil), s.Rows...),
		changes: make(map[string]int, len(s.changes)), ids: make(map[string]int, len(s.ids)),
		fingerprints: make(map[string]int, len(s.fingerprints))}
	for key, value := range s.changes {
		out.changes[key] = value
	}
	for key, value := range s.ids {
		out.ids[key] = value
	}
	for key, value := range s.fingerprints {
		out.fingerprints[key] = value
	}
	return out
}

// insertChange and insertOperation enforce the sqlite PRIMARY KEY and UNIQUE
// constraints.
func (s *ledgerState) insertChange(id, value string) error {
	if _, ok := s.changes[id]; ok {
		return errors.New("UNIQUE constraint failed: configuration_changes.id")
	}
	s.changes[id] = len(s.Changes)
	s.Changes = append(s.Changes, ledgerChange{id, value})
	return nil
}

func (s *ledgerState) insertOperation(row Operation) error {
	_, id := s.ids[row.ID]
	_, fingerprint := s.fingerprints[row.Fingerprint]
	if id || fingerprint {
		return errors.New("UNIQUE constraint failed: operations")
	}
	s.ids[row.ID] = len(s.Rows)
	s.fingerprints[row.Fingerprint] = len(s.Rows)
	s.Rows = append(s.Rows, row)
	return nil
}

// apply performs one write with the journal's SQL semantics and reports
// whether it changed anything. Replay applies the same writes in order.
func (s *ledgerState) apply(op ledgerOp) (bool, error) {
	switch op.Op {
	case "settings_init": // INSERT OR IGNORE INTO settings VALUES (1, '', ?)
		if s.HasSettings {
			return false, nil
		}
		s.HasSettings, s.SettingsID, s.SettingsValue = true, "", op.Value
		return true, nil
	case "settings": // UPDATE settings SET operation_id=?, value=? WHERE singleton=1
		if !s.HasSettings {
			return false, nil
		}
		s.SettingsID, s.SettingsValue = op.ID, op.Value
		return true, nil
	case "change":
		return true, s.insertChange(op.ID, op.Value)
	case "insert":
		if op.Row == nil {
			return false, errLedgerCorrupt
		}
		return true, s.insertOperation(*op.Row)
	case "finish": // UPDATE ... WHERE id=? AND state='pending'
		i, ok := s.ids[op.ID]
		if !ok || s.Rows[i].State != "pending" {
			return false, nil
		}
		result := op.Result
		if result != nil {
			copied := *result
			result = &copied
		}
		s.Rows[i].State, s.Rows[i].Charged, s.Rows[i].Result = op.State, op.Charged, result
		return true, nil
	case "abandon": // UPDATE ... WHERE id=? AND state IN ('pending','uncertain')
		i, ok := s.ids[op.ID]
		if !ok || s.Rows[i].State != "pending" && s.Rows[i].State != "uncertain" {
			return false, nil
		}
		s.Rows[i].State = "abandoned"
		return true, nil
	}
	return false, errLedgerCorrupt
}

// OpenLedger opens (creating, and importing on first use) the ledger in root,
// the worker's rotation-text directory, with open_journal's checks: an
// absolute path, a private directory, and private single-link regular files.
func OpenLedger(root string) (*Ledger, error) { return OpenLedgerContext(context.Background(), root) }

// OpenLedgerContext is OpenLedger for one operation: every lock wait of the
// ledger, at open and at Begin, also ends when ctx does.
func OpenLedgerContext(ctx context.Context, root string) (*Ledger, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !filepath.IsAbs(root) {
		return nil, &draftError{code: "invalid_state_directory"}
	}
	if err := os.Mkdir(root, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, err
	}
	info, err := os.Lstat(root)
	if err != nil {
		return nil, err
	}
	if err := safeJournalInfo(info, true); err != nil {
		return nil, err
	}
	lock, err := openLedgerFile(filepath.Join(root, ledgerLockName), true)
	if err != nil {
		return nil, err
	}
	l := &Ledger{root: root, ctx: ctx, lock: lock, state: newLedgerState()}
	if l.gate, err = openLedgerFile(filepath.Join(root, ledgerGateName), true); err != nil {
		l.Close()
		return nil, err
	}
	if err := l.lockExclusive(); err != nil {
		l.Close()
		return nil, err
	}
	l.legacy, err = holdLegacyJournal(ctx, l.path(legacyJournalName))
	if err == nil {
		err = l.checkPoisoned()
	}
	if err == nil {
		err = l.ensureLog()
	}
	if err == nil {
		err = l.refresh(false)
	}
	l.unlock()
	if err == nil {
		err = l.checkLegacy()
	}
	if err == nil {
		err = ctx.Err() // an opener past its deadline gets no ledger
	}
	if err != nil {
		l.Close()
		return nil, err
	}
	return l, nil
}

// OpenLedgerJournal is the production journal: a Journal over the ledger in
// root with the real backends and clock.
func OpenLedgerJournal(ctx context.Context, root string) (*Journal, error) {
	ledger, err := OpenLedgerContext(ctx, root)
	if err != nil {
		return nil, err
	}
	journal, err := OpenJournal(ledger, nil, nil)
	if err != nil {
		ledger.Close()
		return nil, err
	}
	return journal, nil
}

// safeJournalInfo is safe_journal_file: owned by this user, no group or other
// permissions, and (for files) a single link.
func safeJournalInfo(info os.FileInfo, directory bool) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	kind := info.Mode().IsRegular()
	if directory {
		kind = info.IsDir()
	}
	if !ok || !kind || stat.Uid != uint32(os.Getuid()) || uint32(stat.Mode)&0o077 != 0 ||
		!directory && uint64(stat.Nlink) != 1 {
		return &draftError{code: "journal_permissions"}
	}
	return nil
}

// openLedgerFile opens a private ledger file read-write without following a
// symlink, creating it (and syncing its directory) when asked.
func openLedgerFile(path string, create bool) (*os.File, error) {
	flags := os.O_RDWR | syscall.O_NOFOLLOW
	if create {
		file, err := os.OpenFile(path, flags|os.O_CREATE|os.O_EXCL, 0o600)
		if err == nil {
			if err = ledgerSync(file); err == nil {
				err = syncDirectory(filepath.Dir(path))
			}
			if err != nil {
				file.Close()
				return nil, err
			}
			return file, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if err := safeJournalInfo(info, false); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, flags, 0)
	if err != nil {
		return nil, err
	}
	opened, err := file.Stat()
	if err == nil && !os.SameFile(info, opened) {
		err = errors.New("text ledger file changed while opening")
	}
	if err == nil {
		err = safeJournalInfo(opened, false)
	}
	if err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return ledgerSync(directory)
}

func (l *Ledger) path(name string) string { return filepath.Join(l.root, name) }

func (l *Ledger) lockExclusive() error { return l.flock(l.lock, syscall.LOCK_EX) }

// flock takes how on file, waiting like sqlite's busy timeout or until the
// operation's context ends.
func (l *Ledger) flock(file *os.File, how int) error {
	deadline := time.Now().Add(ledgerLockTimeout)
	for {
		err := syscall.Flock(int(file.Fd()), how|syscall.LOCK_NB)
		if err == nil {
			return nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EINTR) {
			return err
		}
		if time.Now().After(deadline) {
			return errLedgerLocked
		}
		select {
		case <-l.ctx.Done():
			return l.ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
}

func (l *Ledger) unlock() { _ = syscall.Flock(int(l.lock.Fd()), syscall.LOCK_UN) }

// ensureLog creates the log on first use, importing the legacy journal. The
// caller holds the lock, so exactly one process imports.
func (l *Ledger) ensureLog() error {
	if _, err := os.Lstat(l.path(ledgerLogName)); err == nil || !errors.Is(err, os.ErrNotExist) {
		return err
	}
	state, record := newLedgerState(), &LedgerImport{}
	legacy := l.path(legacyJournalName)
	if l.legacy != nil {
		// Read through the held descriptor: closing another would drop the lock.
		imported, err := readLegacyFile(l.legacy.file, legacy)
		if err != nil {
			return err
		}
		state = imported.state
		record = &LedgerImport{Source: legacyJournalName, SHA256: imported.sha256, Size: imported.size,
			MTime: imported.mtime, HotJournalPages: imported.hotJournalPages, RolledBackSHA256: imported.rolledBackSHA256,
			Operations: len(state.Rows), ConfigurationChanges: len(state.Changes)}
	} else if _, err := os.Lstat(legacy); !errors.Is(err, os.ErrNotExist) {
		return errors.New("legacy journal appeared while opening the ledger")
	}
	return l.writeSnapshot(state, record)
}

// writeSnapshot replaces the log with one snapshot frame by an atomic rename.
func (l *Ledger) writeSnapshot(state *ledgerState, record *LedgerImport) error {
	frame := ledgerFrame{V: 1, Kind: "snapshot", Import: record, Changes: state.Changes, Operations: state.Rows}
	if state.HasSettings {
		frame.Settings = &ledgerSettings{state.SettingsID, state.SettingsValue}
	}
	data, err := encodeLedgerFrame(frame)
	if err != nil {
		return err
	}
	if int64(len(data)) > ledgerCap {
		return errLedgerFull
	}
	temporary := l.path(ledgerTempName)
	if err := os.Remove(temporary); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	file, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	_, err = file.Write(data)
	if err == nil {
		err = ledgerSync(file)
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(temporary, l.path(ledgerLogName))
	}
	if err != nil {
		_ = os.Remove(temporary)
		return err
	}
	l.stale = true
	if err := syncDirectory(l.root); err != nil {
		// The new log is in place and read by everyone; only whether the
		// rename survives a crash is unknown.
		return &errLedgerDurabilityUnknown{root: l.root, cause: err}
	}
	return nil
}

func encodeLedgerFrame(frame ledgerFrame) ([]byte, error) {
	payload, err := json.Marshal(frame)
	if err != nil {
		return nil, err
	}
	data := make([]byte, ledgerFrameHeader, ledgerFrameHeader+len(payload))
	copy(data, ledgerMagic)
	binary.BigEndian.PutUint32(data[4:], uint32(len(payload)))
	binary.BigEndian.PutUint32(data[8:], crc32.Checksum(payload, ledgerCRC))
	return append(data, payload...), nil
}

// refresh brings the in-memory state up to the log's last whole frame. A
// writer (holding the lock) truncates an incomplete last frame.
func (l *Ledger) refresh(writer bool) error {
	info, err := os.Lstat(l.path(ledgerLogName))
	if err != nil {
		return err
	}
	if err := safeJournalInfo(info, false); err != nil {
		return err
	}
	if l.log != nil && !l.stale && os.SameFile(info, l.logInfo) && info.Size() >= l.offset {
		if err := l.read(writer); err == nil {
			return nil
		}
		// A reader racing a writer's truncation or compaction rereads.
	}
	return l.reload(writer)
}

func (l *Ledger) reload(writer bool) error {
	var file *os.File
	var info os.FileInfo
	for attempt := 0; ; attempt++ {
		opened, err := openLedgerFile(l.path(ledgerLogName), false)
		if err == nil {
			file = opened
			info, err = file.Stat()
		}
		if err == nil {
			break
		}
		if file != nil {
			file.Close()
			file = nil
		}
		// A concurrent compaction can rename the log between lstat and open.
		if attempt == 2 {
			return err
		}
	}
	if l.log != nil {
		l.log.Close()
	}
	l.log, l.logInfo, l.offset, l.state, l.stale = file, info, 0, newLedgerState(), false
	return l.read(writer)
}

// read applies the frames after l.offset. Only a damaged last frame is a
// torn tail; it is ignored, and truncated by a writer.
func (l *Ledger) read(writer bool) error {
	info, err := l.log.Stat()
	if err != nil {
		return err
	}
	if info.Size() > 2*ledgerCap {
		return errLedgerCorrupt
	}
	data := make([]byte, info.Size()-l.offset)
	if _, err := l.log.ReadAt(data, l.offset); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	state, imported := l.state, l.imported
	if len(data) > 0 && l.offset > 0 {
		state = state.clone()
	}
	position := 0
	torn := false
	for position < len(data) {
		rest := data[position:]
		if len(rest) < ledgerFrameHeader || !bytes.Equal(rest[:4], ledgerMagic) {
			if len(rest) >= ledgerFrameHeader && !bytes.Equal(rest, make([]byte, len(rest))) {
				return errLedgerCorrupt
			}
			torn = true
			break
		}
		size := int(binary.BigEndian.Uint32(rest[4:]))
		if size > len(rest)-ledgerFrameHeader {
			torn = true
			break
		}
		payload := rest[ledgerFrameHeader : ledgerFrameHeader+size]
		if crc32.Checksum(payload, ledgerCRC) != binary.BigEndian.Uint32(rest[8:]) {
			if ledgerFrameHeader+size != len(rest) {
				return errLedgerCorrupt
			}
			torn = true
			break
		}
		first := l.offset == 0 && position == 0
		if state, imported, err = applyLedgerFrame(state, imported, payload, first); err != nil {
			return err
		}
		position += ledgerFrameHeader + size
	}
	if l.offset == 0 && position == 0 {
		return errLedgerCorrupt // the snapshot is written whole, by rename
	}
	if torn && writer {
		if err := l.log.Truncate(l.offset + int64(position)); err != nil {
			return err
		}
		if err := ledgerSync(l.log); err != nil {
			return err
		}
	}
	l.state, l.imported = state, imported
	l.offset += int64(position)
	return nil
}

func applyLedgerFrame(state *ledgerState, imported *LedgerImport, payload []byte, first bool) (*ledgerState, *LedgerImport, error) {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var frame ledgerFrame
	if err := decoder.Decode(&frame); err != nil || decoder.More() || frame.V != 1 {
		return nil, nil, errLedgerCorrupt
	}
	if first {
		if frame.Kind != "snapshot" || frame.Import == nil || frame.Ops != nil {
			return nil, nil, errLedgerCorrupt
		}
		state = newLedgerState()
		if frame.Settings != nil {
			state.HasSettings, state.SettingsID, state.SettingsValue = true, frame.Settings.OperationID, frame.Settings.Value
		}
		for _, change := range frame.Changes {
			if err := state.insertChange(change.ID, change.Value); err != nil {
				return nil, nil, errLedgerCorrupt
			}
		}
		for _, row := range frame.Operations {
			if err := state.insertOperation(row); err != nil {
				return nil, nil, errLedgerCorrupt
			}
		}
		return state, frame.Import, nil
	}
	if frame.Kind != "commit" || len(frame.Ops) == 0 || frame.Import != nil || frame.Settings != nil ||
		frame.Changes != nil || frame.Operations != nil {
		return nil, nil, errLedgerCorrupt
	}
	for _, op := range frame.Ops {
		if _, err := state.apply(op); err != nil {
			return nil, nil, errLedgerCorrupt
		}
	}
	return state, imported, nil
}

// Import reports how the ledger was created.
func (l *Ledger) Import() LedgerImport { return *l.imported }

func (l *Ledger) Begin() error {
	if l.inTx {
		return errors.New("cannot start a transaction within a transaction")
	}
	if err := l.lockExclusive(); err != nil {
		return err
	}
	if err := l.checkPoisoned(); err != nil {
		l.unlock()
		return err
	}
	if err := l.refresh(true); err != nil {
		l.unlock()
		return err
	}
	l.saved, l.pending, l.inTx = l.state.clone(), nil, true
	return nil
}

func (l *Ledger) end() {
	l.saved, l.pending, l.inTx = nil, nil, false
	l.unlock()
}

// Commit makes the transaction durable, or leaves the ledger as at Begin.
func (l *Ledger) Commit() error {
	if !l.inTx {
		return errors.New("no transaction is active")
	}
	defer l.end()
	if len(l.pending) == 0 {
		return nil
	}
	frame, err := encodeLedgerFrame(ledgerFrame{V: 1, Kind: "commit", Ops: l.pending})
	if err != nil {
		l.state = l.saved
		return err
	}
	// Readers wait from here until the frame is durable or gone again.
	if err := l.flock(l.gate, syscall.LOCK_EX); err != nil {
		l.state = l.saved
		return err
	}
	defer syscall.Flock(int(l.gate.Fd()), syscall.LOCK_UN)
	if l.offset+int64(len(frame)) > ledgerCap {
		if err := l.writeSnapshot(l.state, l.imported); err != nil {
			var unknown *errLedgerDurabilityUnknown
			if !errors.As(err, &unknown) {
				l.state = l.saved
			} // else the snapshot is in place: this state is the log's
			return err
		}
		return nil
	}
	_, err = l.log.WriteAt(frame, l.offset)
	if err == nil {
		err = ledgerSync(l.log)
	}
	if err != nil {
		// Leave no partial frame behind. Readers wait on the gate, so none
		// has seen this frame; this ledger rereads. A frame that cannot be
		// removed for certain poisons the ledger before the gate opens.
		removed := ledgerTruncate(l.log, l.offset)
		if removed == nil {
			removed = ledgerSync(l.log)
		}
		l.state, l.stale = l.saved, true
		if removed != nil {
			return l.poison(err)
		}
		return err
	}
	l.offset += int64(len(frame))
	return nil
}

func (l *Ledger) Rollback() error {
	if !l.inTx {
		return errors.New("no transaction is active")
	}
	l.state = l.saved
	l.end()
	return nil
}

func (l *Ledger) InTransaction() bool { return l.inTx }

// write applies one write inside the transaction; it reaches the log at Commit.
func (l *Ledger) write(op ledgerOp) error {
	if !l.inTx {
		return errLedgerNoWriter
	}
	texts := []string{op.ID, op.Value, op.State}
	if op.Result != nil {
		texts = append(texts, *op.Result)
	}
	if op.Row != nil {
		texts = append(texts, op.Row.ID, op.Row.Fingerprint, op.Row.SettingsDigest, op.Row.State, op.Row.Day, op.Row.Month,
			op.Row.AccountID, op.Row.BillingGroup, op.Row.Purpose, op.Row.RequestID)
		if op.Row.Result != nil {
			texts = append(texts, *op.Row.Result)
		}
	}
	for _, text := range texts {
		if !utf8.ValidString(text) {
			return errors.New("text ledger values must be UTF-8")
		}
	}
	changed, err := l.state.apply(op)
	if err != nil {
		return err
	}
	if changed {
		l.pending = append(l.pending, op)
	}
	return nil
}

// InitSettings is open_journal's INSERT OR IGNORE, in its own transaction
// when none is active.
func (l *Ledger) InitSettings(value string) error {
	if l.inTx {
		return l.write(ledgerOp{Op: "settings_init", Value: value})
	}
	if err := l.refreshCommitted(); err != nil {
		return err
	}
	if l.state.HasSettings {
		return nil
	}
	if err := l.Begin(); err != nil {
		return err
	}
	if err := l.write(ledgerOp{Op: "settings_init", Value: value}); err != nil {
		l.Rollback()
		return err
	}
	return l.Commit()
}

func (l *Ledger) current() (*ledgerState, error) {
	if !l.inTx {
		if err := l.refreshCommitted(); err != nil {
			return nil, err
		}
	}
	return l.state, nil
}

// refreshCommitted is a read outside a transaction: holding the gate shared,
// no writer is between appending a frame and its fsync (or the truncation of
// a frame whose fsync failed), so every frame read has committed.
func (l *Ledger) refreshCommitted() error {
	if err := l.flock(l.gate, syscall.LOCK_SH); err != nil {
		return err
	}
	defer syscall.Flock(int(l.gate.Fd()), syscall.LOCK_UN)
	if err := l.checkPoisoned(); err != nil {
		return err
	}
	return l.refresh(false)
}

func (l *Ledger) Settings() (string, string, bool, error) {
	state, err := l.current()
	if err != nil {
		return "", "", false, err
	}
	return state.SettingsID, state.SettingsValue, state.HasSettings, nil
}

func (l *Ledger) UpdateSettings(operationID, value string) error {
	return l.write(ledgerOp{Op: "settings", ID: operationID, Value: value})
}

func (l *Ledger) ConfigurationChange(id string) (string, bool, error) {
	state, err := l.current()
	if err != nil {
		return "", false, err
	}
	if i, ok := state.changes[id]; ok {
		return state.Changes[i].Value, true, nil
	}
	return "", false, nil
}

func (l *Ledger) InsertConfigurationChange(id, value string) error {
	return l.write(ledgerOp{Op: "change", ID: id, Value: value})
}

func (l *Ledger) Operations() ([]Operation, error) {
	state, err := l.current()
	if err != nil {
		return nil, err
	}
	return append([]Operation(nil), state.Rows...), nil
}

func (l *Ledger) InsertOperation(row Operation) error {
	return l.write(ledgerOp{Op: "insert", Row: &row})
}

func (l *Ledger) FinishOperation(id, state string, charged int64, result string) error {
	return l.write(ledgerOp{Op: "finish", ID: id, State: state, Charged: charged, Result: &result})
}

func (l *Ledger) AbandonOperation(id string) error {
	return l.write(ledgerOp{Op: "abandon", ID: id})
}

func (l *Ledger) Close() error {
	if l.inTx {
		l.Rollback()
	}
	if l.log != nil {
		l.log.Close()
	}
	l.legacy.release()
	l.legacy = nil
	if l.gate != nil {
		l.gate.Close()
	}
	return l.lock.Close()
}

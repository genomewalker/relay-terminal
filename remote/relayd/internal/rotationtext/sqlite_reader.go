package rotationtext

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

// A read-only reader for the legacy journal, rotation-text/operations.sqlite3,
// written by text_backend.py through Python's sqlite3 module. It reads
// only what the one-time ledger import needs: the file header, table b-trees
// with overflow chains, records, and the schema table. It never writes the
// database or its rollback journal: it takes sqlite's own SHARED lock (POSIX
// advisory locks, which do not modify the file) and applies a hot rollback
// journal in memory, as sqlite would before reading.

const (
	sqlitePendingByte  = 0x40000000
	sqliteReservedByte = sqlitePendingByte + 1
	sqliteSharedFirst  = sqlitePendingByte + 2
	sqliteSharedSize   = 510
	// open_journal caps the database at 16384 pages; leave room for a larger
	// page size but never read an unbounded file into memory.
	sqliteMaxFile = 256 << 20
)

var (
	sqliteMagic        = []byte("SQLite format 3\x00")
	sqliteJournalMagic = []byte{0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7}
	errSQLiteFormat    = errors.New("legacy journal is not a readable sqlite database")
	errSQLiteLocked    = errors.New("legacy journal is locked")
)

// legacyImport is the legacy journal's state and how it was read.
type legacyImport struct {
	state            *ledgerState
	sha256           string
	rolledBackSHA256 string
	size, mtime      int64
	hotJournalPages  int
}

// legacyBytes reads the whole legacy journal by position.
func legacyBytes(file *os.File) ([]byte, os.FileInfo, error) {
	info, err := file.Stat()
	if err != nil {
		return nil, nil, err
	}
	if info.Size() > sqliteMaxFile {
		return nil, nil, errSQLiteFormat
	}
	data := make([]byte, info.Size())
	if _, err := io.ReadFull(io.NewSectionReader(file, 0, info.Size()), data); err != nil {
		return nil, nil, err
	}
	return data, info, nil
}

func bytesSHA256(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

type sqliteDB struct {
	pages    [][]byte // 1-based page n is pages[n-1]
	pageSize int
	usable   int
}

type sqliteValue struct {
	kind byte // 'n' null, 'i' integer, 'f' real, 't' text, 'b' blob
	i    int64
	s    string
}

// readLegacyJournal reads path under a SHARED lock. A hot rollback journal is
// applied in memory; a write-ahead log is refused (the backend never used WAL).
func readLegacyJournal(path string, timeout time.Duration) (*legacyImport, error) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	if err := sqliteSharedLock(context.Background(), file, timeout); err != nil {
		return nil, err
	}
	// Closing the file releases the process's POSIX locks on it.
	return readLegacyFile(file, path)
}

// readLegacyFile reads the legacy journal through file, on which the caller
// holds SHARED. It reads by position only, so a descriptor shared by several
// ledgers of this process (legacyHold) is safe to use.
func readLegacyFile(file *os.File, path string) (*legacyImport, error) {
	data, info, err := legacyBytes(file)
	if err != nil {
		return nil, err
	}
	result := &legacyImport{sha256: bytesSHA256(data), size: info.Size(), mtime: info.ModTime().UnixNano()}
	if wal, err := os.Lstat(path + "-wal"); err == nil && wal.Size() > 0 {
		return nil, errors.New("legacy journal has a write-ahead log")
	}
	var overlay map[uint32][]byte
	var truncate int
	if hot, err := sqliteHotJournal(file, path+"-journal"); err != nil {
		return nil, err
	} else if hot != nil {
		pageSize := sqliteHeaderPageSize(data)
		if pageSize == 0 {
			// Page 1 itself may be the page the journal restores.
			pageSize = sqliteJournalPageSize(hot)
		}
		if overlay, truncate, err = sqliteJournalPages(hot, pageSize); err != nil {
			return nil, err
		}
		result.hotJournalPages = len(overlay)
	}
	if len(data) == 0 && overlay == nil {
		// Created by open_journal but never initialised: no tables yet.
		result.state = newLedgerState()
		return result, nil
	}
	db, err := openSQLiteImage(data, overlay, truncate)
	if err != nil {
		return nil, err
	}
	if overlay != nil {
		// What sqlite's own rollback of this journal leaves in the file.
		result.rolledBackSHA256 = bytesSHA256(bytes.Join(db.pages, nil))
	}
	if result.state, err = db.ledgerState(); err != nil {
		return nil, err
	}
	return result, nil
}

// sqliteSharedLock acquires sqlite's SHARED lock the way the unix VFS does:
// a read lock on PENDING (excludes a writer that is committing), a read lock
// on the shared range, then PENDING is released. It waits at most timeout, and
// not past ctx.
func sqliteSharedLock(ctx context.Context, file *os.File, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		pending := syscall.Flock_t{Type: syscall.F_RDLCK, Whence: io.SeekStart, Start: sqlitePendingByte, Len: 1}
		if err := syscall.FcntlFlock(file.Fd(), syscall.F_SETLK, &pending); err == nil {
			shared := syscall.Flock_t{Type: syscall.F_RDLCK, Whence: io.SeekStart, Start: sqliteSharedFirst, Len: sqliteSharedSize}
			sharedErr := syscall.FcntlFlock(file.Fd(), syscall.F_SETLK, &shared)
			release := syscall.Flock_t{Type: syscall.F_UNLCK, Whence: io.SeekStart, Start: sqlitePendingByte, Len: 1}
			if err := syscall.FcntlFlock(file.Fd(), syscall.F_SETLK, &release); err != nil {
				return err
			}
			if sharedErr == nil {
				return nil
			}
		} else if !errors.Is(err, syscall.EAGAIN) && !errors.Is(err, syscall.EACCES) && !errors.Is(err, syscall.EINTR) {
			return err
		}
		if time.Now().After(deadline) {
			return errSQLiteLocked
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// sqliteHotJournal returns the rollback journal's bytes when sqlite would treat
// it as hot: present, non-empty, not zeroed, and no process holds RESERVED.
func sqliteHotJournal(db *os.File, path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if err := safeJournalInfo(info, false); err != nil {
		return nil, err
	}
	if info.Size() == 0 {
		return nil, nil
	}
	reserved := syscall.Flock_t{Type: syscall.F_WRLCK, Whence: io.SeekStart, Start: sqliteReservedByte, Len: 1}
	if err := syscall.FcntlFlock(db.Fd(), syscall.F_GETLK, &reserved); err != nil {
		return nil, err
	}
	if reserved.Type != syscall.F_UNLCK {
		// A live writer owns this journal; the database file is still
		// consistent while we hold SHARED (it cannot reach EXCLUSIVE).
		return nil, nil
	}
	if info.Size() > sqliteMaxFile {
		return nil, errSQLiteFormat
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, sqliteMaxFile))
	if err != nil {
		return nil, err
	}
	if len(data) == 0 || data[0] == 0 {
		return nil, nil
	}
	return data, nil
}

func sqliteHeaderPageSize(data []byte) int {
	if len(data) < 100 || !bytes.Equal(data[:16], sqliteMagic) {
		return 0
	}
	return sqlitePageSize(binary.BigEndian.Uint16(data[16:18]))
}

func sqlitePageSize(raw uint16) int {
	size := int(raw)
	if raw == 1 {
		size = 65536
	}
	if size < 512 || size > 65536 || size&(size-1) != 0 {
		return 0
	}
	return size
}

func sqliteJournalPageSize(journal []byte) int {
	if len(journal) < 28 {
		return 0
	}
	// Rollback journals store the actual uint32 size. Only the database's
	// uint16 header uses 1 as the sentinel for 65536-byte pages.
	size := binary.BigEndian.Uint32(journal[24:28])
	if size < 512 || size > 65536 || size&(size-1) != 0 {
		return 0
	}
	return int(size)
}

// sqliteJournalPages plays a hot rollback journal back into page images, as
// pager_playback does: each segment header gives a record count (0xffffffff:
// to end of file), records are (page number, page, checksum), and the first
// header's original database size truncates the file. Playback stops at the
// first incomplete or mis-checksummed record, as sqlite's does.
func sqliteJournalPages(journal []byte, pageSize int) (map[uint32][]byte, int, error) {
	if pageSize == 0 {
		return nil, 0, errSQLiteFormat
	}
	pages := map[uint32][]byte{}
	truncate := -1
	offset := 0
	for offset+28 <= len(journal) && bytes.Equal(journal[offset:offset+8], sqliteJournalMagic) {
		records := binary.BigEndian.Uint32(journal[offset+8:])
		nonce := binary.BigEndian.Uint32(journal[offset+12:])
		original := binary.BigEndian.Uint32(journal[offset+16:])
		sector := int(binary.BigEndian.Uint32(journal[offset+20:]))
		if size := sqliteJournalPageSize(journal[offset:]); size != pageSize {
			return nil, 0, errSQLiteFormat
		}
		if sector < 512 || sector > 65536 || sector&(sector-1) != 0 {
			return nil, 0, errSQLiteFormat
		}
		if truncate < 0 {
			truncate = int(original)
		}
		offset += sector
		record := pageSize + 8
		if records == 0xffffffff {
			if offset > len(journal) {
				break
			}
			records = uint32((len(journal) - offset) / record)
		}
		for n := uint32(0); n < records; n++ {
			if offset+record > len(journal) {
				return pages, truncate, nil
			}
			pgno := binary.BigEndian.Uint32(journal[offset:])
			page := journal[offset+4 : offset+4+pageSize]
			sum := nonce
			for i := pageSize - 200; i > 0; i -= 200 {
				sum += uint32(page[i])
			}
			if pgno == 0 || sum != binary.BigEndian.Uint32(journal[offset+4+pageSize:]) {
				return pages, truncate, nil
			}
			if _, seen := pages[pgno]; !seen {
				pages[pgno] = append([]byte(nil), page...)
			}
			offset += record
		}
		// The next segment header starts on a sector boundary.
		offset = (offset + sector - 1) / sector * sector
	}
	if truncate < 0 {
		return nil, 0, nil
	}
	return pages, truncate, nil
}

func openSQLiteImage(data []byte, overlay map[uint32][]byte, truncate int) (*sqliteDB, error) {
	pageSize := sqliteHeaderPageSize(data)
	if first, ok := overlay[1]; ok {
		pageSize = sqliteHeaderPageSize(first)
	}
	if pageSize == 0 {
		return nil, errSQLiteFormat
	}
	count := len(data) / pageSize
	if overlay != nil {
		count = truncate
		for pgno := range overlay {
			if int(pgno) > count {
				// Pages beyond the original size were added by the
				// interrupted transaction and are dropped.
				delete(overlay, pgno)
			}
		}
	}
	if count < 1 || count > sqliteMaxFile/pageSize {
		return nil, errSQLiteFormat
	}
	db := &sqliteDB{pages: make([][]byte, count), pageSize: pageSize}
	for i := range db.pages {
		if page, ok := overlay[uint32(i+1)]; ok {
			db.pages[i] = page
		} else if (i+1)*pageSize <= len(data) {
			db.pages[i] = data[i*pageSize : (i+1)*pageSize]
		} else {
			return nil, errSQLiteFormat
		}
	}
	header := db.pages[0]
	if !bytes.Equal(header[:16], sqliteMagic) || header[18] > 2 || header[19] > 2 || header[21] != 64 || header[22] != 32 ||
		header[23] != 32 {
		return nil, errSQLiteFormat
	}
	if encoding := binary.BigEndian.Uint32(header[56:60]); encoding != 0 && encoding != 1 {
		return nil, errors.New("legacy journal is not UTF-8")
	}
	db.usable = pageSize - int(header[20])
	if db.usable < 480 {
		return nil, errSQLiteFormat
	}
	return db, nil
}

func (db *sqliteDB) page(n uint32) ([]byte, int, error) {
	if n < 1 || int(n) > len(db.pages) {
		return nil, 0, errSQLiteFormat
	}
	header := 0
	if n == 1 {
		header = 100
	}
	return db.pages[n-1], header, nil
}

// tableRows visits a table b-tree's rows in rowid order.
func (db *sqliteDB) tableRows(root uint32, visit func(rowid int64, payload []byte) error) error {
	seen := map[uint32]bool{}
	var walk func(pgno uint32, depth int) error
	walk = func(pgno uint32, depth int) error {
		if depth > 32 || seen[pgno] {
			return errSQLiteFormat
		}
		seen[pgno] = true
		page, at, err := db.page(pgno)
		if err != nil {
			return err
		}
		kind := page[at]
		cells := int(binary.BigEndian.Uint16(page[at+3:]))
		pointers := at + 8
		if kind == 0x05 {
			pointers = at + 12
		} else if kind != 0x0d {
			return errSQLiteFormat
		}
		if pointers+2*cells > db.usable {
			return errSQLiteFormat
		}
		for i := 0; i < cells; i++ {
			cell := int(binary.BigEndian.Uint16(page[pointers+2*i:]))
			if cell < pointers+2*cells || cell >= db.usable {
				return errSQLiteFormat
			}
			if kind == 0x05 {
				if cell+4 > db.usable {
					return errSQLiteFormat
				}
				if err := walk(binary.BigEndian.Uint32(page[cell:]), depth+1); err != nil {
					return err
				}
				continue
			}
			size, n := sqliteVarint(page[cell:db.usable])
			if n == 0 || size < 0 {
				return errSQLiteFormat
			}
			rowid, m := sqliteVarint(page[cell+n : db.usable])
			if m == 0 {
				return errSQLiteFormat
			}
			payload, err := db.payload(page, cell+n+m, size)
			if err != nil {
				return err
			}
			if err := visit(rowid, payload); err != nil {
				return err
			}
		}
		if kind == 0x05 {
			return walk(binary.BigEndian.Uint32(page[at+8:]), depth+1)
		}
		return nil
	}
	return walk(root, 0)
}

// payload assembles a table leaf cell's payload with its overflow chain.
func (db *sqliteDB) payload(page []byte, at int, size int64) ([]byte, error) {
	if size > sqliteMaxFile {
		return nil, errSQLiteFormat
	}
	u := int64(db.usable)
	x := u - 35
	local := size
	if size > x {
		m := (u-12)*32/255 - 23
		k := m + (size-m)%(u-4)
		local = m
		if k <= x {
			local = k
		}
	}
	if int64(at)+local > u {
		return nil, errSQLiteFormat
	}
	out := make([]byte, 0, size)
	out = append(out, page[at:at+int(local)]...)
	if local == size {
		return out, nil
	}
	if int64(at)+local+4 > u {
		return nil, errSQLiteFormat
	}
	next := binary.BigEndian.Uint32(page[at+int(local):])
	for hops := 0; int64(len(out)) < size; hops++ {
		if hops > len(db.pages) {
			return nil, errSQLiteFormat
		}
		overflow, _, err := db.page(next)
		if err != nil {
			return nil, err
		}
		chunk := min(u-4, size-int64(len(out)))
		out = append(out, overflow[4:4+chunk]...)
		next = binary.BigEndian.Uint32(overflow)
	}
	return out, nil
}

// sqliteVarint decodes sqlite's big-endian varint; n is 0 when truncated.
func sqliteVarint(b []byte) (value int64, n int) {
	var v uint64
	for i := 0; i < 9; i++ {
		if i >= len(b) {
			return 0, 0
		}
		if i == 8 {
			return int64(v<<8 | uint64(b[i])), 9
		}
		v = v<<7 | uint64(b[i]&0x7f)
		if b[i]&0x80 == 0 {
			return int64(v), i + 1
		}
	}
	return 0, 0
}

func decodeSQLiteRecord(payload []byte) ([]sqliteValue, error) {
	headerSize, n := sqliteVarint(payload)
	if n == 0 || headerSize < int64(n) || headerSize > int64(len(payload)) {
		return nil, errSQLiteFormat
	}
	types := []int64{}
	for at := n; at < int(headerSize); {
		serial, m := sqliteVarint(payload[at:headerSize])
		if m == 0 {
			return nil, errSQLiteFormat
		}
		types = append(types, serial)
		at += m
	}
	values := make([]sqliteValue, 0, len(types))
	body := payload[headerSize:]
	for _, serial := range types {
		var size int64
		switch {
		case serial == 0, serial == 8, serial == 9:
		case serial >= 1 && serial <= 4:
			size = serial
		case serial == 5:
			size = 6
		case serial == 6, serial == 7:
			size = 8
		case serial >= 12:
			size = (serial - 12) / 2
		default:
			return nil, errSQLiteFormat
		}
		if size > int64(len(body)) {
			return nil, errSQLiteFormat
		}
		field := body[:size]
		body = body[size:]
		switch {
		case serial == 0:
			values = append(values, sqliteValue{kind: 'n'})
		case serial == 8 || serial == 9:
			values = append(values, sqliteValue{kind: 'i', i: serial - 8})
		case serial <= 6:
			v := int64(int8(field[0]))
			for _, b := range field[1:] {
				v = v<<8 | int64(b)
			}
			values = append(values, sqliteValue{kind: 'i', i: v})
		case serial == 7:
			values = append(values, sqliteValue{kind: 'f'}) // never written by the journal
		case serial%2 == 1:
			values = append(values, sqliteValue{kind: 't', s: string(field)})
		default:
			values = append(values, sqliteValue{kind: 'b', s: string(field)})
		}
	}
	return values, nil
}

// sqliteColumns lists the column names of a CREATE TABLE statement, as sqlite
// stores it (ALTER TABLE ADD COLUMN appends to the stored text).
func sqliteColumns(sql string) ([]string, error) {
	open, close := strings.IndexByte(sql, '('), strings.LastIndexByte(sql, ')')
	if open < 0 || close < open {
		return nil, errSQLiteFormat
	}
	definitions := []string{}
	depth, start := 0, open+1
	var quote byte
	for i := open + 1; i < close; i++ {
		c := sql[i]
		switch {
		case quote != 0:
			if c == quote {
				quote = 0
			}
		case c == '\'' || c == '"' || c == '`':
			quote = c
		case c == '[':
			quote = ']'
		case c == '(':
			depth++
		case c == ')':
			depth--
		case c == ',' && depth == 0:
			definitions = append(definitions, sql[start:i])
			start = i + 1
		}
	}
	definitions = append(definitions, sql[start:close])
	columns := []string{}
	for _, definition := range definitions {
		name, quoted := sqliteIdentifier(strings.TrimSpace(definition))
		if name == "" {
			return nil, errSQLiteFormat
		}
		if !quoted {
			switch strings.ToUpper(name) {
			case "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN":
				continue
			}
		}
		columns = append(columns, name)
	}
	return columns, nil
}

// sqliteIdentifier reads the leading identifier: quoted ("", “, []), or bare
// up to whitespace or a parenthesis.
func sqliteIdentifier(text string) (string, bool) {
	if text == "" {
		return "", false
	}
	if end := map[byte]byte{'"': '"', '`': '`', '[': ']', '\'': '\''}[text[0]]; end != 0 {
		if close := strings.IndexByte(text[1:], end); close >= 0 {
			return text[1 : 1+close], true
		}
		return "", false
	}
	if stop := strings.IndexAny(text, " \t\r\n("); stop >= 0 {
		return text[:stop], false
	}
	return text, false
}

type sqliteTable struct {
	root    uint32
	columns []string
}

func (db *sqliteDB) schema() (map[string]sqliteTable, error) {
	tables := map[string]sqliteTable{}
	err := db.tableRows(1, func(_ int64, payload []byte) error {
		values, err := decodeSQLiteRecord(payload)
		if err != nil {
			return err
		}
		if len(values) < 5 || values[0].kind != 't' || values[1].kind != 't' {
			return errSQLiteFormat
		}
		if values[0].s != "table" {
			return nil
		}
		if values[3].kind != 'i' || values[3].i < 1 || values[3].i > math.MaxUint32 || values[4].kind != 't' {
			return errSQLiteFormat
		}
		columns, err := sqliteColumns(values[4].s)
		if err != nil {
			return err
		}
		tables[values[1].s] = sqliteTable{root: uint32(values[3].i), columns: columns}
		return nil
	})
	return tables, err
}

var (
	legacySettingsColumns   = []string{"singleton", "operation_id", "value"}
	legacyChangesColumns    = []string{"id", "value"}
	legacyOperationsColumns = []string{"id", "fingerprint", "settings_digest", "state", "day", "month", "reserved", "charged",
		"result"}
	// open_journal's migration adds these TEXT NOT NULL DEFAULT '' columns.
	legacyAddedColumns = []string{"account_id", "billing_group", "purpose", "request_id"}
)

// legacyRow maps one record onto the expected columns. A record shorter than
// the schema predates ALTER TABLE ADD COLUMN and takes the column default.
type legacyRow struct {
	index  map[string]int
	values []sqliteValue
}

func (r legacyRow) value(name string) sqliteValue {
	if i, ok := r.index[name]; ok && i < len(r.values) {
		return r.values[i]
	}
	return sqliteValue{kind: 'd'} // the column default
}

func (r legacyRow) text(name string, nullable bool) (*string, error) {
	value := r.value(name)
	switch {
	case value.kind == 't' && utf8.ValidString(value.s):
		return &value.s, nil
	case value.kind == 'n' && nullable:
		return nil, nil
	case value.kind == 'd' && strIn(name, legacyAddedColumns...):
		empty := ""
		return &empty, nil
	}
	return nil, fmt.Errorf("legacy journal column %s has an unexpected value", name)
}

func (r legacyRow) integer(name string) (int64, error) {
	if value := r.value(name); value.kind == 'i' {
		return value.i, nil
	}
	return 0, fmt.Errorf("legacy journal column %s has an unexpected value", name)
}

func legacyColumns(table sqliteTable, required, optional []string) (map[string]int, error) {
	index := map[string]int{}
	for i, name := range table.columns {
		if _, dup := index[name]; dup {
			return nil, errSQLiteFormat
		}
		index[name] = i
	}
	for _, name := range required {
		if _, ok := index[name]; !ok {
			return nil, fmt.Errorf("legacy journal lacks column %s", name)
		}
	}
	for name := range index {
		if !strIn(name, append(append([]string{}, required...), optional...)...) {
			return nil, fmt.Errorf("legacy journal has unknown column %s", name)
		}
	}
	return index, nil
}

// ledgerState reads the three journal tables. A database without them (open
// and never written) is an empty journal, as open_journal would create.
func (db *sqliteDB) ledgerState() (*ledgerState, error) {
	tables, err := db.schema()
	if err != nil {
		return nil, err
	}
	state := newLedgerState()
	if table, ok := tables["settings"]; ok {
		index, err := legacyColumns(table, legacySettingsColumns, nil)
		if err != nil {
			return nil, err
		}
		err = db.tableRows(table.root, func(rowid int64, payload []byte) error {
			values, err := decodeSQLiteRecord(payload)
			if err != nil {
				return err
			}
			row := legacyRow{index, values}
			// singleton is INTEGER PRIMARY KEY: the rowid, stored as NULL.
			if rowid != 1 || state.HasSettings || row.value("singleton").kind != 'n' {
				return errors.New("legacy journal settings are not a singleton")
			}
			id, err := row.text("operation_id", false)
			if err != nil {
				return err
			}
			value, err := row.text("value", false)
			if err != nil {
				return err
			}
			state.HasSettings, state.SettingsID, state.SettingsValue = true, *id, *value
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	if table, ok := tables["configuration_changes"]; ok {
		index, err := legacyColumns(table, legacyChangesColumns, nil)
		if err != nil {
			return nil, err
		}
		err = db.tableRows(table.root, func(_ int64, payload []byte) error {
			values, err := decodeSQLiteRecord(payload)
			if err != nil {
				return err
			}
			row := legacyRow{index, values}
			id, err := row.text("id", false)
			if err != nil {
				return err
			}
			value, err := row.text("value", false)
			if err != nil {
				return err
			}
			return state.insertChange(*id, *value)
		})
		if err != nil {
			return nil, err
		}
	}
	if table, ok := tables["operations"]; ok {
		index, err := legacyColumns(table, legacyOperationsColumns, legacyAddedColumns)
		if err != nil {
			return nil, err
		}
		last := int64(math.MinInt64)
		err = db.tableRows(table.root, func(rowid int64, payload []byte) error {
			if rowid <= last {
				return errSQLiteFormat
			}
			last = rowid
			values, err := decodeSQLiteRecord(payload)
			if err != nil {
				return err
			}
			row := legacyRow{index, values}
			var operation Operation
			texts := []struct {
				name     string
				target   *string
				nullable bool
			}{{"id", &operation.ID, false}, {"fingerprint", &operation.Fingerprint, false},
				{"settings_digest", &operation.SettingsDigest, false}, {"state", &operation.State, false},
				{"day", &operation.Day, false}, {"month", &operation.Month, false},
				{"account_id", &operation.AccountID, false}, {"billing_group", &operation.BillingGroup, false},
				{"purpose", &operation.Purpose, false}, {"request_id", &operation.RequestID, false}}
			for _, field := range texts {
				value, err := row.text(field.name, field.nullable)
				if err != nil {
					return err
				}
				*field.target = *value
			}
			if operation.Result, err = row.text("result", true); err != nil {
				return err
			}
			if operation.Reserved, err = row.integer("reserved"); err != nil {
				return err
			}
			if operation.Charged, err = row.integer("charged"); err != nil {
				return err
			}
			return state.insertOperation(operation)
		})
		if err != nil {
			return nil, err
		}
	}
	return state, nil
}

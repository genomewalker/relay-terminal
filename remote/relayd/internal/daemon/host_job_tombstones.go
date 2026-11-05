package daemon

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// A tombstone keeps a deleted archive folder's job ID reserved. It is the
// final state a status read reports once the output itself is gone.
type hostJobTombstone struct {
	JobID       string `json:"job_id"`
	Fingerprint string `json:"fingerprint"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
	State       string `json:"state"`
	ExitCode    *int   `json:"exit_code,omitempty"`
}

func (t hostJobTombstone) record() hostJobRecord {
	return hostJobRecord{JobID: t.JobID, Fingerprint: t.Fingerprint, State: t.State, ExitCode: t.ExitCode,
		CreatedAt: t.CreatedAt, UpdatedAt: t.UpdatedAt}
}

const hostJobTombstoneDirName = "host-jobs-tombstones"

// errHostJobTombstoneUnreadable means a tombstone may name the ID but could
// not be read back. The ID is treated as reserved.
var errHostJobTombstoneUnreadable = errors.New("reserved host job has an unreadable tombstone; do not replay")

// Tests replace it to fail a tombstone file sync.
var hostJobTombstoneSync = func(file *os.File) error { return file.Sync() }

// syncHostJobTombstones makes every tombstone file, and the directory chain
// that names them, durable. A line that is readable is not proof that it was
// ever synced (an earlier run may have failed at its fsync), so every run
// does this before it deletes anything a tombstone stands in for.
func syncHostJobTombstones(stateDir string) error {
	directory := hostJobTombstoneDir(stateDir)
	if err := durableDirectory(directory); err != nil {
		return err
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".jsonl") || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		file, err := os.OpenFile(filepath.Join(directory, entry.Name()), os.O_RDWR|syscall.O_NOFOLLOW, 0)
		if err != nil {
			return err
		}
		err = hostJobTombstoneSync(file)
		file.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func hostJobTombstoneDir(stateDir string) string {
	return filepath.Join(stateDir, hostJobTombstoneDirName)
}

// lockHostJobLedger takes the cross-process lock that serializes archive
// moves and archive cleanup in every relayd process sharing stateDir. With
// wait zero it fails at once when another process holds it.
func lockHostJobLedger(stateDir string, wait time.Duration) (func(), error) {
	directory := hostJobTombstoneDir(stateDir)
	if err := durableDirectory(directory); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(directory, "lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(wait)
	for {
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() { _ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN); file.Close() }, nil
		}
		if err != syscall.EWOULDBLOCK || !time.Now().Before(deadline) {
			file.Close()
			if err == syscall.EWOULDBLOCK {
				return nil, errors.New("host job ledger is busy")
			}
			return nil, err
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// appendHostJobTombstones durably appends one line per tombstone to this
// month's file. It returns only after the data is fsynced, and the directory
// too when the file is new. A torn last line from an earlier crash is ended
// first, so it can never swallow the next line. The caller holds the ledger lock.
func appendHostJobTombstones(stateDir string, tombstones []hostJobTombstone, now time.Time) error {
	if len(tombstones) == 0 {
		return nil
	}
	directory := hostJobTombstoneDir(stateDir)
	if err := durableDirectory(directory); err != nil {
		return err
	}
	path := filepath.Join(directory, now.UTC().Format("2006-01")+".jsonl")
	_, statErr := os.Lstat(path)
	created := os.IsNotExist(statErr)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|os.O_APPEND|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("host job tombstone index is not a regular file")
	}
	var buffer bytes.Buffer
	if info.Size() > 0 {
		last := make([]byte, 1)
		if _, err := file.ReadAt(last, info.Size()-1); err != nil {
			return err
		}
		if last[0] != '\n' {
			buffer.WriteByte('\n')
		}
	}
	for _, tombstone := range tombstones {
		raw, err := json.Marshal(tombstone)
		if err != nil {
			return err
		}
		buffer.Write(raw)
		buffer.WriteByte('\n')
	}
	if _, err := file.Write(buffer.Bytes()); err != nil {
		return err
	}
	if err := hostJobTombstoneSync(file); err != nil {
		return err
	}
	if created {
		return syncDirectory(directory)
	}
	return nil
}

// hostJobTombstoneIndex finds a tombstoned ID without holding the IDs: a
// sorted slice of 64-bit ID hashes and line locations, 16 bytes per
// tombstone, plus a small unsorted set of recent additions. A hash hit reads
// that one line back and compares the ID. A miss rescans only data appended
// since the last scan, so tombstones written by another relayd process (the
// gc-host-jobs command) are seen before their folders could be missed.
type hostJobTombstoneIndex struct {
	mu      sync.Mutex
	dir     string
	loaded  bool
	files   []string         // tombstone file names; a location's file number indexes this
	scanned map[string]int64 // bytes consumed per file, always at a line end
	sorted  []hostJobTombstoneSlot
	recent  map[uint64][]uint64
}

type hostJobTombstoneSlot struct{ hash, location uint64 }

const hostJobTombstoneRecentLimit = 8192

func newHostJobTombstoneIndex(stateDir string) *hostJobTombstoneIndex {
	return &hostJobTombstoneIndex{dir: hostJobTombstoneDir(stateDir), scanned: map[string]int64{}, recent: map[uint64][]uint64{}}
}

func hostJobTombstoneHash(id string) uint64 {
	hash := fnv.New64a()
	hash.Write([]byte(id))
	return hash.Sum64()
}

// A location packs the file number above a 40-bit byte offset.
func hostJobTombstoneLocation(file int, offset int64) uint64 {
	return uint64(file)<<40 | uint64(offset)
}

// Load reads every tombstone file. It is also done lazily on first lookup.
func (index *hostJobTombstoneIndex) Load() error {
	index.mu.Lock()
	defer index.mu.Unlock()
	return index.refreshLocked()
}

func (index *hostJobTombstoneIndex) Len() int {
	index.mu.Lock()
	defer index.mu.Unlock()
	count := len(index.sorted)
	for _, locations := range index.recent {
		count += len(locations)
	}
	return count
}

// refreshLocked indexes complete lines appended since the last scan.
// Unparsable lines (a torn tail) are skipped: their folders were never removed.
func (index *hostJobTombstoneIndex) refreshLocked() error {
	entries, err := os.ReadDir(index.dir)
	if os.IsNotExist(err) {
		index.loaded = true
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".jsonl") || strings.HasPrefix(name, ".") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		consumed, known := index.scanned[name]
		if known && info.Size() <= consumed {
			continue
		}
		number := -1
		for i, file := range index.files {
			if file == name {
				number = i
			}
		}
		if number < 0 {
			index.files = append(index.files, name)
			number = len(index.files) - 1
		}
		if err := index.scanLocked(name, number, consumed); err != nil {
			return err
		}
	}
	if len(index.sorted) == 0 || len(index.recent) > hostJobTombstoneRecentLimit || !index.loaded {
		index.mergeLocked()
	}
	index.loaded = true
	return nil
}

func (index *hostJobTombstoneIndex) scanLocked(name string, number int, from int64) error {
	file, err := os.Open(filepath.Join(index.dir, name))
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err := file.Seek(from, io.SeekStart); err != nil {
		return err
	}
	reader := bufio.NewReaderSize(file, 64<<10)
	offset := from
	for {
		line, err := reader.ReadSlice('\n')
		if err == bufio.ErrBufferFull {
			// No tombstone is this long: skip the whole line, if it has ended.
			length := int64(len(line))
			for err == bufio.ErrBufferFull {
				line, err = reader.ReadSlice('\n')
				length += int64(len(line))
			}
			if err != nil {
				break
			}
			offset += length
			continue
		}
		if err == io.EOF {
			break // an unterminated tail is read again once it ends
		}
		if err != nil {
			return err
		}
		var probe struct {
			JobID string `json:"job_id"`
		}
		if json.Unmarshal(line, &probe) == nil && probe.JobID != "" {
			hash := hostJobTombstoneHash(probe.JobID)
			index.recent[hash] = append(index.recent[hash], hostJobTombstoneLocation(number, offset))
		}
		offset += int64(len(line))
	}
	index.scanned[name] = offset
	return nil
}

func (index *hostJobTombstoneIndex) mergeLocked() {
	for hash, locations := range index.recent {
		for _, location := range locations {
			index.sorted = append(index.sorted, hostJobTombstoneSlot{hash, location})
		}
	}
	index.recent = map[uint64][]uint64{}
	sort.Slice(index.sorted, func(i, j int) bool { return index.sorted[i].hash < index.sorted[j].hash })
}

// Lookup returns the tombstone for id. A hit that cannot be read back is
// errHostJobTombstoneUnreadable: the ID stays reserved.
func (index *hostJobTombstoneIndex) Lookup(id string) (hostJobTombstone, bool, error) {
	index.mu.Lock()
	defer index.mu.Unlock()
	if !index.loaded {
		if err := index.refreshLocked(); err != nil {
			return hostJobTombstone{}, false, errHostJobTombstoneUnreadable
		}
	}
	tombstone, found, err := index.findLocked(id)
	if found || err != nil {
		return tombstone, found, err
	}
	if err := index.refreshLocked(); err != nil {
		return hostJobTombstone{}, false, errHostJobTombstoneUnreadable
	}
	return index.findLocked(id)
}

func (index *hostJobTombstoneIndex) findLocked(id string) (hostJobTombstone, bool, error) {
	hash := hostJobTombstoneHash(id)
	locations := append([]uint64(nil), index.recent[hash]...)
	for i := sort.Search(len(index.sorted), func(i int) bool { return index.sorted[i].hash >= hash }); i < len(index.sorted) && index.sorted[i].hash == hash; i++ {
		locations = append(locations, index.sorted[i].location)
	}
	for _, location := range locations {
		tombstone, err := index.readLocked(location)
		if err != nil {
			return hostJobTombstone{}, false, errHostJobTombstoneUnreadable
		}
		if tombstone.JobID == id {
			return tombstone, true, nil
		}
	}
	return hostJobTombstone{}, false, nil
}

func (index *hostJobTombstoneIndex) readLocked(location uint64) (hostJobTombstone, error) {
	number, offset := int(location>>40), int64(location&(1<<40-1))
	if number >= len(index.files) {
		return hostJobTombstone{}, errHostJobTombstoneUnreadable
	}
	file, err := os.Open(filepath.Join(index.dir, index.files[number]))
	if err != nil {
		return hostJobTombstone{}, err
	}
	defer file.Close()
	buffer := make([]byte, 4096)
	n, err := file.ReadAt(buffer, offset)
	if err != nil && err != io.EOF {
		return hostJobTombstone{}, err
	}
	end := bytes.IndexByte(buffer[:n], '\n')
	if end < 0 {
		return hostJobTombstone{}, errHostJobTombstoneUnreadable
	}
	var tombstone hostJobTombstone
	if err := json.Unmarshal(buffer[:end], &tombstone); err != nil {
		return hostJobTombstone{}, err
	}
	return tombstone, nil
}

// hostJobTombstoneSnapshot is the status reply for a tombstoned job: its
// original final state and exit code, with the output marked expired. The
// requested offsets are echoed so a draining client sees no further output.
func hostJobTombstoneSnapshot(tombstone hostJobTombstone, r hostRequest) (any, error) {
	if r.StdoutOffset < 0 || r.StderrOffset < 0 {
		return nil, errors.New("negative output offset")
	}
	record := tombstone.record()
	return map[string]any{"job": record, "process_state": hostJobProcessState(record), "stdout": []byte{}, "stderr": []byte{},
		"stdout_offset": r.StdoutOffset, "stderr_offset": r.StderrOffset, "output_expired": true}, nil
}

package capacity

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"unicode/utf8"
)

const MaxJSON = 256 << 10

// Decode rejects duplicate keys at every depth, unknown fields, trailing values,
// oversized/deep input and incomplete JSON. JSON numbers retain integer checks.
func Decode(data []byte, target any) error {
	if len(data) == 0 || len(data) > MaxJSON || !utf8.Valid(data) {
		return errors.New("capacity JSON bound")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 16 {
			return errors.New("capacity JSON depth")
		}
		token, err := d.Token()
		if err != nil {
			return err
		}
		if s, ok := token.(string); ok && len(s) > 8192 {
			return errors.New("capacity string bound")
		}
		delimiter, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delimiter {
		case '{':
			seen := map[string]bool{}
			for d.More() {
				key, err := d.Token()
				if err != nil {
					return err
				}
				s, ok := key.(string)
				if !ok || len(s) > 256 || seen[s] {
					return errors.New("capacity duplicate or invalid key")
				}
				seen[s] = true
				if len(seen) > 4096 {
					return errors.New("capacity key bound")
				}
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
			end, err := d.Token()
			if err != nil || end != json.Delim('}') {
				return errors.New("capacity object truncated")
			}
		case '[':
			n := 0
			for d.More() {
				n++
				if n > 4096 {
					return errors.New("capacity array bound")
				}
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
			end, err := d.Token()
			if err != nil || end != json.Delim(']') {
				return errors.New("capacity array truncated")
			}
		default:
			return errors.New("capacity unexpected delimiter")
		}
		return nil
	}
	if err := walk(0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return errors.New("capacity trailing JSON")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}
func hexDigest(s string) bool {
	b, err := hex.DecodeString(s)
	return err == nil && len(b) == 32 && s == hex.EncodeToString(b)
}
func Hash(data []byte) string { h := sha256.Sum256(data); return hex.EncodeToString(h[:]) }

type Receipt struct {
	Hash     string `json:"hash"`
	Revision uint64 `json:"revision"`
}
type Reservation struct {
	Provider  string `json:"provider"`
	Account   string `json:"account"`
	Operation string `json:"operation"`
	Pane      string `json:"pane"`
	AfterMS   int64  `json:"after_ms"`
	Pending   bool   `json:"pending"`
}
type Disk struct {
	Reservations map[string]Reservation `json:"reservations"`
	Operations   map[string]Operation   `json:"operations"`
	V            int                    `json:"v"`
	Revision     uint64                 `json:"revision"`
	Settings     Settings               `json:"settings"`
	Entries      map[string]Entry       `json:"entries"`
	Receipts     map[string]Receipt     `json:"receipts"`
}

func Empty() Disk {
	return Disk{Reservations: map[string]Reservation{}, Operations: map[string]Operation{}, V: Version, Settings: Defaults(), Entries: map[string]Entry{}, Receipts: map[string]Receipt{}}
}
func (d Disk) Valid() bool {
	if d.Reservations == nil || len(d.Reservations) > 64 || d.V != Version || !d.Settings.Valid() || d.Operations == nil || len(d.Operations) > 128 || d.Entries == nil || d.Receipts == nil || len(d.Entries) > 256 || len(d.Receipts) > 256 {
		return false
	}
	for key, r := range d.Reservations {
		operation, ok := d.Operations[r.Operation]
		if !ok || key != r.Provider+":"+r.Account || operation.Plan.Source.Provider != r.Provider || operation.Plan.Target != r.Account || operation.Plan.Source.Pane != r.Pane || r.AfterMS < 0 {
			return false
		}
	}
	for id, o := range d.Operations {
		if id != o.Plan.ID || !o.Valid() {
			return false
		}
	}
	for pane, e := range d.Entries {
		if pane != e.Source.Pane || !e.Valid() {
			return false
		}
	}
	for id, r := range d.Receipts {
		if !identifier(id) || !hexDigest(r.Hash) || r.Revision == 0 || r.Revision > d.Revision {
			return false
		}
	}
	return true
}

type frame struct {
	V        int    `json:"v"`
	Previous string `json:"previous"`
	SHA256   string `json:"sha256"`
	State    Disk   `json:"state"`
}

// Journal is an append-only full-state write-ahead policy journal. There are no
// executable effects to replay. Each private fsync'd frame is its own receipt.
// A partial append, unsafe path, corrupt hash chain or full log holds all writes.
type Journal struct{ Root string }

func private(info os.FileInfo, dir bool) bool {
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == os.Getuid() && info.Mode().Perm()&0077 == 0 && ((dir && info.IsDir()) || (!dir && info.Mode().IsRegular()))
}
func (j Journal) locked(fn func(*os.File) error) error {
	if err := os.MkdirAll(j.Root, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(j.Root)
	if err != nil || !private(info, true) {
		return errors.New("capacity state root is not private")
	}
	open := func(name string, flags int) (*os.File, error) {
		fd, err := syscall.Open(filepath.Join(j.Root, name), flags|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
		if err != nil {
			return nil, err
		}
		f := os.NewFile(uintptr(fd), name)
		st, e := f.Stat()
		if e != nil || !private(st, false) {
			f.Close()
			return nil, errors.New("capacity state file is not private")
		}
		return f, nil
	}
	lock, err := open("policy.lock", syscall.O_CREAT|syscall.O_RDWR)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	file, err := open("policy.jsonl", syscall.O_CREAT|syscall.O_APPEND|syscall.O_RDWR)
	if err != nil {
		return err
	}
	defer file.Close()
	return fn(file)
}
func load(file *os.File) (Disk, string, error) {
	empty := Empty()
	info, err := file.Stat()
	if err != nil || info.Size() > 8<<20 {
		return empty, "", errors.New("capacity journal bound")
	}
	raw, err := io.ReadAll(io.LimitReader(file, 8<<20+1))
	if err != nil {
		return empty, "", err
	}
	if len(raw) == 0 {
		return empty, "", nil
	}
	if raw[len(raw)-1] != '\n' {
		return empty, "", errors.New("capacity journal partial append")
	}
	previous := ""
	state := empty
	for _, line := range bytes.Split(raw[:len(raw)-1], []byte{'\n'}) {
		var err error
		state, previous, err = decodeFrame(line, previous, state.Revision+1)
		if err != nil {
			return empty, "", err
		}
	}
	return state, previous, nil
}
func (j Journal) Load() (Disk, error) {
	var state Disk
	err := j.locked(func(f *os.File) error { var e error; state, _, e = load(f); return e })
	return state, err
}

// Update serializes real user/enrollment races, checks CAS and exact request ID
// replay/conflicts, writes before acknowledging and does not recover a partial tail.
var ErrNoChange = errors.New("native event already reflected")

func (j Journal) Update(id, requestHash string, expected uint64, change func(*Disk) error) (Disk, error) {
	return j.update(id, requestHash, &expected, change)
}

// NativeEvent has no wire representation. It applies an observed native input
// revocation to the latest locked state, so a simultaneous settings CAS cannot
// drop human takeover. It never admits/replays physical effects.
func (j Journal) NativeEvent(id, requestHash string, change func(*Disk) error) (Disk, error) {
	return j.update(id, requestHash, nil, change)
}
func (j Journal) update(id, requestHash string, expected *uint64, change func(*Disk) error) (Disk, error) {
	var result Disk
	if !identifier(id) || !hexDigest(requestHash) {
		return result, errors.New("invalid capacity operation")
	}
	err := j.locked(func(f *os.File) error {
		state, previous, err := load(f)
		if err != nil {
			return err
		}
		if receipt, ok := state.Receipts[id]; ok {
			if receipt.Hash != requestHash {
				return errors.New("capacity operation identity conflict")
			}
			result = state
			return nil
		}
		if expected != nil && state.Revision != *expected {
			return errors.New("capacity policy changed; refresh before saving")
		}
		if len(state.Receipts) >= 256 {
			return errors.New("capacity receipt bound; user review required")
		}
		if err = change(&state); err != nil {
			if errors.Is(err, ErrNoChange) {
				result = state
				return nil
			}
			return err
		}
		state.Revision++
		state.Receipts[id] = Receipt{requestHash, state.Revision}
		if !state.Valid() {
			return errors.New("invalid capacity state")
		}
		encoded, err := json.Marshal(state)
		if err != nil {
			return err
		}
		line, err := json.Marshal(frame{Version, previous, Hash(encoded), state})
		if err != nil || len(line) > MaxJSON {
			return errors.New("capacity state bound")
		}
		line = append(line, '\n')
		info, err := f.Stat()
		if err != nil || info.Size()+int64(len(line)) > 8<<20 {
			return errors.New("capacity journal full")
		}
		n, err := f.Write(line)
		if err != nil || n != len(line) {
			return fmt.Errorf("capacity append outcome unknown: %v", err)
		}
		if err = f.Sync(); err != nil {
			return err
		}
		parent, err := os.Open(j.Root)
		if err != nil {
			return err
		}
		defer parent.Close()
		if err = parent.Sync(); err != nil {
			return err
		}
		result = state
		return nil
	})
	return result, err
}

func decodeFrame(line []byte, previous string, revision uint64) (Disk, string, error) {
	var f frame
	if Decode(line, &f) != nil || f.V != Version || f.Previous != previous || !f.State.Valid() || f.State.Revision != revision {
		return Disk{}, "", errors.New("capacity journal corrupt chain")
	}
	raw, _ := json.Marshal(f.State)
	if f.SHA256 != Hash(raw) {
		return Disk{}, "", errors.New("capacity journal hash mismatch")
	}
	return f.State, Hash(line), nil
}

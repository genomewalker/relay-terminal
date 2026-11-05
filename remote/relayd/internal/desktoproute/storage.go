package desktoproute

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func privateDirectory(path string, create bool) error {
	if create {
		if e := os.MkdirAll(path, 0700); e != nil {
			return e
		}
	}
	s, e := os.Lstat(path)
	if e != nil {
		return e
	}
	owner, ok := s.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() || !s.IsDir() || s.Mode().Perm()&0077 != 0 {
		return errors.New("directory must be private and owned by this user")
	}
	return nil
}
func privateRead(path string, limit int, mask os.FileMode) ([]byte, error) {
	fd, e := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	s, e := f.Stat()
	if e != nil {
		return nil, e
	}
	owner, ok := s.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() || !s.Mode().IsRegular() || s.Mode().Perm()&mask != 0 || s.Size() > int64(limit) {
		return nil, errors.New("file must be private, regular and bounded")
	}
	return readBounded(f, limit)
}
func readConfig(path string) (Config, error) {
	b, e := privateRead(path, 16384, 0077)
	if e != nil {
		return Config{}, e
	}
	return ParseConfig(b)
}
func readJSONFile(path string, limit int, v any) error {
	b, e := privateRead(path, limit, 0077)
	if e != nil {
		return e
	}
	return decodeJSON(b, limit, v)
}
func syncDirectory(path string) error {
	f, e := os.Open(path)
	if e != nil {
		return e
	}
	defer f.Close()
	return f.Sync()
}
func atomicBytes(path string, data []byte) error {
	if e := privateDirectory(filepath.Dir(path), false); e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".route-")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(data)
	}
	if e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e == nil {
		e = closeErr
	}
	if e != nil {
		return e
	}
	if e = os.Rename(f.Name(), path); e != nil {
		return e
	}
	return syncDirectory(filepath.Dir(path))
}
func atomicJSON(path string, v any) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	return atomicBytes(path, append(b, '\n'))
}
func exclusiveJSON(path string, v any) error {
	if e := privateDirectory(filepath.Dir(path), false); e != nil {
		return e
	}
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	fd, e := syscall.Open(path, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_EXCL|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if e != nil {
		return e
	}
	f := os.NewFile(uintptr(fd), path)
	_, e = f.Write(b)
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e != nil {
		return e
	}
	return syncDirectory(filepath.Dir(path))
}
func fileLock(path string, nonblock bool) (*os.File, error) {
	fd, e := syscall.Open(path, syscall.O_RDWR|syscall.O_CREAT|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), path)
	s, e := f.Stat()
	if e != nil {
		f.Close()
		return nil, e
	}
	owner, ok := s.Sys().(*syscall.Stat_t)
	if !ok || !s.Mode().IsRegular() || int(owner.Uid) != os.Getuid() || s.Mode().Perm()&0077 != 0 {
		f.Close()
		return nil, errors.New("unsafe lock file")
	}
	flags := syscall.LOCK_EX
	if nonblock {
		flags |= syscall.LOCK_NB
	}
	if e = syscall.Flock(fd, flags); e != nil {
		f.Close()
		return nil, e
	}
	return f, nil
}
func exists(path string) bool { _, e := os.Lstat(path); return !os.IsNotExist(e) }
func jsonFiles(root string, limit int) ([]string, error) {
	entries, e := os.ReadDir(root)
	if e != nil {
		return nil, e
	}
	var result []string
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") {
			result = append(result, filepath.Join(root, entry.Name()))
			if len(result) > limit {
				return nil, errors.New("registry exceeds limit")
			}
		}
	}
	return result, nil
}

type Receipt struct {
	ID        string  `json:"id"`
	Status    string  `json:"status"`
	UpdatedAt float64 `json:"updatedAt"`
}

func receiptStatus(s string) bool {
	switch s {
	case "pending", "not_sent", "written_to_socket", "unknown", "read_acknowledged", "admitted":
		return true
	}
	return false
}
func receiptPath(config string) (string, error) {
	directory := filepath.Join(filepath.Dir(config), "receipts")
	if e := privateDirectory(directory, true); e != nil {
		return "", e
	}
	return filepath.Join(directory, strings.TrimSuffix(filepath.Base(config), filepath.Ext(config))+".json"), nil
}

// updateReceipt reserves IDs permanently before dispatch, including IDs evicted
// from the bounded display ledger. A failed reservation can consume an ID; it
// never permits a second attempt. Read acknowledgments cannot be downgraded.
func updateReceipt(config, id, status string, create bool, now time.Time) (bool, error) {
	if !messageID.MatchString(id) || !receiptStatus(status) {
		return false, errors.New("invalid receipt identity or status")
	}
	path, e := receiptPath(config)
	if e != nil {
		return false, e
	}
	stem := strings.TrimSuffix(path, ".json")
	lock, e := fileLock(stem+".lock", false)
	if e != nil {
		return false, e
	}
	defer lock.Close()
	rows := []Receipt{}
	if exists(path) {
		if e = readJSONFile(path, 65536, &rows); e != nil {
			return false, e
		}
	}
	if len(rows) > 256 {
		return false, errors.New("receipt ledger exceeds limit")
	}
	index := -1
	seen := map[string]bool{}
	for i, row := range rows {
		if !messageID.MatchString(row.ID) || !receiptStatus(row.Status) || seen[row.ID] {
			return false, errors.New("invalid receipt ledger")
		}
		seen[row.ID] = true
		if row.ID == id {
			index = i
		}
	}
	archives := stem + ".ids"
	next := Receipt{id, status, float64(now.UnixNano()) / 1e9}
	if create {
		if index >= 0 {
			return false, errReplay
		}
		if e = privateDirectory(archives, true); e != nil {
			return false, e
		}
		for _, row := range append(append([]Receipt{}, rows...), next) {
			p := filepath.Join(archives, "id-"+row.ID)
			if e = exclusiveJSON(p, row); os.IsExist(e) {
				if row.ID == id {
					return false, errReplay
				}
				b, re := privateRead(p, 16384, 0077)
				if re != nil {
					return false, re
				}
				if len(b) == 0 {
					if e = atomicJSON(p, row); e != nil {
						return false, e
					}
				}
			} else if e != nil {
				return false, e
			}
		}
		rows = append(rows, next)
		if len(rows) > 256 {
			rows = rows[len(rows)-256:]
		}
	} else {
		if index < 0 {
			p := filepath.Join(archives, "id-"+id)
			b, re := privateRead(p, 16384, 0077)
			if os.IsNotExist(re) {
				return false, nil
			}
			if re != nil {
				return false, re
			}
			prior := Receipt{id, "unknown", next.UpdatedAt}
			if len(b) > 0 {
				if e = decodeJSON(b, 16384, &prior); e != nil {
					return false, e
				}
				if prior.ID != id || !receiptStatus(prior.Status) {
					return false, errors.New("invalid archived receipt")
				}
			}
			rows = append(rows, prior)
			if len(rows) > 256 {
				rows = rows[len(rows)-256:]
			}
			index = len(rows) - 1
		}
		if rows[index].Status == "read_acknowledged" && status != "read_acknowledged" {
			// An archived receipt may have just re-entered the display ledger.
			// Persist that projection without downgrading its durable status.
			return true, atomicJSON(path, rows)
		}
		rows[index] = next
	}
	if exists(archives) {
		if e = privateDirectory(archives, false); e != nil {
			return false, e
		}
		if e = atomicJSON(filepath.Join(archives, "id-"+id), next); e != nil {
			return false, e
		}
	}
	if e = atomicJSON(path, rows); e != nil {
		return false, e
	}
	return true, nil
}

type Connection struct {
	ReplyName     string   `json:"replyName"`
	Host          string   `json:"host"`
	RemoteSession string   `json:"remoteSession"`
	Tasks         []string `json:"tasks"`
	CurrentTask   string   `json:"currentTask"`
	UpdatedAt     string   `json:"updatedAt"`
}

func connections(root string) ([]Connection, error) {
	rows := []Connection{}
	path := filepath.Join(root, "connections.json")
	if !exists(path) {
		return rows, nil
	}
	if e := readJSONFile(path, 65536, &rows); e != nil {
		return nil, e
	}
	if len(rows) > 64 {
		return nil, errors.New("connection registry exceeds limit")
	}
	seen := map[string]bool{}
	for _, r := range rows {
		for _, id := range append([]string{r.ReplyName, r.Host, r.RemoteSession, r.CurrentTask}, r.Tasks...) {
			if !identifier.MatchString(id) {
				return nil, errors.New("invalid connection identity")
			}
		}
		if len(r.Tasks) < 1 || len(r.Tasks) > 32 || r.Tasks[len(r.Tasks)-1] != r.CurrentTask || seen[r.ReplyName] {
			return nil, errors.New("invalid connection lineage")
		}
		seen[r.ReplyName] = true
	}
	return rows, nil
}
func recordConnection(root string, c Config, previous string, now time.Time) error {
	lock, e := fileLock(filepath.Join(root, ".connections.lock"), false)
	if e != nil {
		return e
	}
	defer lock.Close()
	rows, e := connections(root)
	if e != nil {
		return e
	}
	index := -1
	for i, r := range rows {
		if r.ReplyName == c.LocalName {
			index = i
		}
	}
	if index >= 0 {
		r := rows[index]
		if r.Host != c.Host || r.RemoteSession != c.RemoteSession || (previous != "" && r.CurrentTask != previous) {
			return errors.New("connection lineage changed")
		}
		if previous == "" && r.CurrentTask == c.Thread {
			return nil
		}
	} else {
		rows = append(rows, Connection{ReplyName: c.LocalName, Host: c.Host, RemoteSession: c.RemoteSession, Tasks: []string{}})
		index = len(rows) - 1
		if previous != "" {
			rows[index].Tasks = append(rows[index].Tasks, previous)
		}
	}
	r := &rows[index]
	if len(r.Tasks) == 0 || r.Tasks[len(r.Tasks)-1] != c.Thread {
		if len(r.Tasks) >= 32 {
			return errors.New("connection lineage full")
		}
		r.Tasks = append(r.Tasks, c.Thread)
	}
	r.CurrentTask = c.Thread
	r.UpdatedAt = now.UTC().Format(time.RFC3339Nano)
	if len(rows) > 64 {
		return errors.New("connection registry full")
	}
	return atomicJSON(filepath.Join(root, "connections.json"), rows)
}
func writeJSON(out io.Writer, v any) error { return json.NewEncoder(out).Encode(v) }
func relativeConfig(root, path string) error {
	if filepath.Dir(filepath.Clean(path)) != filepath.Clean(root) || !strings.HasSuffix(path, ".json") {
		return fmt.Errorf("configuration must be within the route root")
	}
	return nil
}

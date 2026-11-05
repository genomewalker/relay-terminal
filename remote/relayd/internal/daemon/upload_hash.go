package daemon

import (
	"crypto/sha256"
	"encoding"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"reflect"
	"sync"
)

// Streamed transfers have no product byte cap. Lengths use signed 64-bit file
// offsets; chunks and journal metadata retain their independent memory bounds.
const maximumStreamedFileBytes int64 = 1<<63 - 1

type uploadHashEntry struct {
	version, digest string
	offset          int64
	state           []byte
}

// Bounded diagnostic snapshots of the last checked prefix. Metadata equality
// is not authority to restore this state: filesystems can coalesce ctime even
// across a same-size write followed by restoration of mtime.
var uploadHashes = struct {
	sync.Mutex
	entries map[string]uploadHashEntry
}{entries: make(map[string]uploadHashEntry)}

func uploadHashVersion(info os.FileInfo) string {
	// Darwin and Linux name the ctime timespec differently. Exclude atime,
	// which normal checksum reads may change. Include ctime as a diagnostic
	// version signal; even unchanged ctime never authorizes cached hash reuse.
	value := reflect.Indirect(reflect.ValueOf(info.Sys()))
	var changed any = info.Sys()
	if value.IsValid() && value.Kind() == reflect.Struct {
		for _, name := range []string{"Ctim", "Ctimespec"} {
			if field := value.FieldByName(name); field.IsValid() && field.CanInterface() {
				changed = field.Interface()
				break
			}
		}
	}
	return fmt.Sprintf("%s:%d:%d:%v:%v", uploadIdentity(info), info.Size(), info.ModTime().UnixNano(), info.Mode(), changed)
}

func rememberUploadHash(f *os.File, offset int64, h hash.Hash) error {
	info, err := f.Stat()
	if err != nil {
		return err
	}
	state, err := h.(encoding.BinaryMarshaler).MarshalBinary()
	if err != nil {
		return err
	}
	entry := uploadHashEntry{version: uploadHashVersion(info), offset: offset,
		digest: hex.EncodeToString(h.Sum(nil)), state: state}
	uploadHashes.Lock()
	defer uploadHashes.Unlock()
	if len(uploadHashes.entries) >= 64 {
		for key := range uploadHashes.entries {
			delete(uploadHashes.entries, key)
			break
		}
	}
	uploadHashes.entries[uploadIdentity(info)] = entry
	return nil
}

func validatedUploadHash(f *os.File, offset int64, expected string, _ bool) (hash.Hash, error) {
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if offset < 0 || info.Size() < offset {
		return nil, errors.New("upload bytes missing")
	}
	h := sha256.New()
	// Every accepted checkpoint must match its durable bytes, including an
	// ordinary next chunk. A matching inode/size/mtime/ctime tuple cannot prove
	// content identity. Reusing a cached state here hides changed prefixes.
	if n, err := io.Copy(h, io.NewSectionReader(f, 0, offset)); err != nil || n != offset {
		if err != nil {
			return nil, err
		}
		return nil, io.ErrUnexpectedEOF
	}
	if hex.EncodeToString(h.Sum(nil)) != expected {
		return nil, errors.New("upload durable prefix changed")
	}
	after, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if uploadHashVersion(info) != uploadHashVersion(after) {
		return nil, errors.New("upload changed during verification")
	}

	if err := rememberUploadHash(f, offset, h); err != nil {
		return nil, err
	}
	return h, nil
}

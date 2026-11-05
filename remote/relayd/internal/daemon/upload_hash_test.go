package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func TestStreamedUploadRejectsChangedCachedPrefix(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stage")
	if err := os.WriteFile(path, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(path, os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	before, _ := f.Stat()
	sum := sha256.Sum256([]byte("original"))
	expected := hex.EncodeToString(sum[:])
	if _, err := validatedUploadHash(f, 8, expected, false); err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteAt([]byte("tampered"), 0); err != nil {
		t.Fatal(err)
	}
	if err := f.Sync(); err != nil {
		t.Fatal(err)
	}
	// Size, inode and restored mtime all match; ctime must invalidate the cache.
	if err := os.Chtimes(path, before.ModTime(), before.ModTime()); err != nil {
		t.Fatal(err)
	}
	if _, err := validatedUploadHash(f, 8, expected, false); err == nil {
		t.Fatal("cached hash hid changed durable bytes")
	}
}

// Deterministically models a filesystem metadata collision. The original test
// still exercises real ctime behavior; this one makes a stale hash advertise
// the current metadata and requires actual durable bytes to win.
func TestStreamedUploadMetadataCollisionCannotAuthorizeCachedPrefix(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stage")
	if err := os.WriteFile(path, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(path, os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sum := sha256.Sum256([]byte("original"))
	expected := hex.EncodeToString(sum[:])
	if _, err := validatedUploadHash(f, 8, expected, false); err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteAt([]byte("tampered"), 0); err != nil {
		t.Fatal(err)
	}
	if err := f.Sync(); err != nil {
		t.Fatal(err)
	}
	info, err := f.Stat()
	if err != nil {
		t.Fatal(err)
	}
	key := uploadIdentity(info)
	uploadHashes.Lock()
	entry := uploadHashes.entries[key]
	entry.version = uploadHashVersion(info)
	uploadHashes.entries[key] = entry
	uploadHashes.Unlock()
	defer func() {
		uploadHashes.Lock()
		delete(uploadHashes.entries, key)
		uploadHashes.Unlock()
	}()
	if _, err := validatedUploadHash(f, 8, expected, false); err == nil {
		t.Fatal("UPLOAD_METADATA_COLLISION_AUTHORIZED_STALE_BYTES")
	}
}

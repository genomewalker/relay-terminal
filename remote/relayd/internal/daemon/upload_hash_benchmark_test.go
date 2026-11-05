package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// Measure the actual accepted-prefix path with a warm filesystem cache. The
// throughput includes SHA256 and diagnostic snapshot work; it is not disk
// throughput. Upload clients validate a growing prefix once per chunk, so total
// bytes reread for N equal chunks of size C are C*N*(N-1)/2 before final commit.
func BenchmarkUploadDurablePrefixValidation(b *testing.B) {
	for _, size := range []int64{1 << 20, 16 << 20, 64 << 20} {
		b.Run(fmt.Sprintf("prefix-%dMiB", size>>20), func(b *testing.B) {
			f, err := os.OpenFile(filepath.Join(b.TempDir(), "prefix"), os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
			if err != nil {
				b.Fatal(err)
			}
			defer f.Close()
			block := make([]byte, 1<<20)
			for offset := int64(0); offset < size; offset += int64(len(block)) {
				if _, err := f.Write(block); err != nil {
					b.Fatal(err)
				}
			}
			if err := f.Sync(); err != nil {
				b.Fatal(err)
			}
			h := sha256.New()
			if n, err := io.Copy(h, io.NewSectionReader(f, 0, size)); err != nil || n != size {
				b.Fatalf("fixture hash: bytes=%d error=%v", n, err)
			}
			expected := hex.EncodeToString(h.Sum(nil))
			b.SetBytes(size)
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				if _, err := validatedUploadHash(f, size, expected, false); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

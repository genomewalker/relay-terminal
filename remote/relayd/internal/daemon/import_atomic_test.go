package daemon

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestImportPublishesOnlyCompleteFile(t *testing.T) {
	directory := t.TempDir()
	reader, writer := io.Pipe()
	result := make(chan error, 1)
	go func() { _, err := ImportFile(directory, "result.txt", reader); result <- err }()
	if _, err := writer.Write([]byte("first")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(directory, "result.txt")); !os.IsNotExist(err) {
		t.Fatal("Incomplete destination is visible", err)
	}
	if _, err := writer.Write([]byte("second")); err != nil {
		t.Fatal(err)
	}
	writer.Close()
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	value, err := os.ReadFile(filepath.Join(directory, "result.txt"))
	if err != nil || string(value) != "firstsecond" {
		t.Fatal("Wrong published bytes", err)
	}
	rows, _ := os.ReadDir(directory)
	if len(rows) != 1 {
		t.Fatal("Staging file retained")
	}
	imported, err := ImportFile(directory, "result.txt", strings.NewReader("new"))
	if err != nil || imported.Name != "result-2.txt" {
		t.Fatal("Collision changed", err)
	}
	value, _ = os.ReadFile(filepath.Join(directory, "result.txt"))
	if string(value) != "firstsecond" {
		t.Fatal("Existing destination overwritten")
	}
}

type importFailReader struct{}

func (importFailReader) Read([]byte) (int, error) { return 0, errors.New("interrupted") }
func TestImportFailureLeavesNoDestination(t *testing.T) {
	directory := t.TempDir()
	if _, err := ImportFile(directory, "result.txt", io.MultiReader(strings.NewReader("partial"), importFailReader{})); err == nil {
		t.Fatal("Expected interruption")
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 0 {
		t.Fatal("Failed import retained bytes", err)
	}
}

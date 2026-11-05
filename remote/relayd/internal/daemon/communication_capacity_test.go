package daemon

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func capacityFile(t testing.TB, root string, n int, size int64) string {
	t.Helper()
	path := filepath.Join(root, fmt.Sprintf("link-%064x.json", n))
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if err = f.Truncate(size); err != nil {
		t.Fatal(err)
	}
	if err = f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}
func TestCommunicationLinkCapacityBeyond256(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 256; i++ {
		capacityFile(t, root, i, 2)
	}
	before, err := communicationLinkInventory(root, "", nil)
	if err != nil || len(before) != 256 {
		t.Fatal("baseline inventory", err)
	}
	next := filepath.Join(root, fmt.Sprintf("link-%064x.json", 256))
	if _, err = communicationLinkInventory(root, next, []byte("{}")); err != nil {
		t.Fatal("257th unique link refused", err)
	}
	after, _ := communicationLinkInventory(root, "", nil)
	if len(after) != 256 {
		t.Fatal("admission mutated saved links")
	}
}
func TestCommunicationLinkCapacityCountAndUpdate(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 4096; i++ {
		capacityFile(t, root, i, 0)
	}
	existing := filepath.Join(root, fmt.Sprintf("link-%064x.json", 0))
	if _, err := communicationLinkInventory(root, existing, []byte("{}")); err != nil {
		t.Fatal("existing link update refused at capacity", err)
	}
	next := filepath.Join(root, fmt.Sprintf("link-%064x.json", 4096))
	if _, err := communicationLinkInventory(root, next, []byte("{}")); err == nil {
		t.Fatal("4097th link accepted")
	}
	capacityFile(t, root, 4096, 0)
	if _, err := communicationLinkInventory(root, "", nil); err == nil {
		t.Fatal("over-capacity listing accepted")
	}
}
func TestCommunicationLinkCapacityBytesAndPrivateFiles(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 63; i++ {
		capacityFile(t, root, i, 128<<10)
	}
	last := capacityFile(t, root, 63, 64<<10)
	if _, err := communicationLinkInventory(root, "", nil); err != nil {
		t.Fatal("exact storage budget refused", err)
	}
	if _, err := communicationLinkInventory(root, last, make([]byte, (64<<10)+1)); err == nil {
		t.Fatal("byte-budget overflow accepted")
	}
	if _, err := communicationLinkInventory(root, last, []byte("{}")); err != nil {
		t.Fatal("smaller replacement refused", err)
	}
	target := filepath.Join(root, "link-symlink.json")
	if err := os.Symlink(last, target); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationLinkInventory(root, "", nil); err == nil {
		t.Fatal("symlink inventory accepted")
	}
}
func FuzzCommunicationLinkCapacity(f *testing.F) {
	f.Add(uint16(256), uint32(100), true)
	f.Add(uint16(64), uint32(131072), false)
	f.Fuzz(func(t *testing.T, n uint16, size uint32, replace bool) {
		// Bound disk work per input; production count boundary is tested above.
		count := int(n % 65)
		bytes := int64(size % ((128 << 10) + 2))
		root := t.TempDir()
		for i := 0; i < count; i++ {
			capacityFile(t, root, i, bytes)
		}
		path := ""
		data := []byte(nil)
		if replace {
			path = filepath.Join(root, fmt.Sprintf("link-%064x.json", 0))
			data = []byte("{}")
		}
		paths, err := communicationLinkInventory(root, path, data)
		if err == nil {
			if len(paths) != count {
				t.Fatal("inventory dropped saved links")
			}
			for _, p := range paths {
				if !strings.HasPrefix(p, root+string(os.PathSeparator)) {
					t.Fatal("inventory escaped root")
				}
			}
			expected := int64(count) * bytes
			if replace {
				if count > 0 {
					expected -= bytes
				}
				expected += 2
			}
			if expected > communicationLinkStorageBytes || (count > 0 && bytes > 128<<10) {
				t.Fatal("inventory accepted out-of-budget data")
			}
		}
	})
}

func TestCommunicationLinkCapacityListRoute(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	root := communicationRoot()
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 257; i++ {
		id := fmt.Sprintf("%064x", i)
		if err := communicationAtomic(filepath.Join(root, "link-"+id+".json"), communicationLink{Version: 1, ID: id}); err != nil {
			t.Fatal(err)
		}
	}
	result, err := ExecuteCommunication(CommunicationRequest{Operation: "list"})
	if err != nil {
		t.Fatal("list route refused 257 links", err)
	}
	if len(result["links"].([]communicationLink)) != 257 {
		t.Fatal("list route lost membership")
	}
}
func TestCommunicationLinkCapacityEncodedResponse(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	root := communicationRoot()
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 65; i++ {
		// Valid historical JSON can expand when escaped for transport.
		value := fmt.Sprintf("{\"version\":1,\"id\":\"%064x\",\"members\":[{\"name\":\"%s\"}]}", i, strings.Repeat("<", 22000))
		path := filepath.Join(root, fmt.Sprintf("link-%064x.json", i))
		if err := os.WriteFile(path, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := ExecuteCommunication(CommunicationRequest{Operation: "list"}); err == nil {
		t.Fatal("oversized encoded response accepted")
	}
}

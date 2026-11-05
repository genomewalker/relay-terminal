package rotationtext

import (
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func renderHolders(pids []int) []byte {
	var b strings.Builder
	for _, pid := range pids {
		b.WriteString("p" + strconv.Itoa(pid) + "\nf3\n")
	}
	return []byte(b.String())
}

func TestParseLsofHolders(t *testing.T) {
	for _, c := range []struct {
		in   string
		pids []int
	}{
		{"p82271\nf7\n", []int{82271}},
		{"p1\nf7\nftxt\np2\nf8\np1\nf9\n", []int{1, 2}},
		{"p2147483647\nfcwd\n", []int{2147483647}},
	} {
		got, err := parseLsofHolders([]byte(c.in))
		if err != nil || !reflect.DeepEqual(got, c.pids) {
			t.Fatalf("%q: %v %v", c.in, got, err)
		}
	}
	for _, in := range []string{
		"",                  // lsof found nothing / failed: never "no holders"
		"p1\nf7",            // truncated: no final newline
		"p1\n",              // a process without a descriptor
		"p1\np2\nf7\n",      // the first record has no descriptor
		"f7\n",              // no process record
		"p01\nf7\n",         // leading zero
		"p0\nf7\n",          // pid 0
		"p-3\nf7\n",         // negative
		"p2147483648\nf7\n", // beyond int32
		"p12a\nf7\n",        // not a number
		"p1\nf\n",           // empty fd
		"p1\nf7 \n",         // fd with a space
		"p1\nf7\nn/x\n",     // unexpected field
		"p1\r\nf7\n",        // carriage return
		"p1\nf7\n\n",        // empty line
		"p1\nf" + strings.Repeat("9", 33) + "\n",
	} {
		if pids, err := parseLsofHolders([]byte(in)); err == nil {
			t.Fatalf("%q accepted as %v", in, pids)
		}
	}
	if _, err := parseLsofHolders([]byte(strings.Repeat("p1\nf7\n", lsofRecordLimit))); err == nil {
		t.Fatal("output beyond the record limit accepted")
	}
}

func TestParseLsofImage(t *testing.T) {
	in := "p42\nftxt\nD0x100000f\ni226694320\nn/opt/homebrew/Cellar/bash/5.3.3/bin/bash\nftxt\nD0x100000f\ni896921514\nn/usr/lib/dyld\n"
	device, inode, path, err := parseLsofImage([]byte(in), 42)
	if err != nil || device != 16777231 || inode != 226694320 || path != "/opt/homebrew/Cellar/bash/5.3.3/bin/bash" {
		t.Fatalf("%d %d %q %v", device, inode, path, err)
	}
	for _, bad := range []string{
		"",
		"p43\nftxt\nD0x1\ni1\nn/x\n",             // another pid
		"p42\nfcwd\nD0x1\ni1\nn/x\n",             // first descriptor not the executable
		"p42\nftxt\nD0x1\ni1\nnrelative\n",       // relative path
		"p42\nftxt\nD0x1\ni0\nn/x\n",             // inode 0
		"p42\nftxt\nD0x1\ni+1\nn/x\n",            // signed inode
		"p42\nftxt\nD0x1\nix\nn/x\n",             // non-numeric inode
		"p42\nftxt\nD0xg\ni1\nn/x\n",             // non-hex device
		"p42\nftxt\nD0x\ni1\nn/x\n",              // empty device
		"p42\nftxt\nD1\ni1\nn/x\n",               // device without 0x
		"p42\nftxt\ni1\nn/x\n",                   // no device field
		"p42\nftxt\nD0x1\ni1\n",                  // incomplete group
		"p42\nftxt\nD0x1\ni1\nn/x",               // truncated
		"p42\nftxt\nD0x1\ni1\nn/x\nftxt\nD0x1\n", // incomplete second group
		"p42\nftxt\nD0x1\ni1\nn/x\x00y\n",        // NUL in the path
		"p42\n",                                  // no groups
	} {
		if _, _, _, err := parseLsofImage([]byte(bad), 42); err == nil {
			t.Fatalf("%q accepted", bad)
		}
	}
}

// Accepted holder output re-renders to output with the same pids; dropping
// the final byte is always rejected; the pid count is bounded by the lines.
func FuzzLsofHolders(f *testing.F) {
	for _, seed := range []string{"p82271\nf7\n", "p1\nf7\nftxt\np2\nf8\np1\nf9\n", "", "p1\n", "p1\nf7", "p01\nf7\n"} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		pids, err := parseLsofHolders(raw)
		if err != nil {
			return
		}
		if len(pids) == 0 || len(pids) > strings.Count(string(raw), "\n")/2 {
			t.Fatalf("pid count %d for %d lines", len(pids), strings.Count(string(raw), "\n"))
		}
		seen := map[int]bool{}
		for _, pid := range pids {
			if pid <= 0 || seen[pid] {
				t.Fatalf("invalid or repeated pid %d", pid)
			}
			seen[pid] = true
		}
		again, err := parseLsofHolders(renderHolders(pids))
		if err != nil || !reflect.DeepEqual(again, pids) {
			t.Fatalf("re-render changed %v -> %v %v", pids, again, err)
		}
		if _, err := parseLsofHolders(raw[:len(raw)-1]); err == nil {
			t.Fatal("truncated output accepted")
		}
	})
}

// Accepted image output names an absolute path and a nonzero inode that
// re-render identically; truncation is rejected.
func FuzzLsofImage(f *testing.F) {
	for _, seed := range []string{"p42\nftxt\nD0x1\ni1\nn/x\n", "p42\nftxt\nD0x100000f\ni226694320\nn/a/b\nftxt\nD0x2\ni2\nn/usr/lib/dyld\n", "p42\nfcwd\nD0x1\ni1\nn/x\n", ""} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		device, inode, path, err := parseLsofImage(raw, 42)
		if err != nil {
			return
		}
		if inode == 0 || !strings.HasPrefix(path, "/") || strings.ContainsAny(path, "\n\x00") {
			t.Fatalf("accepted inode %d path %q", inode, path)
		}
		againDevice, again, againPath, err := parseLsofImage([]byte("p42\nftxt\nD0x"+strconv.FormatUint(device, 16)+"\ni"+strconv.FormatUint(inode, 10)+"\nn"+path+"\n"), 42)
		if err != nil || againDevice != device || again != inode || againPath != path {
			t.Fatalf("re-render changed: %d %d %q %v", againDevice, again, againPath, err)
		}
		if _, _, _, err := parseLsofImage(raw[:len(raw)-1], 42); err == nil {
			t.Fatal("truncated output accepted")
		}
	})
}

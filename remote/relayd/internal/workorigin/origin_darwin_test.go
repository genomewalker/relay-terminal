//go:build darwin

package workorigin

import (
	"encoding/binary"
	"os"
	"os/exec"
	"testing"
)

func TestDarwinKernelPipeIdentity(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()
	n := nativeReader{}
	a, err := n.pipe(os.Getpid(), int(r.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	b, err := n.pipe(os.Getpid(), int(w.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	if a.Handle == 0 || a.Peer != b.Handle || b.Peer != a.Handle || !a.Readable || a.Writable || !b.Writable || b.Readable {
		t.Fatalf("pipe mismatch: %+v %+v", a, b)
	}
	all, err := n.pipes(os.Getpid())
	if err != nil || all[int(w.Fd())] != b {
		t.Fatalf("descriptor inventory: %v", err)
	}
	p, err := n.process(os.Getpid())
	if err != nil || p.PID != os.Getpid() || p.Parent != os.Getppid() || p.StartMicros <= 0 {
		t.Fatalf("process: %+v %v", p, err)
	}
	file, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := n.pipe(os.Getpid(), int(file.Fd())); err == nil {
		t.Fatal("accepted regular file as native input pipe")
	}
}
func TestDarwinDirectParentOwnsChildInputPipe(t *testing.T) {
	cmd := exec.Command("/bin/cat")
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { in.Close(); cmd.Wait() }()
	n := nativeReader{}
	child, err := n.process(cmd.Process.Pid)
	if err != nil || child.Parent != os.Getpid() {
		t.Fatalf("child: %+v %v", child, err)
	}
	pipe, err := n.pipe(child.PID, 0)
	if err != nil {
		t.Fatal(err)
	}
	peers, err := n.pipes(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, p := range peers {
		if p.Handle == pipe.Peer && p.Peer == pipe.Handle && p.Writable {
			found = true
		}
	}
	if !found {
		t.Fatal("native parent pipe counterpart not found")
	}
}

func TestDarwinRunningCodeMatchesStrongCodeDirectory(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	hashes, err := fileCodeHashes(exe)
	if err != nil {
		t.Fatal(err)
	}
	if len(hashes) == 0 {
		t.Fatal("missing Go binary signature")
	}
}

func TestDarwinKernelRunningCodeHashMatchesFile(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	want, err := fileCodeHashes(exe)
	if err != nil {
		t.Fatal(err)
	}
	got, err := runningCodeHash(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range want {
		if got == h {
			return
		}
	}
	t.Fatal("kernel CDHash differs from code directory")
}
func TestDarwinCodesignedArtifactCodeDirectory(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(exe)
	if err != nil {
		t.Fatal(err)
	}
	path := t.TempDir() + "/signed-fixture"
	if err := os.WriteFile(path, raw, 0700); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", path).CombinedOutput(); err != nil {
		t.Fatalf("codesign: %v %s", err, out)
	}
	if out, err := exec.Command("/usr/bin/codesign", "--verify", "--strict", path).CombinedOutput(); err != nil {
		t.Fatalf("signed fixture invalid: %v %s", err, out)
	}
	if _, err := fileCodeHashes(path); err != nil {
		t.Fatal(err)
	}
}

func TestCodeDirectoryReservedSpaceStaysOutsideContainer(t *testing.T) {
	blob := make([]byte, 60)
	put := binary.BigEndian.PutUint32
	put(blob[:4], 0xfade0cc0)
	put(blob[4:8], 60)
	put(blob[8:12], 1)
	put(blob[16:20], 20)
	put(blob[20:24], 0xfade0c02)
	put(blob[24:28], 40)
	blob[57] = 2
	want, err := signatureCodeHashes(blob)
	if err != nil {
		t.Fatal(err)
	}
	padded := append(append([]byte(nil), blob...), make([]byte, 16)...)
	got, err := signatureCodeHashes(padded)
	if err != nil || len(got) != 1 || got[0] != want[0] {
		t.Fatalf("zero alignment padding: %v", err)
	}
	padded[len(padded)-1] = 1
	got, err = signatureCodeHashes(padded)
	if err != nil || len(got) != 1 || got[0] != want[0] {
		t.Fatalf("reserved bytes entered signature identity: %v", err)
	}
	escaped := append([]byte(nil), padded...)
	put(escaped[16:20], 61)
	if _, err := signatureCodeHashes(escaped); err == nil {
		t.Fatal("signature index escaped declared container")
	}
	put(blob[4:8], 61)
	if _, err := signatureCodeHashes(blob); err == nil {
		t.Fatal("out-of-bounds signature length accepted")
	}
}

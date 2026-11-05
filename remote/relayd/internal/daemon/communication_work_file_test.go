package daemon

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

func workFileFixture(t *testing.T) (string, func() []string) {
	t.Helper()
	saveRoot := t.TempDir()
	old := workFileRoot
	t.Cleanup(func() { workFileRoot = old })
	workFileRoot = func() (string, error) { return saveRoot, nil }
	var delivered atomic.Value
	delivered.Store([]string{})
	add := func(s string) { delivered.Store(append(delivered.Load().([]string), s)) }
	paneSend, runTarget := workPaneSend, workRunNativeTarget
	t.Cleanup(func() { workPaneSend, workRunNativeTarget = paneSend, runTarget })
	workPaneSend = func(id string, p map[string]any) (map[string]any, error) {
		add(p["text"].(string))
		return paneSend(id, p)
	}
	workRunNativeTarget = func(ctx context.Context, h nativemsg.Host, target nativemsg.Target, packet []byte, m *nativemsg.WorkMessage) (map[string]any, error) {
		add(m.Envelope.Content)
		return runTarget(ctx, h, target, packet, m)
	}
	return saveRoot, func() []string { return delivered.Load().([]string) }
}

func writeWorkTestFile(t *testing.T, name string, content []byte) (string, string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, content, 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(content)
	return p, hex.EncodeToString(sum[:])
}

func readWorkInboundResult(t *testing.T, path string) map[string]any {
	t.Helper()
	var receipt workTransportReceipt
	if err := communicationRead(path, &receipt); err != nil {
		t.Fatal(err)
	}
	return receipt.Result
}

func TestWorkSendFileBothDirectionsSavesVerifiedFile(t *testing.T) {
	a, b, al, bl, paneCalls, workCalls := workTransportFixture(t, false)
	saveRoot, delivered := workFileFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	content := bytes.Repeat([]byte("SCIENTIFIC STORY line\n"), 2000)[:40000]
	path, sum := writeWorkTestFile(t, "STORY-20261105.txt", content)

	// Work (node-a) to pane (node-b).
	wo := workRequestOrigin{thread: workTestThread, applicationPID: 42, revalidate: func() error { return nil }}
	wr := WorkRequest{Operation: "send_file", LinkID: al.ID, MessageID: signedMessage, Path: path, FileSHA256: sum, ClientToken: workTestToken}
	result, err := executeWorkRequest(ctx, a, "node-a", wr, wo)
	if err != nil || result["status"] != "accepted_by_provider" || paneCalls.Load() != 1 {
		t.Fatal("Work file to pane", result, err, paneCalls.Load())
	}
	saved := filepath.Join(saveRoot, signedMessage, "STORY-20261105.txt")
	got, err := os.ReadFile(saved)
	if err != nil || !bytes.Equal(got, content) {
		t.Fatal("saved file differs", err)
	}
	if info, _ := os.Stat(saved); info.Mode().Perm() != 0o600 {
		t.Fatal("saved file mode", info.Mode())
	}
	in := readWorkInboundResult(t, workInboundPath(b, "node-a", signedMessage))
	file, _ := in["file"].(map[string]any)
	if file["sha256"] != sum || file["saved_path"] != saved || file["verified"] != true {
		t.Fatal("receiver receipt lacks verified file", in)
	}
	if d := delivered(); len(d) != 1 || !strings.Contains(d[0], "verified and saved on this host at "+saved) || !strings.Contains(d[0], sum) {
		t.Fatal("delivered note", d)
	}
	// Same ID: no replay. Same ID with a different file: refused.
	if _, err = executeWorkRequest(ctx, a, "node-a", wr, wo); err != nil || paneCalls.Load() != 1 {
		t.Fatal("duplicate file replayed", err, paneCalls.Load())
	}
	other, otherSum := writeWorkTestFile(t, "OTHER.txt", []byte("other"))
	conflict := wr
	conflict.Path, conflict.FileSHA256 = other, otherSum
	if _, err = executeWorkRequest(ctx, a, "node-a", conflict, wo); err == nil {
		t.Fatal("same ID with a different file accepted")
	}

	// Pane (node-b) to Work (node-a), with a caller note.
	po := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	pr := WorkRequest{Operation: "send_file", LinkID: bl.ID, MessageID: testGroupID, Path: path, FileSHA256: sum, Text: "Draft attached.", ClientToken: workTestToken}
	result, err = executeWorkRequest(ctx, b, "node-b", pr, po)
	if err != nil || result["status"] != "admitted_not_processed" || workCalls.Load() != 1 {
		t.Fatal("pane file to Work", result, err, workCalls.Load())
	}
	if got, err = os.ReadFile(filepath.Join(saveRoot, testGroupID, "STORY-20261105.txt")); err != nil || !bytes.Equal(got, content) {
		t.Fatal("pane-sent file differs", err)
	}
	if d := delivered(); len(d) != 2 || !strings.HasPrefix(d[1], "Draft attached.\n\n[Relay file] STORY-20261105.txt, 40000 bytes") {
		t.Fatal("pane note", d)
	}
	// Receipts keep the digest but never the bytes.
	marker := []byte(base64.StdEncoding.EncodeToString(content[:300])[:64])
	for _, p := range []string{workOutboundPath(a, signedMessage), workInboundPath(b, "node-a", signedMessage), workOutboundPath(b, testGroupID), workInboundPath(a, "node-b", testGroupID)} {
		data, e := os.ReadFile(p)
		if e != nil || bytes.Contains(data, marker) || bytes.Contains(data, []byte("SCIENTIFIC STORY line")) || !bytes.Contains(data, []byte(sum)) {
			t.Fatal("receipt kept file bytes or lost digest", p, e)
		}
	}
}

func TestWorkSendFileRefusesBeforeSubmitting(t *testing.T) {
	a, _, al, _, paneCalls, _ := workTransportFixture(t, false)
	workFileFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	wo := workRequestOrigin{thread: workTestThread, applicationPID: 42, revalidate: func() error { return nil }}
	path, sum := writeWorkTestFile(t, "draft.txt", []byte("draft"))
	link := filepath.Join(filepath.Dir(path), "link.txt")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	big, bigSum := writeWorkTestFile(t, "big.txt", bytes.Repeat([]byte("x"), workFileLimit+1))
	empty, emptySum := writeWorkTestFile(t, "empty.txt", nil)
	wrong := strings.Repeat("0", 64)
	cases := map[string]WorkRequest{
		"wrong digest": {Path: path, FileSHA256: wrong},
		"symlink":      {Path: link, FileSHA256: sum},
		"too large":    {Path: big, FileSHA256: bigSum},
		"empty":        {Path: empty, FileSHA256: emptySum},
		"relative":     {Path: "draft.txt", FileSHA256: sum},
		"directory":    {Path: filepath.Dir(path), FileSHA256: sum},
		"hidden name":  {Path: filepath.Join(filepath.Dir(path), ".hidden"), FileSHA256: sum},
	}
	for name, c := range cases {
		c.Operation, c.LinkID, c.MessageID, c.ClientToken = "send_file", al.ID, signedMessage, workTestToken
		if _, err := executeWorkRequest(ctx, a, "node-a", c, wo); err == nil {
			t.Fatal(name, "accepted")
		}
	}
	plain := WorkRequest{Operation: "send", LinkID: al.ID, MessageID: signedMessage, Text: "x", Path: path, ClientToken: workTestToken}
	if _, err := executeWorkRequest(ctx, a, "node-a", plain, wo); err == nil {
		t.Fatal("file field on plain send accepted")
	}
	if _, err := os.Stat(workOutboundPath(a, signedMessage)); !os.IsNotExist(err) || paneCalls.Load() != 0 {
		t.Fatal("refused file left a receipt or delivered", err, paneCalls.Load())
	}
}

func TestWorkWireFileVerification(t *testing.T) {
	content := []byte("verified bytes")
	sum := sha256.Sum256(content)
	m := workWire{FileName: "a.txt", FileSize: int64(len(content)), FileSHA256: hex.EncodeToString(sum[:]), FileContent: base64.StdEncoding.EncodeToString(content)}
	if got, err := decodeWorkWireFile(m); err != nil || !bytes.Equal(got, content) {
		t.Fatal("valid file rejected", err)
	}
	tampered := m
	tampered.FileContent = base64.StdEncoding.EncodeToString([]byte("verified bytez"))
	if _, err := decodeWorkWireFile(tampered); err == nil {
		t.Fatal("tampered bytes accepted")
	}
	short := m
	short.FileSize++
	if _, err := decodeWorkWireFile(short); err == nil {
		t.Fatal("size mismatch accepted")
	}
	for _, name := range []string{"", ".", "..", ".env", "a/b", `a\b`, "a\nb", strings.Repeat("a", 256)} {
		bad := m
		bad.FileName = name
		if workWireFileValid(bad) {
			t.Fatalf("unsafe name %q accepted", name)
		}
	}
	// A message without a file keeps the pre-file wire encoding, so existing
	// fingerprints and receipts are unchanged.
	data, _ := json.Marshal(workWire{Version: 3, MessageID: signedMessage})
	if bytes.Contains(data, []byte("file_")) {
		t.Fatal("fileless wire gained file fields", string(data))
	}
	if !workWireFileValid(workWire{}) || workWireFileValid(workWire{FileContent: "eA=="}) {
		t.Fatal("fileless validity")
	}
}

func TestSaveWorkFileNeverReplaces(t *testing.T) {
	workFileFixture(t)
	if _, err := saveWorkFile(signedMessage, "a.txt", []byte("one")); err != nil {
		t.Fatal(err)
	}
	if _, err := saveWorkFile(signedMessage, "a.txt", []byte("two")); err == nil {
		t.Fatal("existing file replaced")
	}
	root, _ := workFileRoot()
	if got, _ := os.ReadFile(filepath.Join(root, signedMessage, "a.txt")); string(got) != "one" {
		t.Fatal("file changed", string(got))
	}
}

// The largest file must fit the 128 KiB peer request with the default note, and
// a request that cannot fit must be refused before an outbound receipt exists.
func TestWorkSendFileMaximumFitsPeerRequest(t *testing.T) {
	a, _, al, _, paneCalls, _ := workTransportFixture(t, false)
	saveRoot, _ := workFileFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	content := bytes.Repeat([]byte{0xff, 0x00, '"'}, workFileLimit/3+1)[:workFileLimit]
	path, sum := writeWorkTestFile(t, "max.bin", content)
	note := strings.Repeat("\"<", 16384/2)
	wo := workRequestOrigin{thread: workTestThread, applicationPID: 42, revalidate: func() error { return nil }}
	wr := WorkRequest{Operation: "send_file", LinkID: al.ID, MessageID: signedMessage, Path: path, FileSHA256: sum, Text: note, ClientToken: workTestToken}
	// A worst-case note with the largest file is refused before any receipt.
	if _, err := executeWorkRequest(ctx, a, "node-a", wr, wo); err == nil || !strings.Contains(err.Error(), "no request submitted") {
		t.Fatal("oversized request not refused up front", err)
	}
	if _, err := os.Stat(workOutboundPath(a, signedMessage)); !os.IsNotExist(err) || paneCalls.Load() != 0 {
		t.Fatal("oversized request claimed a receipt", err)
	}
	// The largest file with the default note is delivered.
	wr.Text = ""
	result, err := executeWorkRequest(ctx, a, "node-a", wr, wo)
	if err != nil || result["status"] != "accepted_by_provider" || paneCalls.Load() != 1 {
		t.Fatal("maximum file and note", result, err)
	}
	if got, _ := os.ReadFile(filepath.Join(saveRoot, signedMessage, "max.bin")); !bytes.Equal(got, content) {
		t.Fatal("maximum file differs")
	}
}

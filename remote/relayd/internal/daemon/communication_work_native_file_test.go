package daemon

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func workNativeFileSend(t *testing.T, root, node string, link communicationTypedRemoteLink, origin workRequestOrigin, id, path, sum, note string) map[string]any {
	t.Helper()
	got, err := executeWorkRequest(context.Background(), root, node, WorkRequest{Operation: "send_file", LinkID: link.ID, MessageID: id, Path: path, FileSHA256: sum, Text: note, ClientToken: workTestToken}, origin)
	if err != nil || got["status"] != "outcome_unknown" || got["carrier"] != "relay_host_channel" {
		t.Fatal("native file send must queue", got, err)
	}
	return got
}

func TestWorkNativeFileBothDirectionsSavesVerifiedFile(t *testing.T) {
	a, b, al, bl, paneCalls, workCalls := workNativeFixture(t)
	saveRoot, delivered := workFileFixture(t)
	content := bytes.Repeat([]byte("SCIENTIFIC STORY line\n"), 2000)[:40000]
	path, sum := writeWorkTestFile(t, "STORY-20261106.txt", content)

	workNativeFileSend(t, a, "node-a", al, workNativeWorkOrigin(), signedMessage, path, sum, "")
	if _, err := os.Stat(workNativeFilePath(a, signedMessage)); err != nil || paneCalls.Load() != 0 {
		t.Fatal("file not queued beside the text", err)
	}
	settled := workNativeCarry(t, a, "node-a", b, "node-b")
	if len(settled) != 1 || settled[0]["status"] != "accepted_by_provider" || paneCalls.Load() != 1 {
		t.Fatal("Work file to pane over host channel", settled, paneCalls.Load())
	}
	saved := filepath.Join(saveRoot, signedMessage, "STORY-20261106.txt")
	if got, err := os.ReadFile(saved); err != nil || !bytes.Equal(got, content) {
		t.Fatal("saved file differs", err)
	}
	in := readWorkInboundResult(t, workInboundPath(b, "node-a", signedMessage))
	if file, _ := in["file"].(map[string]any); file["sha256"] != sum || file["verified"] != true || in["peer_authentication"] != workNativeAuth {
		t.Fatal("receiver receipt", in)
	}
	for _, p := range []string{workNativeFilePath(a, signedMessage), workNativePendingPath(a, signedMessage)} {
		if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("queued file kept after final outcome", p, err)
		}
	}

	po := workRequestOrigin{pane: bl.Local.PaneID, revalidate: func() error { return nil }}
	workNativeFileSend(t, b, "node-b", bl, po, testGroupID, path, sum, "Draft attached.")
	settled = workNativeCarry(t, b, "node-b", a, "node-a")
	if len(settled) != 1 || settled[0]["status"] != "admitted_not_processed" || workCalls.Load() != 1 {
		t.Fatal("pane file to Work over host channel", settled, workCalls.Load())
	}
	if got, err := os.ReadFile(filepath.Join(saveRoot, testGroupID, "STORY-20261106.txt")); err != nil || !bytes.Equal(got, content) {
		t.Fatal("pane-sent file differs", err)
	}
	if d := delivered(); len(d) != 2 || !strings.HasPrefix(d[1], "Draft attached.\n\n[Relay file] \"STORY-20261106.txt\", 40000 bytes") {
		t.Fatal("delivered notes", d)
	}
	marker := []byte(base64.StdEncoding.EncodeToString(content[:300])[:64])
	for _, p := range []string{workOutboundPath(a, signedMessage), workInboundPath(b, "node-a", signedMessage), workOutboundPath(b, testGroupID), workInboundPath(a, "node-b", testGroupID)} {
		data, e := os.ReadFile(p)
		if e != nil || bytes.Contains(data, marker) || !bytes.Contains(data, []byte(sum)) {
			t.Fatal("receipt kept file bytes or lost digest", p, e)
		}
	}
}

// The largest file with the default note passes every limit on the way:
// the claim output the app reads, the request relayd decodes, and delivery.
func TestWorkNativeMaximumFileFitsTheWholeCarrierPath(t *testing.T) {
	a, b, al, _, paneCalls, _ := workNativeFixture(t)
	saveRoot, _ := workFileFixture(t)
	content := bytes.Repeat([]byte{0xff, 0x00, '"'}, workFileLimit/3+1)[:workFileLimit]
	path, sum := writeWorkTestFile(t, "max.bin", content)
	// A worst-case note with the largest file is refused before any record.
	note := strings.Repeat("\"<", 16384/2)
	if _, err := executeWorkRequest(context.Background(), a, "node-a", WorkRequest{Operation: "send_file", LinkID: al.ID, MessageID: signedMessage, Path: path, FileSHA256: sum, Text: note, ClientToken: workTestToken}, workNativeWorkOrigin()); err == nil || !strings.Contains(err.Error(), "no request submitted") {
		t.Fatal("oversized request not refused up front", err)
	}
	for _, p := range []string{workOutboundPath(a, signedMessage), workNativePendingPath(a, signedMessage), workNativeFilePath(a, signedMessage)} {
		if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("refused request left a record", p, err)
		}
	}
	workNativeFileSend(t, a, "node-a", al, workNativeWorkOrigin(), signedMessage, path, sum, "")
	claim, envelope := workNativeClaimEnvelope(t, a, "node-a", signedMessage)
	if out, _ := json.Marshal(claim); len(out) > 256<<10 {
		t.Fatal("claim output exceeds what the app reads", len(out))
	}
	request, _ := json.Marshal(map[string]any{"operation": "deliver_signed_work", "work_envelope": envelope})
	decoded, err := DecodeCommunicationRequest(bytes.NewReader(request))
	if err != nil || decoded.WorkEnvelope != envelope {
		t.Fatal("maximum delivery request refused by the decoder", len(request), err)
	}
	reply, err := communicationWorkNative(context.Background(), b, "node-b", decoded)
	if err != nil || paneCalls.Load() != 1 {
		t.Fatal("maximum file delivery", err)
	}
	if got, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_settle", MessageID: signedMessage, WorkReply: reply["work_reply"].(string)}); err != nil || got["status"] != "accepted_by_provider" {
		t.Fatal("settle", got, err)
	}
	if got, _ := os.ReadFile(filepath.Join(saveRoot, signedMessage, "max.bin")); !bytes.Equal(got, content) {
		t.Fatal("maximum file differs")
	}
}

func TestWorkNativeFileRejectsAlteredBytesAndKeepsItUntilConfirmed(t *testing.T) {
	a, b, al, _, paneCalls, _ := workNativeFixture(t)
	saveRoot, _ := workFileFixture(t)
	content := []byte("original file bytes\n")
	path, sum := writeWorkTestFile(t, "data.txt", content)
	workNativeFileSend(t, a, "node-a", al, workNativeWorkOrigin(), signedMessage, path, sum, "")
	_, envelope := workNativeClaimEnvelope(t, a, "node-a", signedMessage)

	// Bytes changed under a valid sender signature: the digest check refuses.
	altered := workNativeResign(t, envelope, a, "node-a", func(s *workNativeSend) {
		s.Wire.FileContent = base64.StdEncoding.EncodeToString([]byte("altered file bytes!\n"))
	})
	if _, err := workNativeOp(b, "node-b", CommandRequestOrEnvelope(altered)); err == nil {
		t.Fatal("altered file accepted")
	}
	// Bytes changed under someone else's signature: the pin refuses.
	impostor, _ := peerFixture(t, "node-a")
	if _, err := workNativeOp(b, "node-b", CommandRequestOrEnvelope(workNativeResign(t, envelope, impostor, "node-a", func(*workNativeSend) {}))); err == nil {
		t.Fatal("file from wrong host key accepted")
	}
	if paneCalls.Load() != 0 {
		t.Fatal("refused file delivered")
	}
	if _, err := os.Stat(filepath.Join(saveRoot, signedMessage)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("refused file saved", err)
	}
	// The first hop was lost; the file is still queued and the next pass
	// delivers it once. A late duplicate is answered from the record.
	if _, err := os.Stat(workNativeFilePath(a, signedMessage)); err != nil {
		t.Fatal("file dropped before the peer confirmed", err)
	}
	if got := workNativeCarry(t, a, "node-a", b, "node-b"); len(got) != 1 || got[0]["status"] != "accepted_by_provider" || paneCalls.Load() != 1 {
		t.Fatal("lost hop with file", got)
	}
	if _, err := workNativeOp(b, "node-b", CommandRequestOrEnvelope(envelope)); err != nil || paneCalls.Load() != 1 {
		t.Fatal("late duplicate file delivered", err, paneCalls.Load())
	}
	if got, _ := os.ReadFile(filepath.Join(saveRoot, signedMessage, "data.txt")); !bytes.Equal(got, content) {
		t.Fatal("saved file differs")
	}

	// A queued file altered on the sender's disk is never sent.
	path2, sum2 := writeWorkTestFile(t, "second.txt", []byte("second file\n"))
	workNativeFileSend(t, a, "node-a", al, workNativeWorkOrigin(), workNativeSecondID, path2, sum2, "")
	var f workNativeFile
	_ = communicationRead(workNativeFilePath(a, workNativeSecondID), &f)
	f.Content = base64.StdEncoding.EncodeToString([]byte("swapped file\n"))
	_ = communicationAtomic(workNativeFilePath(a, workNativeSecondID), f)
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_claim", MessageID: workNativeSecondID}); err == nil {
		t.Fatal("altered queued file dispatched")
	}
	// After 24 h without confirmation the text and the file are deleted.
	base := workNativeNow
	workNativeNow = func() time.Time { return base().Add(workNativeQueryWindow + time.Minute) }
	defer func() { workNativeNow = base }()
	if _, err := workNativeOp(a, "node-a", CommunicationRequest{Operation: "work_native_claim", MessageID: workNativeSecondID}); err == nil {
		t.Fatal("expired claim accepted")
	}
	for _, p := range []string{workNativeFilePath(a, workNativeSecondID), workNativePendingPath(a, workNativeSecondID)} {
		if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("expired file kept", p, err)
		}
	}
}

func TestDecodeCommunicationRequestAllowsOnlySignedWorkAbove64KiB(t *testing.T) {
	big := func(op string, size int) []byte {
		body, _ := json.Marshal(map[string]any{"operation": op, "work_envelope": strings.Repeat("a", size)})
		return body
	}
	if _, err := DecodeCommunicationRequest(bytes.NewReader(big("deliver_signed_work", 200<<10))); err != nil {
		t.Fatal("signed Work delivery within its limit refused", err)
	}
	for _, c := range []struct {
		op   string
		size int
	}{{"remote_send", 70 << 10}, {"work_native_settle", 70 << 10}, {"deliver_signed", 70 << 10}, {"deliver_signed_work", 225 << 10}} {
		if _, err := DecodeCommunicationRequest(bytes.NewReader(big(c.op, c.size))); err == nil {
			t.Fatal("oversized request accepted", c.op, c.size)
		}
	}
	if _, err := DecodeCommunicationRequest(bytes.NewReader(big("remote_send", 60<<10))); err != nil {
		t.Fatal("ordinary request within 64 KiB refused", err)
	}
}

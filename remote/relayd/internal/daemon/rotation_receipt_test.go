package daemon

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeReceiptLedger installs a chitta CLI that records its stdin and prints
// reply.
func fakeReceiptLedger(t *testing.T, reply string) string {
	t.Helper()
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "reply"), []byte(reply), 0o600); err != nil {
		t.Fatal(err)
	}
	cli := filepath.Join(directory, "chitta")
	script := "#!/bin/sh\ncat > '" + directory + "/stdin'\ncat '" + directory + "/reply'\n"
	if err := os.WriteFile(cli, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	saved := rotationReceiptLedgerCLI
	rotationReceiptLedgerCLI = func() (string, error) { return cli, nil }
	t.Cleanup(func() { rotationReceiptLedgerCLI = saved })
	return filepath.Join(directory, "stdin")
}

func ledgerValue(value string) string {
	return `{"jsonrpc": "2.0", "id": 1, "result": {"content": [], "structured": {"value": ` + value + `}}}`
}

var receiptArguments = []string{"--old", "old-1", "--intent", "intent-1", "--new", "new-1", "--revision", "3", "--project-dir", "/w"}

func TestRotationReceiptPrintsCapsuleAndCanonicalDigest(t *testing.T) {
	stdin := fakeReceiptLedger(t, ledgerValue(
		`{"status": "ok", "capsule": {"revision": 3, "next_action": "résumé \"x\"", "b": [1, 2.50, {"z": null, "a": true}], "a": {}, "e": []}}`))
	var stdout bytes.Buffer
	if err := RotationReceipt(context.Background(), receiptArguments, &stdout); err != nil {
		t.Fatal(err)
	}
	// json.dumps(capsule, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
	canonical := `{"a":{},"b":[1,2.5,{"a":true,"z":null}],"e":[],"next_action":"résumé \"x\"","revision":3}`
	sum := sha256.Sum256([]byte(canonical))
	want := `{
  "a": {},
  "b": [
    1,
    2.5,
    {
      "a": true,
      "z": null
    }
  ],
  "e": [],
  "next_action": "résumé \"x\"",
  "revision": 3
}
RELAY-RECEIPT intent=intent-1 session=new-1 revision=3 sha256=` + hex.EncodeToString(sum[:]) + "\n"
	if stdout.String() != want {
		t.Fatalf("receipt\n got %s\nwant %s", stdout.String(), want)
	}
	request, err := os.ReadFile(stdin)
	if err != nil {
		t.Fatal(err)
	}
	if string(request) != `{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "ledger_op", "arguments": `+
		`{"op": "capsule_get", "args": {"v": 1, "project_dir": "/w", "session_id": "old-1"}}}}`+"\n" {
		t.Fatalf("ledger request %s", request)
	}
}

func TestRotationReceiptRefusesOtherRevisionOrStatus(t *testing.T) {
	for _, c := range []struct{ value, line string }{
		{`{"status": "ok", "capsule": {"revision": 4}}`, "RELAY-RECEIPT-REFUSED status=ok revision=4\n"},
		{`{"status": "ok", "capsule": {"revision": 3.0}}`, "RELAY-RECEIPT-REFUSED status=ok revision=3.0\n"},
		{`{"status": "missing", "capsule": null}`, "RELAY-RECEIPT-REFUSED status=missing revision=None\n"},
		{`{"capsule": {"revision": 3}}`, "RELAY-RECEIPT-REFUSED status=None revision=3\n"},
	} {
		fakeReceiptLedger(t, ledgerValue(c.value))
		var stdout bytes.Buffer
		err := RotationReceipt(context.Background(), receiptArguments, &stdout)
		if !IsRotationReceiptRefused(err) || stdout.String() != c.line {
			t.Errorf("%s: err %v stdout %q", c.value, err, stdout.String())
		}
	}
	fakeReceiptLedger(t, ledgerValue(`{"status": "ok", "capsule": {"revision": "3"}}`))
	var stdout bytes.Buffer
	if err := RotationReceipt(context.Background(), receiptArguments, &stdout); err != nil ||
		!strings.HasSuffix(stdout.String(), "\nRELAY-RECEIPT intent=intent-1 session=new-1 revision=3 sha256="+
			rotationCapsuleDigest(pyObj("revision", "3"))+"\n") {
		t.Fatalf("string revision: %v %q", err, stdout.String())
	}
}

func TestRotationReceiptFailsWithoutPrintingOnLedgerOrRequestErrors(t *testing.T) {
	for name, c := range map[string]struct {
		reply     string
		arguments []string
		message   string
	}{
		"tool error":    {`{"result": {"isError": true, "content": [{"type": "text", "text": "ledger locked"}]}}`, receiptArguments, "ledger locked"},
		"not JSON":      {`ledger down`, receiptArguments, "not JSON"},
		"no value":      {`{"result": {"structured": {}}}`, receiptArguments, "unexpected shape"},
		"list capsule":  {ledgerValue(`{"status": "ok", "capsule": [3]}`), receiptArguments, "not an object"},
		"missing flag":  {ledgerValue(`{}`), receiptArguments[:8], "requires --old"},
		"extra operand": {ledgerValue(`{}`), append(append([]string{}, receiptArguments...), "more"), "invalid rotation receipt request"},
		"unknown flag":  {ledgerValue(`{}`), append([]string{"--force"}, receiptArguments...), "invalid rotation receipt request"},
	} {
		fakeReceiptLedger(t, c.reply)
		var stdout bytes.Buffer
		err := RotationReceipt(context.Background(), c.arguments, &stdout)
		if err == nil || IsRotationReceiptRefused(err) || !strings.Contains(err.Error(), c.message) || stdout.Len() != 0 {
			t.Errorf("%s: err %v stdout %q", name, err, stdout.String())
		}
	}
}

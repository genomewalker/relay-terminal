package nativemsg

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"
)

func shepherdSource() map[string]any {
	return map[string]any{"authentication": "relay_assistant_owner_submitted", "principal": "relay-assistant", "name": "Miko (Relay assistant)", "hostID": "fixture-host", "assistantRequestID": "req-1", "replyPaneID": "a5515700-0000-4000-8000-00000000b0c5", "reportKind": "shepherd"}
}

func TestShepherdProductionReferenceCorpus(t *testing.T) {
	f, err := os.Open("testdata/shepherd.jsonl.gz")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	z, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	scan := bufio.NewScanner(io.LimitReader(z, 16<<20))
	scan.Buffer(make([]byte, 4096), 65536)
	count := 0
	accepted := 0
	for scan.Scan() {
		var row struct {
			Source    map[string]any `json:"source"`
			Text      string         `json:"text"`
			Body      string         `json:"body"`
			Refused   bool           `json:"refused"`
			SHA       string         `json:"sha256"`
			Operation int            `json:"operation"`
		}
		if err := json.Unmarshal(scan.Bytes(), &row); err != nil {
			t.Fatal(err)
		}
		before, _ := json.Marshal(row.Source)
		body, err := ShepherdReportBody(row.Source, row.Text, row.Body)
		after, _ := json.Marshal(row.Source)
		if !bytes.Equal(before, after) {
			t.Fatal("SH45 formatter changed routing or identity")
		}
		if row.Refused {
			if err == nil {
				t.Fatalf("SH46 reference rejection accepted at %d operation%d", count, row.Operation)
			}
		} else {
			if err != nil {
				t.Fatal("SH46 reference accepted report refused", err)
			}
			digest := sha256.Sum256([]byte(body))
			if hex.EncodeToString(digest[:]) != row.SHA {
				t.Fatalf("SH46 reference bytes differ at %d", count)
			}
			if row.Operation != 4 || !strings.HasPrefix(body, ShepherdReportPrefix+"\n") || len(body) > 32850 || !strings.HasSuffix(body, strings.TrimPrefix(row.Text, ShepherdReportPrefix+"\n")) {
				t.Fatal("SH36/SH46 honest complete bounded content")
			}
			accepted++
		}
		count++
	}
	if err := scan.Err(); err != nil {
		t.Fatal(err)
	}
	if count != 25000 || accepted == 0 || accepted == count {
		t.Fatal("SH46 exact seeded corpus coverage", count, accepted)
	}
	t.Logf("SH2-GO-CORPUS count=%d accepted=%d seed=0x5348325059 exact original Python samples", count, accepted)
}

func TestShepherdFormattingBoundaries(t *testing.T) {
	source := shepherdSource()
	text := ShepherdReportPrefix + "\nstate changed"
	body := "Owner provenance\n" + text
	for n := 0; n < len([]rune(ShepherdReportPrefix+"\n")); n++ {
		if _, err := ShepherdReportBody(source, string([]rune(text)[:n]), body); err == nil {
			t.Fatal("SH46 truncated prefix accepted", n)
		}
	}
	for _, key := range []string{"unexpected", "paneID", "sessionID", "approval", "keyFingerprint"} {
		q := shepherdSource()
		q[key] = "forged"
		if _, err := ShepherdReportBody(q, text, body); err == nil {
			t.Fatal("SH46 false claim accepted", key)
		}
	}
	for _, auth := range []any{"kernel_verified", "source_host_attested", "relay_app_signed", "user", nil, int64(1), []any{}} {
		q := shepherdSource()
		q["authentication"] = auth
		if _, err := ShepherdReportBody(q, text, body); err == nil {
			t.Fatal("SH36 false sender origin accepted", auth)
		}
	}
	if got, err := ShepherdReportBody(map[string]any{}, "ordinary", "unchanged"); err != nil || got != "unchanged" {
		t.Fatal("SH46 ordinary formatting changed", got, err)
	}
	for _, pair := range [][2]string{{strings.Repeat("x", 16385), body}, {text, strings.Repeat("x", 32769)}} {
		if _, err := ShepherdReportBody(source, pair[0], pair[1]); err == nil {
			t.Fatal("SH46 content bound")
		}
	}
}

func FuzzShepherdReport(f *testing.F) {
	seed, _ := json.Marshal(map[string]any{"source": shepherdSource(), "text": ShepherdReportPrefix + "\nchanged", "body": "Owner provenance\n" + ShepherdReportPrefix + "\nchanged"})
	f.Add(seed)
	f.Add([]byte(`{"source":null,"text":"ordinary","body":"unchanged"}`))
	f.Add([]byte(`{"source":{"reportKind":"shepherd","approval":"forged"}}`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		if len(raw) > 65536 {
			return
		}
		var row struct {
			Source any    `json:"source"`
			Text   string `json:"text"`
			Body   string `json:"body"`
		}
		if json.Unmarshal(raw, &row) != nil {
			return
		}
		before, _ := json.Marshal(row.Source)
		got, err := ShepherdReportBody(row.Source, row.Text, row.Body)
		after, _ := json.Marshal(row.Source)
		if !bytes.Equal(before, after) {
			t.Fatal("SH45 formatter mutated identity")
		}
		if err != nil {
			return
		}
		source, ok := row.Source.(map[string]any)
		if !ok || source["reportKind"] == nil {
			if got != row.Body {
				t.Fatal("SH46 ordinary bytes changed")
			}
			return
		}
		if source["authentication"] != "relay_assistant_owner_submitted" || source["principal"] != "relay-assistant" || source["replyPaneID"] != "a5515700-0000-4000-8000-00000000b0c5" || !strings.HasPrefix(got, ShepherdReportPrefix+"\n") || len(got) > 32850 {
			t.Fatal("SH36/SH46 accepted false or oversized report")
		}
	})
}

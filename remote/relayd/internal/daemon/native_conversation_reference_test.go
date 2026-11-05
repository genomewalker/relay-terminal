package daemon

import (
	"bufio"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"testing"
)

func TestConversationCanonicalParserReference(t *testing.T) {
	file, err := os.Open("testdata/conversation-reference.jsonl.gz")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	z, err := gzip.NewReader(file)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	digest := sha256.New()
	scan := bufio.NewScanner(io.TeeReader(io.LimitReader(z, 32<<20), digest))
	scan.Buffer(make([]byte, 4096), 2<<20)
	count, accepted, refused := 0, 0, 0
	for scan.Scan() {
		var row struct {
			Row        string `json:"row"`
			Kind       string `json:"kind"`
			Session    string `json:"session"`
			Offset     int64  `json:"offset"`
			Names      string `json:"tool_names"`
			NamesAfter string `json:"tool_names_after"`
			Value      string `json:"value"`
			Raised     string `json:"raised"`
		}
		if err := json.Unmarshal(scan.Bytes(), &row); err != nil {
			t.Fatal(err)
		}
		input := phLoads(row.Row).(*pyObject)
		names := phLoads(row.Names).(*pyObject)
		var value *pyList
		raised := phRaised(t, func() { value = parseConversationRow(input, row.Kind, row.Session, row.Offset, names) })
		if row.Raised != "" {
			refused++
			if raised == nil || phKindName(raised.kind) != row.Raised {
				t.Fatalf("reference exception case %d got %v, want %s", count, raised, row.Raised)
			}
		} else {
			accepted++
			if raised != nil {
				t.Fatalf("reference accepted case %d refused: %v", count, raised)
			}
			got := string(pyEncode(value, pyDumpsSortedASCII))
			if got != row.Value || string(pyEncode(names, pyDumpsSortedASCII)) != row.NamesAfter {
				t.Fatalf("reference parser case %d (%s offset %d) output/state mismatch\n got: %.500s\nwant: %.500s", count, row.Kind, row.Offset, got, row.Value)
			}
			if len(value.items) > 65 || names.Len() > 4096 {
				t.Fatal("native parser output/name bound")
			}
		}
		count++
	}
	if err := scan.Err(); err != nil {
		t.Fatal(err)
	}
	if count != 9058 || accepted == 0 || refused == 0 || hex.EncodeToString(digest.Sum(nil)) != "c00db32739a84b79d8b5dc1b208809161bb4e3a1315f43646181ad283eb8bf88" {
		t.Fatal("canonical parser reference coverage/digest", count, accepted, refused)
	}
	t.Logf("canonical parser corpus=%d accepted=%d refused=%d original-binding-tests=18 generated=8000 seed=0x434f4e5645525345", count, accepted, refused)
}

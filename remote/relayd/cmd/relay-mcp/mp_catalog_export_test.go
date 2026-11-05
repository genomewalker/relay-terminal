package main

import (
	"encoding/json"
	"os"
	"testing"
)

func TestMPExportCatalog(t *testing.T) {
	x, c, e := (&server{}).handle(request{Method: "tools/list"})
	if c != 0 {
		t.Fatal(e)
	}
	b, _ := json.MarshalIndent(x, "", "  ")
	if p := os.Getenv("MP_CATALOG_OUT"); p != "" {
		if e := os.WriteFile(p, b, 0600); e != nil {
			t.Fatal(e)
		}
	}
	if p := os.Getenv("MP_MIKO_OUT"); p != "" {
		b, _ := json.MarshalIndent(mikoCatalog(), "", "  ")
		if e := os.WriteFile(p, b, 0600); e != nil {
			t.Fatal(e)
		}
	}
}

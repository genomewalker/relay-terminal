package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The handler proves its origin by the frontend's live stdin writer, so the
// frontend must keep that writer open until the handler exits.
func TestExecuteKeepsHandlerStdinOpenUntilExit(t *testing.T) {
	script := filepath.Join(t.TempDir(), "handler")
	body := "#!/bin/bash\nIFS= read -r line || exit 3\nexec /usr/bin/python3 -I -c 'import select,sys; r,_,_=select.select([0],[],[],0.5); print(\"{\\\"open\\\":false}\" if r else \"{\\\"open\\\":true}\")'\n"
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	old := handlerPath
	handlerPath = script
	t.Cleanup(func() { handlerPath = old })
	out, err := execute([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(out)); got != `{"open":true}` {
		t.Fatalf("handler stdin writer was not held open: %s", got)
	}
}

// Generate only disposable synthetic data with the native SQLite CLI.
package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func sha(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }
func main() {
	if len(os.Args) != 4 {
		panic("usage: generator SQLITE_CLI OUT PRIVATE_NATIVE_WRITER")
	}
	cli, out := os.Args[1], os.Args[2]
	must(os.MkdirAll(out, 0700))
	path := filepath.Join(out, "journal.sqlite3")
	if _, e := os.Lstat(path); !os.IsNotExist(e) {
		panic("output fixture already exists")
	}
	sql := `PRAGMA page_size=65536;
PRAGMA journal_mode=DELETE;
PRAGMA synchronous=FULL;
CREATE TABLE settings(singleton INTEGER PRIMARY KEY CHECK(singleton=1), operation_id TEXT NOT NULL,value TEXT NOT NULL);
CREATE TABLE configuration_changes(id TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE operations(id TEXT PRIMARY KEY,fingerprint TEXT UNIQUE NOT NULL,settings_digest TEXT NOT NULL,state TEXT NOT NULL,day TEXT NOT NULL,month TEXT NOT NULL,reserved INTEGER NOT NULL,charged INTEGER NOT NULL,result TEXT);
INSERT INTO settings VALUES(1,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','committed-settings-64k');
INSERT INTO configuration_changes VALUES('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','committed-change-64k');
WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<3) INSERT INTO operations SELECT printf('%032x',n),printf('%064x',n),printf('%064x',n+100),'pending','2026-10-25','2026-10',1000000,1000000,'committed-result-'||n FROM x;
`
	c := exec.Command(cli, "-batch", path)
	c.Stdin = strings.NewReader(".bail on\n" + sql)
	b, e := c.CombinedOutput()
	if e != nil {
		panic(fmt.Sprintf("initialize: %v %s", e, b))
	}
	committed, e := os.ReadFile(path)
	must(e)
	c = exec.Command(os.Args[3], path)
	writerOutput, e := c.CombinedOutput()
	if e != nil {
		panic(fmt.Sprintf("private writer: %v %s", e, writerOutput))
	}
	db, e := os.ReadFile(path)
	must(e)
	journal, e := os.ReadFile(path + "-journal")
	must(e)
	if len(db) < 18 || binary.BigEndian.Uint16(db[16:18]) != 1 {
		panic("database did not encode the 64K sentinel")
	}
	if len(journal) < 28 || binary.BigEndian.Uint32(journal[24:28]) != 65536 || !bytes.Equal(journal[:8], []byte{0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7}) {
		panic(fmt.Sprintf("not a 64K hot journal: %x", journal[:28]))
	}
	if bytes.Equal(committed, db) {
		panic("no uncommitted pages were spilled")
	}
	files := []map[string]any{}
	for _, entry := range []struct {
		name string
		data []byte
	}{{"journal.sqlite3", db}, {"journal.sqlite3-journal", journal}, {"committed.sqlite3", committed}} {
		var compressed bytes.Buffer
		w := gzip.NewWriter(&compressed)
		_, e = w.Write(entry.data)
		must(e)
		must(w.Close())
		encoded := base64.StdEncoding.EncodeToString(compressed.Bytes()) + "\n"
		must(os.WriteFile(filepath.Join(out, entry.name+".gz.b64"), []byte(encoded), 0600))
		files = append(files, map[string]any{"name": entry.name, "bytes": len(entry.data), "sha256": sha(entry.data), "encoded_sha256": sha([]byte(encoded))})
	}
	v, e := exec.Command(cli, "-version").CombinedOutput()
	must(e)
	meta := map[string]any{"sqlite_cli": cli, "sqlite_version": strings.TrimSpace(string(v)), "source": "native SQLite CLI creates private synthetic schema; native SQLite C API sqlite3_db_cacheflush syncs uncommitted changes; private writer _exit avoids rollback", "writer_output": strings.TrimSpace(string(writerOutput)), "database_header_uint16": binary.BigEndian.Uint16(db[16:18]), "journal_page_size_uint32": binary.BigEndian.Uint32(journal[24:28]), "files": files}
	b, e = json.MarshalIndent(meta, "", "  ")
	must(e)
	must(os.WriteFile(filepath.Join(out, "generation.json"), append(b, '\n'), 0600))
	fmt.Println(string(b))
}

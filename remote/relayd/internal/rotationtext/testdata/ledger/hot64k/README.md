# Native SQLite 64 KiB rollback fixture

This is private synthetic data: three operations, one settings row and one configuration row. Native SQLite 3.51.0 created the committed database. The native SQLite C API updated all three tables in one uncommitted DELETE/FULL transaction and called sqlite3_db_cacheflush; its private process then used _exit without sqlite3_close. The resulting hot journal restores four pages. No user database or provider was read.

The database header has uint16 sentinel 1 at offset 16; the journal header has actual uint32 65536 at offset 24. These formats are distinct: https://www.sqlite.org/fileformat2.html#the_rollback_journal . The test pins all decompressed bytes and compares the Go in-memory recovery, durable import and native SQLite rollback with the exact committed snapshot and manual rows/results.

To generate a new disposable capture (from this directory; NEW_OUT must not contain a database):

```sh
cc -O2 -Wall -Wextra -Werror native-hot64-writer.c -lsqlite3 -o /tmp/relay-synthetic-hot64-writer
go run generate-native-hot64.go /usr/bin/sqlite3 NEW_OUT /tmp/relay-synthetic-hot64-writer
```

Generation produces three gzip/base64 captures and a JSON provenance record. Journal nonces and timestamps may differ; regeneration requires an explicit fixture-hash review. The fixed corpus retains this original native output. The primary regression also asks native SQLite to recover a separate private copy and checks exact restored bytes and all rows/results. Neither Go import is permitted to change the source database or source journal. The damaged-header case separately covers the page-one fallback using the same native journal, without claiming that deliberately damaged bytes are a separately valid SQLite database.

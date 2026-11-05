// Only for synthetic fixture creation. Do not use on an existing database.
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) return 3;
    char *error = NULL;
    const char *sql = "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA cache_size=1; PRAGMA cache_spill=1; BEGIN IMMEDIATE; UPDATE settings SET value='uncommitted-settings'; UPDATE configuration_changes SET value='uncommitted-change'; UPDATE operations SET result=printf('%090000d',0);";
    if (sqlite3_exec(db, sql, NULL, NULL, &error) != SQLITE_OK) {
        fprintf(stderr, "SQL: %s\n", error ? error : sqlite3_errmsg(db)); return 4;
    }
    // Native SQLite syncs journal and dirty database pages while preserving
    // the uncommitted transaction. Abrupt exit prevents close-time rollback.
    int rc = sqlite3_db_cacheflush(db);
    if (rc != SQLITE_OK) { fprintf(stderr,"cacheflush: %d %s\n",rc,sqlite3_errmsg(db)); return 5; }
    printf("synthetic-hot64-flushed sqlite=%s\n", sqlite3_libversion());
    fflush(stdout);
    _exit(0);
}

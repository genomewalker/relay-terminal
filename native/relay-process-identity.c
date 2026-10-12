// Read a macOS process incarnation without signalling or modifying it.
#include <errno.h>
#include <limits.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    errno = 0;
    long requested = strtol(argv[1], &end, 10);
    if (errno || !end || *end || requested <= 0 || requested > INT_MAX) return 2;
    struct proc_bsdinfo info = {0};
    int bytes = proc_pidinfo((int)requested, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (bytes != sizeof(info) || info.pbi_pid != requested) return 1;
    printf("%u:%llu:%llu:%u\n", info.pbi_pid,
           (unsigned long long)info.pbi_start_tvsec,
           (unsigned long long)info.pbi_start_tvusec, info.pbi_uid);
    return 0;
}

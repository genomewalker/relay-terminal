//go:build darwin && cgo

package main

/*
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/types.h>

#ifndef POSIX_SPAWN_SETSID
#define POSIX_SPAWN_SETSID 0x0400
#endif
#ifndef POSIX_SPAWN_CLOEXEC_DEFAULT
#define POSIX_SPAWN_CLOEXEC_DEFAULT 0x4000
#endif

typedef int (*relay_setdisclaim_fn)(posix_spawnattr_t *, int);
typedef pid_t (*relay_responsible_fn)(pid_t);

// Spawn path with stdin from /dev/null, stdout and stderr on out_fd, a new
// session, an empty signal mask and every other descriptor closed. This is
// what exec.Cmd does for the supervisor. When the private
// responsibility_spawnattrs_setdisclaim is available, the child also becomes
// its own "responsible process" for macOS privacy (TCC) attribution.
static int relay_spawn_supervisor(pid_t *pid, const char *path, char *const argv[],
                                  char *const envp[], int out_fd, int *disclaimed) {
	posix_spawnattr_t attr;
	posix_spawn_file_actions_t actions;
	sigset_t empty;
	int rc;

	*disclaimed = 0;
	rc = posix_spawnattr_init(&attr);
	if (rc != 0) return rc;
	rc = posix_spawn_file_actions_init(&actions);
	if (rc != 0) {
		posix_spawnattr_destroy(&attr);
		return rc;
	}
	sigemptyset(&empty);
	rc = posix_spawnattr_setflags(&attr,
		POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK);
	if (rc == 0) rc = posix_spawnattr_setsigmask(&attr, &empty);
	if (rc == 0) {
		relay_setdisclaim_fn setdisclaim =
			(relay_setdisclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
		if (setdisclaim != NULL && setdisclaim(&attr, 1) == 0) *disclaimed = 1;
	}
	if (rc == 0) rc = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
	if (rc == 0) rc = posix_spawn_file_actions_adddup2(&actions, out_fd, 1);
	if (rc == 0) rc = posix_spawn_file_actions_adddup2(&actions, out_fd, 2);
	if (rc == 0) rc = posix_spawn(pid, path, &actions, &attr, argv, envp);
	posix_spawn_file_actions_destroy(&actions);
	posix_spawnattr_destroy(&attr);
	return rc;
}

static int relay_responsible_pid(pid_t pid, pid_t *responsible) {
	relay_responsible_fn lookup =
		(relay_responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
	if (lookup == NULL) return 0;
	*responsible = lookup(pid);
	return 1;
}
*/
import "C"

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"unsafe"
)

// startSupervisorProcess starts the detached supervisor so that macOS
// attributes its privacy permissions, and those of every pane it hosts, to
// relayd itself rather than to whichever Relay.app copy started this client.
// Arguments, environment, working directory, session and stdio match the
// portable exec.Cmd path, which remains the fallback.
func startSupervisorProcess(child *exec.Cmd, logFile *os.File) (*os.Process, error) {
	if child.Err != nil {
		return nil, child.Err
	}
	process, disclaimed, err := spawnSupervisorDisclaimed(child.Path, child.Args, child.Environ(), logFile)
	if err != nil {
		fmt.Fprintf(logFile, "relayd: disclaimed supervisor spawn failed (%v); using exec\n", err)
		return startSupervisorProcessPortable(child)
	}
	if !disclaimed {
		fmt.Fprintln(logFile, "relayd: responsibility disclaim unavailable; supervisor inherits the launcher's privacy attribution")
	}
	return process, nil
}

func spawnSupervisorDisclaimed(path string, args, env []string, logFile *os.File) (*os.Process, bool, error) {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))
	argv := cStringArray(args)
	defer freeCStringArray(argv)
	envp := cStringArray(env)
	defer freeCStringArray(envp)

	var pid C.pid_t
	var disclaimed C.int
	rc := C.relay_spawn_supervisor(&pid, cPath, &argv[0], &envp[0], C.int(logFile.Fd()), &disclaimed)
	if rc != 0 {
		return nil, false, syscall.Errno(rc)
	}
	process, err := os.FindProcess(int(pid))
	if err != nil {
		return nil, false, err
	}
	return process, disclaimed != 0, nil
}

// responsiblePID reports macOS's responsible process for pid, when the
// private lookup is available.
func responsiblePID(pid int) (int, bool) {
	var responsible C.pid_t
	if C.relay_responsible_pid(C.pid_t(pid), &responsible) == 0 {
		return 0, false
	}
	return int(responsible), true
}

func cStringArray(values []string) []*C.char {
	array := make([]*C.char, len(values)+1)
	for index, value := range values {
		array[index] = C.CString(value)
	}
	return array
}

func freeCStringArray(array []*C.char) {
	for _, value := range array {
		if value != nil {
			C.free(unsafe.Pointer(value))
		}
	}
}

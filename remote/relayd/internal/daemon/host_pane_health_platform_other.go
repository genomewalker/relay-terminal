//go:build !linux && !darwin

package daemon

import "os"

const (
	phPlatformLinux  = false
	phPlatformDarwin = false
)

func phStatUID(os.FileInfo) int { return -1 }

func phStatDevIno(os.FileInfo) (int64, uint64) { return -1, 0 }

func phMachine() string { return "" }

func phProcessArguments(int64) []string {
	phRaise(phOSError, "Native process arguments are unavailable.")
	return nil
}

func phProcessEnvironment(*phReader, int64) [][]byte {
	phRaise(phUnbound, "Process environment is unavailable.")
	return nil
}

func phKernelStartNative(*phReader, any) int64 {
	phRaise(phValueError, "Native process incarnation is unavailable.")
	return 0
}

func phProcessCwd(int64) string {
	phRaise(phValueError, "The agent's working directory is unavailable.")
	return ""
}

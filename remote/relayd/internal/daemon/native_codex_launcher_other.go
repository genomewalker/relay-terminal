//go:build !linux

package daemon

// Other native process inventories identify the executable directly.
func nativeCodexLauncherChild(pid int, processes map[int]string) int { return 0 }

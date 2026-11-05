//go:build !linux && !darwin

package nativemsg

func nativePeerOwner(*pySocket) (int64, int64, error) {
	return 0, 0, valueError("Native inbox kernel credentials are unsupported on this host")
}

func checkDaemonPeer(*pySocket, any, int64) error {
	return valueError("Native daemon peer authentication unavailable")
}

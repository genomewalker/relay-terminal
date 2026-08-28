//go:build !linux

package daemon

import "net"

// Bundled relayd targets Linux. Other platforms are used for development and
// tests; private directory and socket permissions remain enforced there.
func RequirePeerUID(_ net.Conn, _ int) error { return nil }

func PeerCredentials(_ net.Conn) (uid int, pid int, err error) { return -1, 0, nil }

//go:build !darwin && !linux

package subscriptionquota

import "net"

func checkPeer(*net.UnixConn, uint32) error { return errUnavailable }

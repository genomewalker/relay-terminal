//go:build !linux

package daemon

import "errors"

func (server *Server) RecoverWorker(sessionID string, pid int) error {
	return errors.New("existing-worker recovery is currently supported on Linux")
}

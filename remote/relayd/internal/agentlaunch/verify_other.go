//go:build !linux

package agentlaunch

import "errors"

func VerifyProcess(Snapshot) error { return errors.New("source process verification needs Linux") }

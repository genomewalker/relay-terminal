//go:build !linux

package daemon

import "errors"

func commitLegacyWorkerViewport(workerManifest, uint16, uint16) error {
	return errors.New("legacy viewport recovery is supported only on Linux")
}

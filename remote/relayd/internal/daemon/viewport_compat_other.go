//go:build !linux

package daemon

import "errors"

func commitLegacyWorkerViewport(workerManifest, uint16, uint16, string) (uint64, error) {
	return 0, errors.New("legacy viewport recovery is supported only on Linux")
}

func pulseLegacyWorkerViewport(workerManifest, uint16, uint16, string) error {
	return errors.New("legacy viewport recovery is supported only on Linux")
}

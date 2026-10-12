//go:build !darwin

package daemon

func validateLegacyWorkerIdentity(manifest workerManifest) (bool, error) { return false, nil }

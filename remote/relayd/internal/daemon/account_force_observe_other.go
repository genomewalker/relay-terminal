//go:build !darwin && !linux

package daemon

import "errors"

func accountForcePreviewPlatform(*Server, forceAccountTarget) (any, error) {
	return nil, errors.New("account force observation unsupported on this host")
}
func accountForceCommitPlatform(*Server, forceAccountTarget, []string) (forceAccountResult, error) {
	return forceAccountUnknown, errors.New("account force signaling unsupported on this host")
}

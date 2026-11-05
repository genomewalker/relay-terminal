//go:build !darwin

package appupdate

import "errors"

func kernelIdentity(int) (string, error) {
	return "", errors.New("native app updates require Darwin kernel identity")
}
func newWatcher() (Watcher, error) {
	return nil, errors.New("native app updates require Darwin process events")
}

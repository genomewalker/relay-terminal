//go:build !linux && !darwin

package agentlaunch

import "errors"

func ProcessEnvironment(int, ...string) (map[string]string, error) {
	return nil, errors.New("agent environment is unavailable on this platform")
}

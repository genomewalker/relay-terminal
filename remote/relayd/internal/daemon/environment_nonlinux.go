//go:build !linux

package daemon

import "strings"

func stableProcessEnvironment(input []string) []string {
	result := make([]string, 0, len(input)+2)
	for _, value := range input {
		if !strings.HasPrefix(value, "TZ=") && !strings.HasPrefix(value, "LC_ALL=") {
			result = append(result, value)
		}
	}
	return append(result, "TZ=UTC", "LC_ALL=C")
}

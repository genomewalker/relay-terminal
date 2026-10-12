package daemon

import (
	"os"
	"strings"
)

// TerminalEnvironment prevents the noninteractive launcher's color policy from
// leaking into interactive terminals. Shell startup files can still set their
// own preferences after launch. Preserve PATH ordering and empty components.
func TerminalEnvironment(environment []string) []string {
	result := make([]string, 0, len(environment))
	for _, entry := range environment {
		name, value, found := strings.Cut(entry, "=")
		if name == "NO_COLOR" {
			continue
		}
		if found && name == "PATH" {
			seen := map[string]bool{}
			parts := []string{}
			for _, part := range strings.Split(value, string(os.PathListSeparator)) {
				if part == "$PATH" || part == "${PATH}" || seen[part] {
					continue
				}
				seen[part] = true
				parts = append(parts, part)
			}
			entry = "PATH=" + strings.Join(parts, string(os.PathListSeparator))
		}
		result = append(result, entry)
	}
	return result
}

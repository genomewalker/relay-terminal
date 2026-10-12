package main

import "strings"

// Codex launches use the user's official CLI on PATH or an explicit override.
// Archived Relay native bundles are never selected by the launcher.
func resolveStockCodexExecutable() (string, error) {
	return findRealAgentExecutable("codex")
}

func stockCodexEnvironment(environment []string) []string {
	environment = agentEnvironmentWithout(environment, "RELAY_NATIVE_ROTATION_HELPER")
	return agentEnvironmentWithout(environment, "RELAY_NATIVE_MESSAGES")
}

func agentEnvironmentWithout(environment []string, name string) []string {
	result := make([]string, 0, len(environment))
	for _, entry := range environment {
		if !strings.HasPrefix(entry, name+"=") {
			result = append(result, entry)
		}
	}
	return result
}

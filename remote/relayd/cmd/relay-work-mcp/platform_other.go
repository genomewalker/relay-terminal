//go:build !darwin

package main

import "os"

func platformHandlerPath() string {
	executable, err := os.Executable()
	if err != nil {
		// No handler: execute reports "unavailable; no request submitted".
		return ""
	}
	return siblingHandler(executable)
}

func platformHandlerEnv(environment []string) []string { return withoutSharedCaller(environment) }

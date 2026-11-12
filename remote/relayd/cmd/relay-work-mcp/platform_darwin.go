//go:build darwin

package main

func platformHandlerPath() string { return "/Applications/Relay.app/Contents/MacOS/relay-mcp" }

// macOS keeps its existing environment: native Work origin is proven by the
// provider pipe, and separately authorized actors may still use their token.
func platformHandlerEnv(environment []string) []string { return environment }

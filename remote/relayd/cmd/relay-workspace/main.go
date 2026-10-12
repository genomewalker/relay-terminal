package main

import (
 "os"
 "os/exec"
 "path/filepath"
)

// The signed native entry point keeps the Python CLI in bundle resources.
func main() {
 binary, err := os.Executable()
 if err != nil { panic(err) }
 directory := filepath.Dir(binary)
 script := filepath.Join(filepath.Dir(directory), "Resources", "relay-workspace.py")
 command := exec.Command("python3", append([]string{script}, os.Args[1:]...)...)
 command.Env = append(os.Environ(), "RELAY_MCP_BINARY=" + filepath.Join(directory, "relay-mcp"))
 command.Stdin, command.Stdout, command.Stderr = os.Stdin, os.Stdout, os.Stderr
 if err := command.Run(); err != nil {
  if exited, ok := err.(*exec.ExitError); ok { os.Exit(exited.ExitCode()) }
  panic(err)
 }
}

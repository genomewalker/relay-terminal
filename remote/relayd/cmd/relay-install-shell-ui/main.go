package main

import (
	"context"
	"fmt"
	"github.com/relay-terminal/relayd/internal/providersetup"
	"os"
)

func main() {
	home, e := os.UserHomeDir()
	if e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
	os.Exit(providersetup.Main(context.Background(), append([]string{"install-shell-ui"}, os.Args[1:]...), home, os.Stdin, os.Stdout, os.Stderr))
}

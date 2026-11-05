package main

import (
	"fmt"
	"github.com/relay-terminal/relayd/internal/codexshared"
	"os"
)

func main() {
	if e := codexshared.Run(os.Args[1:], os.Stdout, os.Stderr); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}

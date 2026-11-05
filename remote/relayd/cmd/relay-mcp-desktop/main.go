package main

import (
	"fmt"
	"github.com/relay-terminal/relayd/internal/helpercli"
	"os"
)

func main() {
	if e := helpercli.RunMCPDesktop(); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}

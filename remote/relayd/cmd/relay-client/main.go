package main

import (
	"fmt"
	"github.com/relay-terminal/relayd/internal/clientbootstrap"
	"os"
)

func main() {
	if err := clientbootstrap.Run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

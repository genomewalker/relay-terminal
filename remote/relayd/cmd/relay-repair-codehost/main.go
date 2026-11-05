package main

import (
	"github.com/relay-terminal/relayd/internal/nativeprovider"
	"os"
)

func main() { os.Exit(nativeprovider.CLI("repair", os.Args[1:], os.Stdout, os.Stderr)) }

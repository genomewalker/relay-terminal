package main

import (
	"github.com/relay-terminal/relayd/internal/appupdate"
	"os"
)

func main() { os.Exit(appupdate.CLI("preserve", os.Args[1:], os.Stdout, os.Stderr)) }

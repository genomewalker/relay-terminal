package main

import (
	"flag"
	"fmt"
	"github.com/relay-terminal/relayd/internal/helpercli"
	"os"
)

func main() {
	production := flag.Bool("production", false, "validate production acceptance")
	root := flag.String("root", "website", "website directory")
	flag.Parse()
	if flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "unexpected positional arguments")
		os.Exit(2)
	}
	if e := helpercli.ValidateWebsite(*root, *production); e != nil {
		fmt.Fprintln(os.Stderr, "Website validation failed:", e)
		os.Exit(1)
	}
	mode := "development preview"
	if *production {
		mode = "production"
	}
	fmt.Printf("Website validation passed (%s)\n", mode)
}

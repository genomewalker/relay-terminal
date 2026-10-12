package main

import (
	"encoding/json"
	"github.com/relay-terminal/relayd/internal/daemon"
	"io"
	"os"
)

func runPlugin() {
	decoder := json.NewDecoder(io.LimitReader(os.Stdin, 65537))
	decoder.DisallowUnknownFields()
	var request daemon.PluginRequest
	if err := decoder.Decode(&request); err != nil {
		fatal(err.Error())
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		fatal("expected one plugin request")
	}
	result, err := daemon.InspectPlugin(request)
	if err != nil {
		fatal(err.Error())
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fatal(err.Error())
	}
}

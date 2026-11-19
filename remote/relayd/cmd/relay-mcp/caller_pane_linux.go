//go:build linux

package main

import (
	"os"
	"strconv"
	"strings"
)

func parentPID(pid int) int {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return 0
	}
	text := string(raw)
	end := strings.LastIndexByte(text, ')')
	if end < 0 {
		return 0
	}
	fields := strings.Fields(text[end+1:])
	if len(fields) < 2 {
		return 0
	}
	ppid, _ := strconv.Atoi(fields[1])
	return ppid
}

func processEnviron(pid int) ([]byte, bool) {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/environ")
	return raw, err == nil
}

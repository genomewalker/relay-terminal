//go:build !linux && !darwin

package main

func parentPID(int) int                 { return 0 }
func processEnviron(int) ([]byte, bool) { return nil, false }

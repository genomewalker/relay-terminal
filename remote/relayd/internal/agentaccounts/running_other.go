//go:build !linux && !darwin

package agentaccounts

import "errors"

func userProcesses() ([]runningProcess, error) {
	return nil, errors.New("process listing is unsupported on this platform")
}

func renameExclusive(from, to string) (bool, error) {
	return true, errors.New("renaming without replacing is unsupported on this platform")
}

func openPaths() (map[int][]string, error) {
	return nil, errors.New("open files cannot be listed on this platform")
}

func renameExchange(a, b string) (bool, error) {
	return false, errors.New("exchanging files is unsupported on this platform")
}

//go:build !darwin

package workorigin

import "errors"

type nativeReader struct{}

func (nativeReader) uid() uint32 { return 0 }
func (nativeReader) process(int) (Process, error) {
	return Process{}, errors.New("native Work is available only on macOS")
}
func (nativeReader) pipe(int, int) (Pipe, error) {
	return Pipe{}, errors.New("native Work is available only on macOS")
}
func (nativeReader) pipes(int) (map[int]Pipe, error) {
	return nil, errors.New("native Work is available only on macOS")
}

func (nativeReader) trustedFrontend(Process) bool { return false }

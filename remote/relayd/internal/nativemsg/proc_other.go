//go:build !linux && !darwin

package nativemsg

// unavailableSource is a host without /proc and without Darwin's sysctl.
type unavailableSource struct{}

func defaultSource() processSource { return unavailableSource{} }

func (unavailableSource) linux() bool { return false }
func (unavailableSource) identity(int64) (string, error) {
	return "", unbound("Process discovery is unavailable.")
}
func (unavailableSource) epoch(int64) (float64, error) {
	return 0, unbound("Process discovery is unavailable.")
}
func (unavailableSource) processes() ([]psRow, error) {
	return nil, unbound("Process discovery is unavailable.")
}
func (unavailableSource) executable(int64) (string, error) {
	return "", unbound("Process discovery is unavailable.")
}
func (unavailableSource) openPaths(int64) ([]string, error) {
	return nil, unbound("Process discovery is unavailable.")
}
func (unavailableSource) environment(int64) ([][]byte, error) {
	return nil, unbound("Process environment is unavailable.")
}

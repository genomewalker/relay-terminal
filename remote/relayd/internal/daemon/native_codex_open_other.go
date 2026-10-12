//go:build !linux && !darwin

package daemon

func nativeCodexOpenTranscriptBinding(pane string, pid int, start uint64) (AgentBindingRecord, error) {
	return AgentBindingRecord{}, errNativeRuntimeUnsupported
}

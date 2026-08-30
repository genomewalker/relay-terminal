package daemon

import (
	"bytes"
	"strconv"
	"strings"
)

// terminalModeState is the part of the terminal parser that must outlive the
// bounded screen replay. Full-screen programs commonly negotiate these modes
// once at startup. If those bytes fall out of the replay ring, a newly attached
// renderer otherwise shows the right screen while interpreting its keyboard,
// mouse, and paste input with stale defaults.
type terminalModeState struct {
	escapeState   uint8
	csi           []byte
	keyboardStack []int
	privateModes  map[int]bool
}

var durablePrivateModes = []int{1, 1000, 1002, 1003, 1004, 1006, 1007, 2004}

func newTerminalModeState() terminalModeState {
	return terminalModeState{
		keyboardStack: []int{0},
		privateModes:  make(map[int]bool),
	}
}

func (state *terminalModeState) ingest(data []byte) {
	if state.privateModes == nil || len(state.keyboardStack) == 0 {
		*state = newTerminalModeState()
	}
	for _, value := range data {
		switch state.escapeState {
		case 0:
			if value == 0x1b {
				state.escapeState = 1
			}
		case 1:
			switch value {
			case '[':
				state.escapeState = 2
				state.csi = state.csi[:0]
			case 'c': // RIS resets input modes and the keyboard stack.
				state.reset()
			case 0x1b:
				state.escapeState = 1
			default:
				state.escapeState = 0
			}
		case 2:
			if value == 0x1b {
				state.escapeState = 1
				state.csi = state.csi[:0]
				continue
			}
			state.csi = append(state.csi, value)
			if value >= 0x40 && value <= 0x7e {
				state.applyCSI(state.csi)
				state.escapeState = 0
				state.csi = state.csi[:0]
			} else if len(state.csi) > 96 {
				state.escapeState = 0
				state.csi = state.csi[:0]
			}
		}
	}
}

func (state *terminalModeState) reset() {
	state.escapeState = 0
	state.csi = state.csi[:0]
	state.keyboardStack = []int{0}
	clear(state.privateModes)
}

func (state *terminalModeState) applyCSI(sequence []byte) {
	if len(sequence) < 2 {
		return
	}
	final := sequence[len(sequence)-1]
	parameters := string(sequence[:len(sequence)-1])
	if strings.HasPrefix(parameters, "?") && (final == 'h' || final == 'l') {
		enabled := final == 'h'
		for _, raw := range strings.Split(strings.TrimPrefix(parameters, "?"), ";") {
			mode, err := strconv.Atoi(raw)
			if err == nil && isDurablePrivateMode(mode) {
				state.privateModes[mode] = enabled
			}
		}
		return
	}
	if final != 'u' || len(parameters) == 0 {
		return
	}
	operation := parameters[0]
	if operation != '>' && operation != '=' && operation != '<' {
		return
	}
	value := 0
	if raw := parameters[1:]; raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			return
		}
		value = parsed
	}
	switch operation {
	case '>':
		state.keyboardStack = append(state.keyboardStack, value)
	case '=':
		state.keyboardStack[len(state.keyboardStack)-1] = value
	case '<':
		count := value
		if count < 1 {
			count = 1
		}
		if count >= len(state.keyboardStack) {
			state.keyboardStack = state.keyboardStack[:1]
		} else {
			state.keyboardStack = state.keyboardStack[:len(state.keyboardStack)-count]
		}
	}
}

func isDurablePrivateMode(candidate int) bool {
	for _, mode := range durablePrivateModes {
		if candidate == mode {
			return true
		}
	}
	return false
}

// presentationPrelude reconstructs the effective input-mode state without
// changing the remote PTY or its output sequence. Resetting the local keyboard
// stack before one canonical push also means the TUI's eventual pop returns to
// the normal shell state, even after many reconnects.
func (state *terminalModeState) presentationPrelude() []byte {
	if state.privateModes == nil || len(state.keyboardStack) == 0 {
		return nil
	}
	var output bytes.Buffer
	output.WriteString("\x1b[<65535u")
	if flags := state.keyboardStack[len(state.keyboardStack)-1]; flags > 0 {
		output.WriteString("\x1b[>")
		output.WriteString(strconv.Itoa(flags))
		output.WriteByte('u')
	}
	for _, mode := range durablePrivateModes {
		output.WriteString("\x1b[?")
		output.WriteString(strconv.Itoa(mode))
		if state.privateModes[mode] {
			output.WriteByte('h')
		} else {
			output.WriteByte('l')
		}
	}
	return output.Bytes()
}

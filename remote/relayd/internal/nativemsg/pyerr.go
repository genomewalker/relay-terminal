package nativemsg

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
)

// pyErr is a Python exception as the adapter raised it: its class decides
// which except clause swallows it, and its message is str(error).
type pyErr struct {
	class string
	errno syscall.Errno
	msg   string
}

func (e *pyErr) Error() string { return e.msg }

// Exception classes the adapter raises or catches.
const (
	classValue      = "ValueError"
	classJSON       = "JSONDecodeError"
	classUnicode    = "UnicodeDecodeError"
	classKey        = "KeyError"
	classIndex      = "IndexError"
	classOS         = "OSError"
	classConnection = "ConnectionError"
	classTimeout    = "timeout"
	classUnbound    = "Unbound"
	classType       = "TypeError"
	classAttribute  = "AttributeError"
	classRuntime    = "RuntimeError"
	classOverflow   = "OverflowError"
	classInternal   = "InternalError"
)

// pyParents is the part of Python's exception hierarchy the adapter's except
// clauses distinguish.
var pyParents = map[string]string{
	classJSON:       classValue,
	classUnicode:    classValue,
	classConnection: classOS,
	classTimeout:    classOS,
	classOverflow:   "ArithmeticError",
}

func valueError(msg string) error    { return &pyErr{class: classValue, msg: msg} }
func unbound(msg string) error       { return &pyErr{class: classUnbound, msg: msg} }
func typeError(msg string) error     { return &pyErr{class: classType, msg: msg} }
func connectionError(m string) error { return &pyErr{class: classConnection, msg: m} }

// keyError is str(KeyError(key)), the key's repr.
func keyError(key string) error { return &pyErr{class: classKey, msg: pyRepr(key)} }

func attributeError(value any, name string) error {
	return &pyErr{class: classAttribute, msg: fmt.Sprintf("'%s' object has no attribute '%s'", pyTypeName(value), name)}
}

// isA reports whether err is an instance of the Python class. A Go error that
// did not come from this package is not any Python class but Exception.
func isA(err error, class string) bool {
	var e *pyErr
	if !errors.As(err, &e) {
		return class == "Exception"
	}
	if class == "Exception" {
		return true
	}
	if class == "FileNotFoundError" {
		return e.class == classOS && e.errno == syscall.ENOENT
	}
	for current := e.class; current != ""; current = pyParents[current] {
		if current == class {
			return true
		}
	}
	// Errno subclasses of ConnectionError.
	if class == classConnection && e.class == classOS {
		switch e.errno {
		case syscall.EPIPE, syscall.ESHUTDOWN, syscall.ECONNABORTED, syscall.ECONNREFUSED, syscall.ECONNRESET:
			return true
		}
	}
	return false
}

func caught(err error, classes ...string) bool {
	for _, class := range classes {
		if isA(err, class) {
			return true
		}
	}
	return false
}

// strerror is the C library's message, which Go's tables carry in lower case.
func strerror(errno syscall.Errno) string {
	text := errno.Error()
	if text == "" {
		return text
	}
	return strings.ToUpper(text[:1]) + text[1:]
}

// osError is str(OSError(errno, strerror[, filename])).
func osError(errno syscall.Errno, filename *string) error {
	msg := fmt.Sprintf("[Errno %d] %s", int(errno), strerror(errno))
	if filename != nil {
		msg += ": " + pyRepr(*filename)
	}
	return &pyErr{class: classOS, errno: errno, msg: msg}
}

// fromOS converts a Go file or socket error into the OSError Python raised
// for the same call. name is the filename Python attaches, if any.
func fromOS(err error, name ...string) error {
	if err == nil {
		return nil
	}
	var e *pyErr
	if errors.As(err, &e) {
		return err
	}
	if errors.Is(err, os.ErrDeadlineExceeded) {
		return &pyErr{class: classTimeout, msg: "timed out"}
	}
	var errno syscall.Errno
	if errors.As(err, &errno) {
		if len(name) > 0 {
			return osError(errno, &name[0])
		}
		return osError(errno, nil)
	}
	return &pyErr{class: classOS, msg: err.Error()}
}

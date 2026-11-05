package daemon

// Python exception and standard-library semantics for the native pane probe
// (host_pane_health_discovery.go, host_pane_health_maintenance.go). The probe
// is a line-by-line port of host_agent_maintenance.py and the parts of
// host_agent_conversation.py it reaches. Their fences depend on which
// exception classes each `except` clause catches, so failures are raised as
// typed panics and caught only where Python catches the same class.

import (
	"errors"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

type phKind int

const (
	phOSError phKind = iota + 1
	phValueError
	phUnbound // agent_conversation.Unbound, a plain Exception subclass
	phTimeout // subprocess.TimeoutExpired, not an OSError
	phKeyError
	phAttributeError
	phTypeError
	phIndexError
	phRuntimeError
)

type phException struct {
	kind phKind
	msg  string
}

func (e *phException) Error() string { return e.msg }

func phRaise(kind phKind, msg string) { panic(&phException{kind: kind, msg: msg}) }

// phRaiseOS raises an OSError formatted as Python's str(OSError).
func phRaiseOS(err error) { panic(&phException{kind: phOSError, msg: phOSErrorText(err)}) }

func phOSErrorText(err error) string {
	var pathErr *fs.PathError
	var linkErr *os.LinkError
	var errno syscall.Errno
	filename := ""
	switch {
	case errors.As(err, &pathErr):
		filename = pathErr.Path
	case errors.As(err, &linkErr):
		filename = linkErr.Old
	}
	if !errors.As(err, &errno) {
		return err.Error()
	}
	text := errno.Error()
	if text != "" {
		r, size := utf8.DecodeRuneInString(text)
		text = string(unicode.ToUpper(r)) + text[size:]
	}
	if filename == "" {
		return "[Errno " + pyStr(int64(errno)) + "] " + text
	}
	return "[Errno " + pyStr(int64(errno)) + "] " + text + ": " + pyStringRepr(filename)
}

func phErrno(err error) syscall.Errno {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return errno
	}
	return 0
}

// phCatch runs body and returns the exception it raised when its class is one
// of kinds. Any other panic propagates, as an uncaught Python exception does.
func phCatch(body func(), kinds ...phKind) (caught *phException) {
	defer func() {
		recovered := recover()
		if recovered == nil {
			return
		}
		exception := phExceptionOf(recovered)
		if exception != nil {
			for _, kind := range kinds {
				if exception.kind == kind {
					caught = exception
					return
				}
			}
		}
		panic(recovered)
	}()
	body()
	return nil
}

// phCatchAll is `except Exception`: every failure, including the shared
// pyTypeError raised by the Python value model.
func phCatchAll(body func()) (failed bool) {
	defer func() {
		if recover() != nil {
			failed = true
		}
	}()
	body()
	return false
}

func phExceptionOf(recovered any) *phException {
	switch value := recovered.(type) {
	case *phException:
		return value
	case pyTypeError:
		return &phException{kind: phTypeError, msg: string(value)}
	}
	return nil
}

// phGet is dict.get(key, fallback); any other receiver raises AttributeError.
func phGet(value any, key string, fallback any) any {
	object, ok := value.(*pyObject)
	if !ok {
		phRaise(phAttributeError, "object has no attribute 'get'")
	}
	return object.GetOr(key, fallback)
}

// phIndex is value[key] on a dict.
func phIndex(value any, key string) any {
	object, ok := value.(*pyObject)
	if !ok {
		phRaise(phTypeError, "object is not subscriptable")
	}
	item, ok := object.Lookup(key)
	if !ok {
		phRaise(phKeyError, key)
	}
	return item
}

// phIsDict, phIsList and phIsStr are isinstance checks.
func phIsDict(v any) bool { _, ok := v.(*pyObject); return ok }
func phIsList(v any) bool { _, ok := v.(*pyList); return ok }
func phIsStr(v any) bool  { _, ok := v.(string); return ok }

// phIsInt is isinstance(v, int), which bool satisfies.
func phIsInt(v any) bool { _, isBool := v.(bool); return isBool || pyIsInt(v) }

// phStrictInt is isinstance(v, int) and not isinstance(v, bool).
func phStrictInt(v any) bool { return pyIsInt(v) }

// phInOptions is `value in (a, b, ...)` for a tuple of literals.
func phInOptions(value any, options ...any) bool {
	for _, option := range options {
		if pyEqual(value, option) {
			return true
		}
	}
	return false
}

// phHashKey checks that v can be a dict key or set member.
func phHashKey(v any) {
	if !pyHashable(v) {
		phRaise(phTypeError, "unhashable type")
	}
}

// phLoads is json.loads on text.
func phLoads(text string) any {
	value, err := pyDecode([]byte(text))
	if err != nil {
		phRaise(phValueError, "Expecting value")
	}
	return value
}

// phLoadsBytes is json.loads on bytes: undecodable UTF-8 is a ValueError
// (UnicodeDecodeError) and a UTF-8 BOM is accepted.
func phLoadsBytes(data []byte) any {
	data = []byte(strings.TrimPrefix(string(data), "\xef\xbb\xbf"))
	if !utf8.Valid(data) {
		phRaise(phValueError, "'utf-8' codec can't decode")
	}
	return phLoads(string(data))
}

// phDecodeUTF8 is bytes.decode("utf-8") (strict).
func phDecodeUTF8(data []byte) string {
	if !utf8.Valid(data) {
		phRaise(phValueError, "'utf-8' codec can't decode")
	}
	return string(data)
}

// phDecodeReplace is bytes.decode("utf-8", "replace").
func phDecodeReplace(data []byte) string {
	if utf8.Valid(data) {
		return string(data)
	}
	var builder strings.Builder
	for len(data) > 0 {
		r, size := utf8.DecodeRune(data)
		builder.WriteRune(r)
		data = data[size:]
	}
	return builder.String()
}

// phIsSpace is str.isspace for one character.
func phIsSpace(r rune) bool {
	return unicode.IsSpace(r) || r >= 0x1c && r <= 0x1f
}

// phStrip is str.strip().
func phStrip(s string) string { return strings.TrimFunc(s, phIsSpace) }

// phSplit is str.split() with an optional maxsplit (-1 for none).
func phSplit(s string, maxsplit int) []string {
	var result []string
	i := 0
	runes := []rune(s)
	for i < len(runes) {
		for i < len(runes) && phIsSpace(runes[i]) {
			i++
		}
		if i == len(runes) {
			break
		}
		if maxsplit >= 0 && len(result) == maxsplit {
			result = append(result, string(runes[i:]))
			return result
		}
		start := i
		for i < len(runes) && !phIsSpace(runes[i]) {
			i++
		}
		result = append(result, string(runes[start:i]))
	}
	return result
}

// phSplitLines is str.splitlines().
func phSplitLines(s string) []string {
	var result []string
	runes := []rune(s)
	start := 0
	for i := 0; i < len(runes); i++ {
		switch runes[i] {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			result = append(result, string(runes[start:i]))
			start = i + 1
		case '\r':
			result = append(result, string(runes[start:i]))
			if i+1 < len(runes) && runes[i+1] == '\n' {
				i++
			}
			start = i + 1
		}
	}
	if start < len(runes) {
		result = append(result, string(runes[start:]))
	}
	return result
}

// phSplitLinesBytes is bytes.splitlines().
func phSplitLinesBytes(data []byte) [][]byte {
	var result [][]byte
	start := 0
	for i := 0; i < len(data); i++ {
		switch data[i] {
		case '\n':
			result = append(result, data[start:i])
			start = i + 1
		case '\r':
			result = append(result, data[start:i])
			if i+1 < len(data) && data[i+1] == '\n' {
				i++
			}
			start = i + 1
		}
	}
	if start < len(data) {
		result = append(result, data[start:])
	}
	return result
}

// phHasControl is any(ord(c) < 32 or ord(c) == 127 for c in text).
func phHasControl(text string) bool {
	for _, r := range text {
		if r < 32 || r == 127 {
			return true
		}
	}
	return false
}

var phShellUnsafe = regexp.MustCompile(`[^A-Za-z0-9_@%+=:,./-]`)

// phShlexQuote is shlex.quote.
func phShlexQuote(s string) string {
	if s == "" {
		return "''"
	}
	if !phShellUnsafe.MatchString(s) {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'"
}

// phShlexSplit is shlex.split(s) in POSIX mode without comments.
func phShlexSplit(s string) []string {
	var words []string
	runes := []rune(s)
	pos := 0
	for {
		token, quoted, state := "", false, ' '
		escaped := ' '
		ended := false
		for !ended {
			var next rune
			eof := pos >= len(runes)
			if !eof {
				next = runes[pos]
				pos++
			}
			switch {
			case state == ' ':
				switch {
				case eof:
					ended = true
				case strings.ContainsRune(" \t\r\n", next):
					if token != "" || quoted {
						ended = true
					}
				case next == '\\':
					escaped, state = 'a', '\\'
				case next == '\'' || next == '"':
					state = next
				default:
					token, state = string(next), 'a'
				}
			case state == '\'' || state == '"':
				quoted = true
				switch {
				case eof:
					phRaise(phValueError, "No closing quotation")
				case next == state:
					state = 'a'
				case next == '\\' && state == '"':
					escaped, state = state, '\\'
				default:
					token += string(next)
				}
			case state == '\\':
				if eof {
					phRaise(phValueError, "No escaped character")
				}
				if (escaped == '\'' || escaped == '"') && next != state && next != escaped {
					token += string(state)
				}
				token += string(next)
				state = escaped
			default: // 'a'
				switch {
				case eof:
					ended = true
				case strings.ContainsRune(" \t\r\n", next):
					state = ' '
					if token != "" || quoted {
						ended = true
					}
				case next == '\'' || next == '"':
					state = next
				case next == '\\':
					escaped, state = 'a', '\\'
				default:
					token += string(next)
				}
			}
		}
		if token == "" && !quoted {
			return words
		}
		words = append(words, token)
	}
}

// phNormpath is posixpath.normpath.
func phNormpath(path string) string {
	if path == "" {
		return "."
	}
	initial := 0
	if strings.HasPrefix(path, "/") {
		initial = 1
		if strings.HasPrefix(path, "//") && !strings.HasPrefix(path, "///") {
			initial = 2
		}
	}
	var parts []string
	for _, part := range strings.Split(path, "/") {
		if part == "" || part == "." {
			continue
		}
		if part != ".." || initial == 0 && len(parts) == 0 || len(parts) > 0 && parts[len(parts)-1] == ".." {
			parts = append(parts, part)
		} else if len(parts) > 0 {
			parts = parts[:len(parts)-1]
		}
	}
	result := strings.Repeat("/", initial) + strings.Join(parts, "/")
	if result == "" {
		return "."
	}
	return result
}

// phExpanduser is os.path.expanduser.
func phExpanduser(path string) string {
	if !strings.HasPrefix(path, "~") {
		return path
	}
	i := strings.Index(path[1:], "/") + 1
	if i == 0 {
		i = len(path)
	}
	var home string
	if i == 1 {
		value, ok := os.LookupEnv("HOME")
		if !ok {
			account, err := user.LookupId(pyStr(int64(os.Getuid())))
			if err != nil {
				phRaise(phKeyError, "getpwuid(): uid not found")
			}
			value = account.HomeDir
		}
		home = value
	} else {
		account, err := user.Lookup(path[1:i])
		if err != nil {
			return path
		}
		home = account.HomeDir
	}
	home = strings.TrimRight(home, "/")
	if home+path[i:] == "" {
		return "/"
	}
	return home + path[i:]
}

// phHome is pathlib.Path.home().
func phHome() string { return phPath(phExpanduser("~")) }

// phEnv is os.environ.get(name, fallback).
func phEnv(name, fallback string) string {
	if value, ok := os.LookupEnv(name); ok {
		return value
	}
	return fallback
}

// phPath is str(pathlib.PurePosixPath(s)): empty and "." components are
// dropped, ".." is kept, and exactly two leading slashes are preserved.
func phPath(s string) string {
	root := ""
	if strings.HasPrefix(s, "/") {
		root = "/"
		if strings.HasPrefix(s, "//") && !strings.HasPrefix(s, "///") {
			root = "//"
		}
	}
	var parts []string
	for _, part := range strings.Split(s, "/") {
		if part != "" && part != "." {
			parts = append(parts, part)
		}
	}
	result := root + strings.Join(parts, "/")
	if result == "" {
		return "."
	}
	return result
}

// phJoin is pathlib's `/`: an absolute component replaces what precedes it.
func phJoin(base string, parts ...string) string {
	result := base
	for _, part := range parts {
		if strings.HasPrefix(part, "/") {
			result = part
		} else {
			result = result + "/" + part
		}
	}
	return phPath(result)
}

func phPathParts(s string) (string, []string) {
	s = phPath(s)
	root := ""
	switch {
	case strings.HasPrefix(s, "//"):
		root = "//"
	case strings.HasPrefix(s, "/"):
		root = "/"
	}
	rest := strings.TrimPrefix(s, root)
	if rest == "" || rest == "." {
		return root, nil
	}
	return root, strings.Split(rest, "/")
}

// phName is PurePath.name.
func phName(s string) string {
	_, parts := phPathParts(s)
	if len(parts) == 0 {
		return ""
	}
	return parts[len(parts)-1]
}

// phParent is PurePath.parent.
func phParent(s string) string {
	root, parts := phPathParts(s)
	if len(parts) == 0 {
		return phPath(s)
	}
	result := root + strings.Join(parts[:len(parts)-1], "/")
	if result == "" {
		return "."
	}
	return result
}

// phParents is PurePath.parents.
func phParents(s string) []string {
	root, parts := phPathParts(s)
	var result []string
	for i := len(parts) - 1; i >= 0; i-- {
		value := root + strings.Join(parts[:i], "/")
		if value == "" {
			value = "."
		}
		result = append(result, value)
	}
	return result
}

// phSuffix is PurePath.suffix.
func phSuffix(s string) string {
	name := phName(s)
	i := strings.LastIndex(name, ".")
	if 0 < i && i < len(name)-1 {
		return name[i:]
	}
	return ""
}

// phAbs is os.path.abspath.
func phAbs(path string) string {
	if !strings.HasPrefix(path, "/") {
		cwd, err := os.Getwd()
		if err != nil {
			phRaiseOS(err)
		}
		path = cwd + "/" + path
	}
	return phNormpath(path)
}

// phRealpath is os.path.realpath(path) (non-strict): missing components are
// kept, symlink loops leave the remaining path unresolved.
func phRealpath(path string) string {
	resolved, _ := phJoinRealpath("", path, map[string]*string{})
	return phAbs(resolved)
}

func phPosixJoin(a, b string) string {
	if strings.HasPrefix(b, "/") || a == "" {
		return b
	}
	if strings.HasSuffix(a, "/") {
		return a + b
	}
	return a + "/" + b
}

func phJoinRealpath(path, rest string, seen map[string]*string) (string, bool) {
	if strings.HasPrefix(rest, "/") {
		rest, path = rest[1:], "/"
	}
	for rest != "" {
		name := rest
		if i := strings.Index(rest, "/"); i >= 0 {
			name, rest = rest[:i], rest[i+1:]
		} else {
			rest = ""
		}
		if name == "" || name == "." {
			continue
		}
		if name == ".." {
			if path != "" {
				head, tail := filepath.Split(path)
				if head != "" && strings.Trim(head, "/") != "" {
					head = strings.TrimRight(head, "/")
				}
				path = head
				if tail == ".." {
					path = phPosixJoin(phPosixJoin(path, ".."), "..")
				}
			} else {
				path = ".."
			}
			continue
		}
		next := phPosixJoin(path, name)
		info, err := os.Lstat(next)
		if err != nil || info.Mode()&os.ModeSymlink == 0 {
			path = next
			continue
		}
		if known, ok := seen[next]; ok {
			if known != nil {
				path = *known
				continue
			}
			return phPosixJoin(next, rest), false
		}
		seen[next] = nil
		target, err := os.Readlink(next)
		if err != nil {
			phRaiseOS(err)
		}
		resolved, ok := phJoinRealpath(path, target, seen)
		if !ok {
			return phPosixJoin(resolved, rest), false
		}
		path = resolved
		seen[next] = &resolved
	}
	return path, true
}

// phResolve is Path.resolve(strict).
func phResolve(path string, strict bool) string {
	path = phPath(path)
	if !strict {
		resolved := phPath(phRealpath(path))
		if _, err := os.Stat(resolved); phErrno(err) == syscall.ELOOP {
			phRaise(phRuntimeError, "Symlink loop from "+pyStringRepr(path))
		}
		return resolved
	}
	resolved, err := filepath.EvalSymlinks(phAbs(path))
	if err != nil {
		if errno := phErrno(err); errno != 0 && errno != syscall.ELOOP {
			phRaiseOS(err)
		}
		if errors.Is(err, fs.ErrNotExist) {
			phRaiseOS(err)
		}
		phRaise(phRuntimeError, "Symlink loop from "+pyStringRepr(path))
	}
	return phPath(resolved)
}

// phIgnoredStatError is pathlib's _ignore_error: these mean "does not exist".
func phIgnoredStatError(err error) bool {
	switch phErrno(err) {
	case syscall.ENOENT, syscall.ENOTDIR, syscall.EBADF, syscall.ELOOP:
		return true
	}
	return false
}

func phStatOrMissing(path string, follow bool) (os.FileInfo, bool) {
	var info os.FileInfo
	var err error
	if follow {
		info, err = os.Stat(path)
	} else {
		info, err = os.Lstat(path)
	}
	if err != nil {
		if phIgnoredStatError(err) {
			return nil, false
		}
		phRaiseOS(err)
	}
	return info, true
}

// phExists, phIsFile and phIsDir are Path.exists/is_file/is_dir.
func phExists(path string) bool { _, ok := phStatOrMissing(path, true); return ok }

func phIsFile(path string) bool {
	info, ok := phStatOrMissing(path, true)
	return ok && info.Mode().IsRegular()
}

func phIsDir(path string) bool {
	info, ok := phStatOrMissing(path, true)
	return ok && info.IsDir()
}

// phLexists is os.path.lexists.
func phLexists(path string) bool { _, err := os.Lstat(path); return err == nil }

// phMustStat is os.stat / os.lstat raising OSError.
func phMustStat(path string, follow bool) os.FileInfo {
	var info os.FileInfo
	var err error
	if follow {
		info, err = os.Stat(path)
	} else {
		info, err = os.Lstat(path)
	}
	if err != nil {
		phRaiseOS(err)
	}
	return info
}

// phOpenRead is open(path, "rb") that never blocks the probe: a FIFO, which
// Python would wait on for a writer indefinitely, raises OSError instead.
func phOpenRead(path string) *os.File {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		phRaiseOS(err)
	}
	if info, err := file.Stat(); err == nil && info.Mode()&os.ModeNamedPipe != 0 {
		file.Close()
		phRaise(phOSError, "Refusing to wait on a named pipe: "+pyStringRepr(path))
	}
	return file
}

// phListDir is os.scandir order (unsorted); an unreadable directory is
// reported to the caller.
func phListDir(path string) ([]string, error) {
	// Non-blocking: opening a FIFO named like a directory must not wait for a
	// writer (os.listdir never opens one for reading).
	directory, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer directory.Close()
	return directory.Readdirnames(-1)
}

// phGlob is Path(base).glob(pattern) for patterns of "/"-separated
// components without "**". Wildcard components list the directory (hidden
// names included, as pathlib does); intermediate matches must be directories
// and literal components must exist.
func phGlob(base, pattern string) []string {
	if !phIsDirQuiet(base) {
		return nil
	}
	return phGlobFrom(phPath(base), strings.Split(pattern, "/"))
}

func phIsDirQuiet(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func phGlobFrom(parent string, components []string) []string {
	component, last := components[0], len(components) == 1
	var result []string
	if !strings.ContainsAny(component, "*?[") {
		path := phJoin(parent, component)
		if last {
			if _, err := os.Stat(path); err == nil {
				result = append(result, path)
			}
		} else if phIsDirQuiet(path) {
			result = append(result, phGlobFrom(path, components[1:])...)
		}
		return result
	}
	names, err := phListDir(parent)
	if err != nil {
		return nil
	}
	for _, name := range names {
		path := phJoin(parent, name)
		if !last && !phIsDirQuiet(path) {
			continue
		}
		if matched, _ := filepath.Match(component, name); !matched {
			continue
		}
		if last {
			result = append(result, path)
		} else {
			result = append(result, phGlobFrom(path, components[1:])...)
		}
	}
	return result
}

// phWhich is shutil.which(name).
func phWhich(name string) string {
	if strings.Contains(name, "/") {
		if phAccessCheck(name) {
			return name
		}
		return ""
	}
	path, ok := os.LookupEnv("PATH")
	if !ok {
		path = "/bin:/usr/bin"
	}
	if path == "" {
		return ""
	}
	seen := map[string]bool{}
	for _, directory := range strings.Split(path, ":") {
		if seen[directory] {
			continue
		}
		seen[directory] = true
		candidate := phPosixJoin(directory, name)
		if directory == "" {
			candidate = name
		}
		if phAccessCheck(candidate) {
			return candidate
		}
	}
	return ""
}

func phAccessCheck(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir() && syscall.Access(path, 1) == nil
}

// phMtime is st_mtime: CPython computes sec + nsec * 1e-9 as a double.
func phMtime(info os.FileInfo) float64 {
	modified := info.ModTime()
	return float64(modified.Unix()) + float64(modified.Nanosecond())*1e-9
}

// phMtimeNs is st_mtime_ns.
func phMtimeNs(info os.FileInfo) int64 { return info.ModTime().UnixNano() }

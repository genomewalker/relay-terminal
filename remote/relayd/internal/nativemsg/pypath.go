package nativemsg

import (
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// Paths are kept as the str() of a pathlib.PurePosixPath.

// pathParts splits a path as PurePosixPath does: "//" alone is its own root,
// empty and "." components vanish.
func pathParts(s string) (root string, parts []string) {
	switch {
	case strings.HasPrefix(s, "//") && !strings.HasPrefix(s, "///"):
		root = "//"
	case strings.HasPrefix(s, "/"):
		root = "/"
	}
	for _, part := range strings.Split(s, "/") {
		if part != "" && part != "." {
			parts = append(parts, part)
		}
	}
	return root, parts
}

func joinParts(root string, parts []string) string {
	s := root + strings.Join(parts, "/")
	if s == "" {
		return "."
	}
	return s
}

// pathNorm is str(pathlib.Path(s)).
func pathNorm(s string) string { return joinParts(pathParts(s)) }

// pathFrom is pathlib.Path(value) for a JSON value.
func pathFrom(value any) (string, error) {
	s, ok := value.(string)
	if !ok {
		return "", typeError("expected str, bytes or os.PathLike object, not " + pyTypeName(value))
	}
	return pathNorm(s), nil
}

// pathJoin is Path(base) / child.
func pathJoin(base, child string) string {
	if strings.HasPrefix(child, "/") {
		return pathNorm(child)
	}
	return pathNorm(base + "/" + child)
}

func pathParent(s string) string {
	root, parts := pathParts(s)
	if len(parts) == 0 {
		return joinParts(root, nil)
	}
	return joinParts(root, parts[:len(parts)-1])
}

func pathName(s string) string {
	_, parts := pathParts(s)
	if len(parts) == 0 {
		return ""
	}
	return parts[len(parts)-1]
}

func pathSuffix(s string) string {
	name := pathName(s)
	i := strings.LastIndex(name, ".")
	if 0 < i && i < len(name)-1 {
		return name[i:]
	}
	return ""
}

func pathIsAbs(s string) bool { return strings.HasPrefix(s, "/") }

// pathRelativeTo reports whether path.relative_to(base) succeeds.
func pathRelativeTo(path, base string) bool {
	pRoot, pParts := pathParts(path)
	bRoot, bParts := pathParts(base)
	if pRoot != bRoot || len(pParts) < len(bParts) {
		return false
	}
	for i := range bParts {
		if pParts[i] != bParts[i] {
			return false
		}
	}
	return true
}

// normpath is posixpath.normpath.
func normpath(path string) string {
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
	for _, comp := range strings.Split(path, "/") {
		if comp == "" || comp == "." {
			continue
		}
		if comp != ".." || (initial == 0 && len(parts) == 0) || (len(parts) > 0 && parts[len(parts)-1] == "..") {
			parts = append(parts, comp)
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

func nulError(path string) error {
	if strings.IndexByte(path, 0) >= 0 {
		return valueError("embedded null byte")
	}
	return nil
}

// resolvePath is Python 3.6 Path.resolve(strict): symlinks are followed
// component by component, and without strict a missing tail is kept.
func resolvePath(path, cwd string, strict bool) (string, error) {
	if err := nulError(path); err != nil {
		return "", err
	}
	seen := map[string]*string{}
	var resolve func(base, rest string) (string, error)
	resolve = func(base, rest string) (string, error) {
		if strings.HasPrefix(rest, "/") {
			base = ""
		}
		for _, name := range strings.Split(rest, "/") {
			if name == "" || name == "." {
				continue
			}
			if name == ".." {
				if i := strings.LastIndex(base, "/"); i >= 0 {
					base = base[:i]
				} else {
					base = ""
				}
				continue
			}
			next := base + "/" + name
			if cached, ok := seen[next]; ok {
				if cached != nil {
					base = *cached
					continue
				}
				return "", &pyErr{class: classRuntime, msg: "Symlink loop from " + pyRepr(next)}
			}
			target, err := os.Readlink(next)
			if err != nil {
				var errno syscall.Errno
				if strict && !(asErrno(err, &errno) && errno == syscall.EINVAL) {
					return "", fromOS(err, next)
				}
				base = next
				continue
			}
			seen[next] = nil
			resolved, err := resolve(base, target)
			if err != nil {
				return "", err
			}
			seen[next] = &resolved
			base = resolved
		}
		return base, nil
	}
	base := ""
	if !pathIsAbs(path) {
		base = cwd
	}
	s, err := resolve(base, pathNorm(path))
	if err != nil {
		return "", err
	}
	if s == "" {
		s = "/"
	}
	return normpath(s), nil
}

func asErrno(err error, errno *syscall.Errno) bool {
	for err != nil {
		if e, ok := err.(syscall.Errno); ok {
			*errno = e
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

func statT(info os.FileInfo) *syscall.Stat_t { return info.Sys().(*syscall.Stat_t) }

func pyStat(path string) (*syscall.Stat_t, error) {
	if err := nulError(path); err != nil {
		return nil, err
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, fromOS(err, path)
	}
	return statT(info), nil
}

func pyLstat(path string) (*syscall.Stat_t, error) {
	if err := nulError(path); err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fromOS(err, path)
	}
	return statT(info), nil
}

func isRegular(st *syscall.Stat_t) bool { return st.Mode&syscall.S_IFMT == syscall.S_IFREG }
func isDir(st *syscall.Stat_t) bool     { return st.Mode&syscall.S_IFMT == syscall.S_IFDIR }
func isSocket(st *syscall.Stat_t) bool  { return st.Mode&syscall.S_IFMT == syscall.S_IFSOCK }

// openNoFollow is os.open(path, O_RDONLY | O_NOFOLLOW) and os.fstat.
func openNoFollow(path string) (*os.File, *syscall.Stat_t, error) {
	if err := nulError(path); err != nil {
		return nil, nil, err
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, nil, fromOS(err, path)
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, fromOS(err)
	}
	return f, statT(info), nil
}

// readUpTo is a buffered f.read(n): it returns fewer bytes only at EOF.
func readUpTo(f *os.File, n int) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(f, int64(n)))
	if err != nil {
		return nil, fromOS(err)
	}
	return data, nil
}

func devIno(st *syscall.Stat_t) string {
	// Python formats st_dev as a signed and st_ino as an unsigned integer.
	return strconv.FormatInt(int64(st.Dev), 10) + ":" + strconv.FormatUint(uint64(st.Ino), 10)
}

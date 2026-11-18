package daemon

// Declared services are long-running host jobs (APIs, gateways, web servers)
// that a supervisor upgrade may stop and relaunch on the user's behalf. Only
// an explicit declaration authorizes that; every other live host job still
// defers the upgrade.
//
// Declarations live beside the host job ledger, one directory per host:
//
//	<state-dir>/services/<hostname>/declarations.json   specs and bindings
//	<state-dir>/services/<hostname>/journal.json        an upgrade in progress
//	<state-dir>/services/<hostname>/lock                serializes changes
//
// The state directory is commonly on a home directory shared by several HPC
// nodes, so a declaration only ever acts on the host that declared it. The
// files are owner-only because a spec may carry environment values; neither
// the CLI nor the journal summary prints them.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	serviceFileVersion          = 1
	defaultServiceStartupGrace  = 90
	maximumServiceStartupGrace  = 3600
	maximumDeclaredServices     = 128
	maximumServiceDeclaredBytes = 1 << 20
)

var (
	validServiceName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)
	validServiceHost = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$`)
)

// ServiceHealth names one probe. TCP is host:port (a bare port means
// 127.0.0.1); Unix is a socket path. With HTTPPath the probe is an HTTP GET
// whose status must be in Accept (default 200-399); without it a connection
// is enough.
type ServiceHealth struct {
	TCP      string `json:"tcp,omitempty"`
	Unix     string `json:"unix,omitempty"`
	HTTPPath string `json:"http_path,omitempty"`
	Accept   []int  `json:"accept,omitempty"`
}

// ServiceSpec is everything needed to launch the service again. Exactly one
// of Command (run by /bin/sh -lc, as host exec does) or Argv is set.
type ServiceSpec struct {
	Name                string            `json:"name"`
	Command             string            `json:"command,omitempty"`
	Argv                []string          `json:"argv,omitempty"`
	Cwd                 string            `json:"cwd"`
	Env                 map[string]string `json:"env,omitempty"`
	DependsOn           []string          `json:"depends_on,omitempty"`
	Health              *ServiceHealth    `json:"health,omitempty"`
	StartupGraceSeconds int               `json:"startup_grace_seconds"`
}

// ServiceDeclaration is a spec plus its binding to the host job that runs it
// now. Generation numbers are allocated from serviceFile.Generations and are
// never reused: a finished job ID stays reserved in the ledger.
type ServiceDeclaration struct {
	ServiceSpec
	JobID      string `json:"job_id,omitempty"`
	Generation int    `json:"generation,omitempty"`
	DeclaredAt string `json:"declared_at"`
}

type serviceFile struct {
	Version     int                  `json:"version"`
	Host        string               `json:"host"`
	Services    []ServiceDeclaration `json:"services"`
	Generations map[string]int       `json:"generations,omitempty"`
}

// ServiceStore is one host's declarations.
type ServiceStore struct {
	dir  string
	host string
}

// LocalHostName is the key for this host's declarations.
func LocalHostName() (string, error) {
	host, err := os.Hostname()
	if err != nil {
		return "", err
	}
	if !validServiceHost.MatchString(host) {
		return "", fmt.Errorf("host name %q cannot key service declarations", host)
	}
	return host, nil
}

// OpenServiceStore opens (without creating) the host's service directory.
// An empty state directory means the supervisor's default.
func OpenServiceStore(stateDir, host string) (*ServiceStore, error) {
	if stateDir == "" {
		stateDir = defaultWorkerStateDir()
	}
	if host == "" {
		var err error
		if host, err = LocalHostName(); err != nil {
			return nil, err
		}
	}
	if !validServiceHost.MatchString(host) {
		return nil, errors.New("invalid service host")
	}
	return &ServiceStore{dir: filepath.Join(stateDir, "services", host), host: host}, nil
}

func (s *ServiceStore) Host() string { return s.host }

func (s *ServiceStore) declarationsPath() string { return filepath.Join(s.dir, "declarations.json") }
func (s *ServiceStore) journalPath() string      { return filepath.Join(s.dir, "journal.json") }

// Lock serializes declaration changes and upgrades for this host. With wait
// false a held lock is reported instead of awaited.
func (s *ServiceStore) Lock(wait bool) (func(), error) {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return nil, err
	}
	file, err := OpenPrivateFile(filepath.Join(s.dir, "lock"), syscall.O_CREAT|syscall.O_RDWR)
	if err != nil {
		return nil, err
	}
	how := syscall.LOCK_EX
	if !wait {
		how |= syscall.LOCK_NB
	}
	if err := syscall.Flock(int(file.Fd()), how); err != nil {
		file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errors.New("another service operation or supervisor upgrade holds the service lock")
		}
		return nil, err
	}
	return func() {
		_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
		file.Close()
	}, nil
}

func (s *ServiceStore) load() (serviceFile, error) {
	file := serviceFile{Version: serviceFileVersion, Host: s.host}
	if err := readServiceJSON(s.declarationsPath(), &file); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return serviceFile{Version: serviceFileVersion, Host: s.host}, nil
		}
		return file, err
	}
	if file.Version != serviceFileVersion || file.Host != s.host {
		return file, errors.New("service declarations belong to another host or format; refusing to use them")
	}
	return file, nil
}

func (s *ServiceStore) save(file serviceFile) error {
	file.Version, file.Host = serviceFileVersion, s.host
	sort.Slice(file.Services, func(i, j int) bool { return file.Services[i].Name < file.Services[j].Name })
	return writeServiceJSON(s.declarationsPath(), file)
}

// Services returns this host's declarations, sorted by name.
func (s *ServiceStore) Services() ([]ServiceDeclaration, error) {
	file, err := s.load()
	return file.Services, err
}

// Declare adds or replaces a declaration. jobID binds it to the job that runs
// the service now (an existing relay_exec job may be adopted this way). A
// replacement keeps its binding unless jobID is given. The caller holds Lock.
func (s *ServiceStore) Declare(spec ServiceSpec, jobID string) (ServiceDeclaration, error) {
	if spec.StartupGraceSeconds == 0 {
		spec.StartupGraceSeconds = defaultServiceStartupGrace
	}
	if err := spec.validate(); err != nil {
		return ServiceDeclaration{}, err
	}
	if jobID != "" && !validSessionID.MatchString(jobID) {
		return ServiceDeclaration{}, errors.New("invalid job ID")
	}
	file, err := s.load()
	if err != nil {
		return ServiceDeclaration{}, err
	}
	declaration := ServiceDeclaration{ServiceSpec: spec, JobID: jobID, DeclaredAt: time.Now().UTC().Format(time.RFC3339)}
	replaced := false
	for i, existing := range file.Services {
		if jobID != "" && existing.JobID == jobID && existing.Name != spec.Name {
			return ServiceDeclaration{}, fmt.Errorf("job %s is already declared as service %s", jobID, existing.Name)
		}
		if existing.Name == spec.Name {
			if jobID == "" {
				declaration.JobID, declaration.Generation = existing.JobID, existing.Generation
			}
			file.Services[i], replaced = declaration, true
		}
	}
	if !replaced {
		if len(file.Services) >= maximumDeclaredServices {
			return ServiceDeclaration{}, errors.New("too many declared services")
		}
		file.Services = append(file.Services, declaration)
	}
	if _, err := serviceLaunchLevels(file.Services); err != nil {
		return ServiceDeclaration{}, err
	}
	return declaration, s.save(file)
}

// Undeclare removes a declaration; its job keeps running, but is no longer
// stopped by an upgrade. Allocated generations are kept. The caller holds Lock.
func (s *ServiceStore) Undeclare(name string) error {
	file, err := s.load()
	if err != nil {
		return err
	}
	kept := file.Services[:0]
	found := false
	for _, existing := range file.Services {
		if existing.Name == name {
			found = true
			continue
		}
		for _, dependency := range existing.DependsOn {
			if dependency == name {
				return fmt.Errorf("service %s depends on %s", existing.Name, name)
			}
		}
		kept = append(kept, existing)
	}
	if !found {
		return fmt.Errorf("service %s is not declared on %s", name, s.host)
	}
	file.Services = kept
	return s.save(file)
}

// HasWork reports whether an upgrade on this host has declarations or an
// unfinished journal to honour. Without either, the upgrade is unchanged.
func (s *ServiceStore) HasWork() (bool, error) {
	if _, err := os.Lstat(s.dir); errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	file, err := s.load()
	if err != nil {
		return true, err
	}
	if len(file.Services) > 0 {
		return true, nil
	}
	journal, err := s.loadJournal()
	return journal != nil && !journal.finished(), err
}

func (spec ServiceSpec) validate() error {
	if !validServiceName.MatchString(spec.Name) {
		return errors.New("service name must be 1-64 letters, digits, '-' or '_'")
	}
	if (spec.Command == "") == (len(spec.Argv) == 0) {
		return errors.New("give exactly one of a command or an argv")
	}
	if len(spec.Command) > 60000 || len(spec.Argv) > 128 || len(spec.Env) > 128 {
		return errors.New("command, argv or environment exceeds host exec limits")
	}
	for _, argument := range spec.Argv {
		if len(argument) > 1<<20 || strings.ContainsRune(argument, 0) {
			return errors.New("invalid argument")
		}
	}
	if !filepath.IsAbs(spec.Cwd) {
		return errors.New("service cwd must be an absolute path")
	}
	for key, value := range spec.Env {
		if key == "" || strings.ContainsAny(key, "=\x00") || strings.ContainsRune(value, 0) || len(value) > 65536 {
			return errors.New("invalid environment")
		}
	}
	for _, dependency := range spec.DependsOn {
		if !validServiceName.MatchString(dependency) || dependency == spec.Name {
			return fmt.Errorf("invalid dependency %q", dependency)
		}
	}
	if spec.StartupGraceSeconds < 1 || spec.StartupGraceSeconds > maximumServiceStartupGrace {
		return errors.New("startup grace must be 1-3600 seconds")
	}
	if health := spec.Health; health != nil {
		if (health.TCP == "") == (health.Unix == "") {
			return errors.New("health needs exactly one of a TCP address or a Unix socket")
		}
		if health.HTTPPath != "" && !strings.HasPrefix(health.HTTPPath, "/") {
			return errors.New("health HTTP path must start with /")
		}
		if len(health.Accept) > 0 && health.HTTPPath == "" {
			return errors.New("accepted status codes need an HTTP path")
		}
		for _, code := range health.Accept {
			if code < 100 || code > 599 {
				return fmt.Errorf("invalid HTTP status %d", code)
			}
		}
	}
	return nil
}

// serviceLaunchLevels orders services by dependency: every service in a level
// depends only on services in earlier levels. Stop order is the reverse.
// Dependencies are per host; a missing or cyclic one is refused.
func serviceLaunchLevels(services []ServiceDeclaration) ([][]string, error) {
	byName := map[string]ServiceDeclaration{}
	for _, service := range services {
		if _, duplicate := byName[service.Name]; duplicate {
			return nil, fmt.Errorf("service %s is declared twice", service.Name)
		}
		byName[service.Name] = service
	}
	for _, service := range services {
		for _, dependency := range service.DependsOn {
			if _, ok := byName[dependency]; !ok {
				return nil, fmt.Errorf("service %s depends on %s, which is not declared on this host", service.Name, dependency)
			}
		}
	}
	placed := map[string]bool{}
	var levels [][]string
	for len(placed) < len(byName) {
		var level []string
		for name, service := range byName {
			if placed[name] {
				continue
			}
			ready := true
			for _, dependency := range service.DependsOn {
				if !placed[dependency] {
					ready = false
					break
				}
			}
			if ready {
				level = append(level, name)
			}
		}
		if len(level) == 0 {
			return nil, errors.New("service dependencies form a cycle")
		}
		sort.Strings(level)
		for _, name := range level {
			placed[name] = true
		}
		levels = append(levels, level)
	}
	return levels, nil
}

func serviceJobID(name string, generation int) string {
	return fmt.Sprintf("svc-%s-g%d", name, generation)
}

func readServiceJSON(path string, value any) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() > maximumServiceDeclaredBytes {
		return fmt.Errorf("%s is not a bounded regular file", filepath.Base(path))
	}
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("%s must be private to its owner", filepath.Base(path))
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, value); err != nil {
		return fmt.Errorf("%s is invalid: %w", filepath.Base(path), err)
	}
	return nil
}

// writeServiceJSON is durable before it returns: the data is synced, renamed
// over the old file and the directory is synced.
func writeServiceJSON(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	if len(data) > maximumServiceDeclaredBytes {
		return errors.New("service record exceeds its size limit")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".service-*")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)
	if err = file.Chmod(0o600); err == nil {
		_, err = file.Write(append(data, '\n'))
	}
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

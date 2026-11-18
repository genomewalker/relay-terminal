package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// TestServiceFakeProcess is the fake service the tests launch as a host job:
// an HTTP server that logs its start and its SIGTERM. Run directly it does
// nothing.
func TestServiceFakeProcess(t *testing.T) {
	address := os.Getenv("RELAY_SERVICE_FAKE_ADDR")
	if address == "" {
		return
	}
	name, logPath := os.Getenv("RELAY_SERVICE_FAKE_NAME"), os.Getenv("RELAY_SERVICE_FAKE_LOG")
	record := func(line string) {
		file, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err == nil {
			fmt.Fprintln(file, line)
			file.Close()
		}
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM)
	if delay, _ := strconv.Atoi(os.Getenv("RELAY_SERVICE_FAKE_DELAY_MS")); delay > 0 {
		time.Sleep(time.Duration(delay) * time.Millisecond)
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		record("listen-failed " + name)
		os.Exit(3)
	}
	record(fmt.Sprintf("start %s %d", name, os.Getpid()))
	status, _ := strconv.Atoi(os.Getenv("RELAY_SERVICE_FAKE_STATUS"))
	if status == 0 {
		status = http.StatusOK
	}
	go http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(status) }))
	for range signals {
		if os.Getenv("RELAY_SERVICE_FAKE_IGNORE_TERM") == "1" {
			continue
		}
		record("stop " + name)
		os.Exit(0)
	}
}

// inProcessJobs is a supervisor reached without a socket. Its errors are the
// supervisor's own answers, so they are definite refusals.
type inProcessJobs struct{ server *Server }

func (j inProcessJobs) call(request hostRequest) (json.RawMessage, error) {
	result, err := j.server.hostRPC(request)
	if err != nil {
		return nil, &serviceRPCError{refused: true, message: err.Error()}
	}
	return json.Marshal(result)
}

// lossyJobs executes every request but loses the answer to the first exec,
// as a dropped connection would.
type lossyJobs struct {
	inProcessJobs
	mu   sync.Mutex
	lost int
}

func (j *lossyJobs) call(request hostRequest) (json.RawMessage, error) {
	raw, err := j.inProcessJobs.call(request)
	j.mu.Lock()
	defer j.mu.Unlock()
	if request.Operation == "exec" && j.lost == 0 {
		j.lost++
		return nil, &serviceRPCError{message: "host response unavailable; outcome unknown"}
	}
	return raw, err
}

type serviceFixture struct {
	t        *testing.T
	stateDir string
	work     string
	log      string
	old      *Server
	servers  []*Server
}

// newServer is a supervisor on the fixture's state directory.
func (f *serviceFixture) newServer() *Server {
	server := &Server{stateDir: f.stateDir}
	f.servers = append(f.servers, server)
	return server
}

func newServiceFixture(t *testing.T) *serviceFixture {
	root := t.TempDir()
	// No default may resolve to the user's real Relay state.
	t.Setenv("HOME", filepath.Join(root, "home"))
	t.Setenv("XDG_STATE_HOME", filepath.Join(root, "state"))
	t.Setenv("XDG_RUNTIME_DIR", filepath.Join(root, "run"))
	f := &serviceFixture{t: t, stateDir: filepath.Join(root, "workers"), work: filepath.Join(root, "work"), log: filepath.Join(root, "services.log")}
	if err := os.MkdirAll(f.work, 0o700); err != nil {
		t.Fatal(err)
	}
	f.old = f.newServer()
	t.Cleanup(f.killAll)
	return f
}

func (f *serviceFixture) killAll() {
	for _, line := range f.lines() {
		var name string
		var pid int
		if _, err := fmt.Sscanf(line, "start %s %d", &name, &pid); err == nil && pid > 1 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	}
	// Each supervisor records the exit; wait so the temp dir can be removed.
	deadline := time.Now().Add(5 * time.Second)
	for _, server := range f.servers {
		server.hostJobs.Range(func(_, value any) bool {
			job := value.(*hostJob)
			if job.cmd != nil {
				waitHostJobExited(job, deadline)
			}
			return true
		})
	}
}

func (f *serviceFixture) lines() []string {
	file, err := os.Open(f.log)
	if err != nil {
		return nil
	}
	defer file.Close()
	var lines []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	return lines
}

func (f *serviceFixture) events(prefix string) []string {
	var names []string
	for _, line := range f.lines() {
		if fields := strings.Fields(line); len(fields) >= 2 && fields[0] == prefix {
			names = append(names, fields[1])
		}
	}
	return names
}

func freeServicePort(t *testing.T) int {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

type fakeService struct {
	name      string
	status    int
	depends   []string
	accept    []int
	ignore    bool
	delayMS   int
	graceSecs int
}

func (f *serviceFixture) spec(service fakeService, port int) ServiceSpec {
	env := map[string]string{
		"RELAY_SERVICE_FAKE_ADDR":   fmt.Sprintf("127.0.0.1:%d", port),
		"RELAY_SERVICE_FAKE_NAME":   service.name,
		"RELAY_SERVICE_FAKE_LOG":    f.log,
		"RELAY_SERVICE_FAKE_SECRET": "s3cr3t-value",
	}
	if service.status != 0 {
		env["RELAY_SERVICE_FAKE_STATUS"] = strconv.Itoa(service.status)
	}
	if service.ignore {
		env["RELAY_SERVICE_FAKE_IGNORE_TERM"] = "1"
	}
	if service.delayMS > 0 {
		env["RELAY_SERVICE_FAKE_DELAY_MS"] = strconv.Itoa(service.delayMS)
	}
	grace := service.graceSecs
	if grace == 0 {
		grace = 10
	}
	return ServiceSpec{
		Name: service.name, Argv: []string{os.Args[0], "-test.run=^TestServiceFakeProcess$"}, Cwd: f.work, Env: env,
		DependsOn: service.depends, StartupGraceSeconds: grace,
		Health: &ServiceHealth{TCP: strconv.Itoa(port), HTTPPath: "/health", Accept: service.accept},
	}
}

// startOld runs a service as an ordinary relay_exec job on the old supervisor,
// declares it bound to that job, and waits until it is healthy.
func (f *serviceFixture) startOld(store *ServiceStore, service fakeService) ServiceSpec {
	f.t.Helper()
	spec := f.spec(service, freeServicePort(f.t))
	jobID := service.name + "-r0562"
	if _, err := f.old.hostRPC(hostRequest{RequestID: "req-" + jobID, Operation: "exec", JobID: jobID, Argv: spec.Argv, Cwd: spec.Cwd, Env: spec.Env}); err != nil {
		f.t.Fatal(err)
	}
	f.waitHealthy(spec)
	if _, err := store.Declare(spec, jobID); err != nil {
		f.t.Fatal(err)
	}
	return spec
}

func (f *serviceFixture) waitHealthy(spec ServiceSpec) {
	f.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for probeServiceHealth(spec.Health, time.Second) != nil {
		if time.Now().After(deadline) {
			f.t.Fatalf("%s never became healthy", spec.Name)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (f *serviceFixture) upgrade(server *Server) *ServiceUpgrade {
	store, err := OpenServiceStore(f.stateDir, "node-a")
	if err != nil {
		f.t.Fatal(err)
	}
	return &ServiceUpgrade{Store: store, stateDir: f.stateDir, jobs: inProcessJobs{server}}
}

func (f *serviceFixture) store() *ServiceStore {
	store, err := OpenServiceStore(f.stateDir, "node-a")
	if err != nil {
		f.t.Fatal(err)
	}
	return store
}

func jobState(t *testing.T, server *Server, jobID string) serviceJobStatus {
	t.Helper()
	status, err := serviceStatus(inProcessJobs{server}, jobID)
	if err != nil {
		t.Fatal(err)
	}
	return status
}

func equalServiceStrings(a, b []string) bool {
	return strings.Join(a, ",") == strings.Join(b, ",")
}

func TestServiceUpgradeStopsAndRelaunchesInDependencyOrder(t *testing.T) {
	f := newServiceFixture(t)
	store := f.store()
	// One API answers 401 on its health path, which is declared healthy.
	f.startOld(store, fakeService{name: "api", status: http.StatusUnauthorized, accept: []int{401, 403, 404}})
	f.startOld(store, fakeService{name: "gateway", depends: []string{"api"}})
	f.startOld(store, fakeService{name: "web", depends: []string{"gateway"}})

	upgrade := f.upgrade(f.old)
	plan, err := upgrade.Plan()
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Blockers) != 0 || len(plan.Stop) != 3 {
		t.Fatalf("plan = %+v", plan)
	}
	if err := upgrade.Begin(plan); err != nil {
		t.Fatal(err)
	}
	if got := f.events("stop"); !equalServiceStrings(got, []string{"web", "gateway", "api"}) {
		t.Fatalf("stop order = %v", got)
	}
	for _, name := range []string{"api", "gateway", "web"} {
		if jobState(t, f.old, name+"-r0562").live() {
			t.Fatalf("%s still runs after Begin", name)
		}
	}
	// The stopped services no longer defer the old supervisor's upgrade.
	if err := f.old.prepareHostUpgrade(); err != nil {
		t.Fatalf("old supervisor still defers: %v", err)
	}

	// The replacement supervisor shares the state directory.
	replacement := f.newServer()
	upgrade.jobs = inProcessJobs{replacement}
	if err := upgrade.Relaunch(ServiceResumeOptions{}); err != nil {
		t.Fatal(err)
	}
	if got := f.events("start"); !equalServiceStrings(got, []string{"api", "gateway", "web", "api", "gateway", "web"}) {
		t.Fatalf("start order = %v", got)
	}
	services, err := store.Services()
	if err != nil {
		t.Fatal(err)
	}
	for _, service := range services {
		want := serviceJobID(service.Name, 1)
		if service.JobID != want || service.Generation != 1 {
			t.Fatalf("%s bound to %s generation %d, want %s", service.Name, service.JobID, service.Generation, want)
		}
		if status := jobState(t, replacement, want); status.record.State != "running" {
			t.Fatalf("%s is %s", want, status.record.State)
		}
	}
	var summary strings.Builder
	upgrade.Summary(&summary)
	for _, want := range []string{"api-r0562", "svc-api-g1", "svc-web-g1", "healthy"} {
		if !strings.Contains(summary.String(), want) {
			t.Fatalf("summary lacks %q:\n%s", want, summary.String())
		}
	}
	if strings.Contains(summary.String(), "s3cr3t") || strings.Contains(summary.String(), "test.run") {
		t.Fatalf("summary shows command or environment:\n%s", summary.String())
	}
	journal, err := store.loadJournal()
	if err != nil || journal == nil || !journal.finished() {
		t.Fatalf("journal = %+v, %v", journal, err)
	}
	if active, err := store.HasWork(); err != nil || !active {
		t.Fatalf("declarations no longer active: %v %v", active, err)
	}

	// The next upgrade uses the next generation, never a reused one.
	next := f.upgrade(replacement)
	plan, err = next.Plan()
	if err != nil || len(plan.Stop) != 3 {
		t.Fatalf("second plan = %+v, %v", plan, err)
	}
	if err := next.Begin(plan); err != nil {
		t.Fatal(err)
	}
	for _, entry := range next.journal.Entries {
		if entry.JobID != serviceJobID(entry.Spec.Name, 2) {
			t.Fatalf("second upgrade journals %s", entry.JobID)
		}
	}
	if err := next.Relaunch(ServiceResumeOptions{}); err != nil {
		t.Fatal(err)
	}
}

func TestServiceUpgradeRefusesUndeclaredJobsNamingThem(t *testing.T) {
	f := newServiceFixture(t)
	store := f.store()
	f.startOld(store, fakeService{name: "api"})
	other := f.spec(fakeService{name: "other"}, freeServicePort(t))
	if _, err := f.old.hostRPC(hostRequest{RequestID: "req-other", Operation: "exec", JobID: "notebook-r12", Argv: other.Argv, Cwd: other.Cwd, Env: other.Env}); err != nil {
		t.Fatal(err)
	}
	f.waitHealthy(other)
	// A peer listener is drained by the supervisor, never counted here.
	start, err := processStartIdentity(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	listenerDir := filepath.Join(f.stateDir, "host-jobs", "listener-1")
	if err := os.MkdirAll(listenerDir, 0o700); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(hostJobRecord{JobID: "listener-1", Kind: hostJobKindPeerListener, State: "running", PID: os.Getpid(), ProcessStart: start})
	if err := os.WriteFile(filepath.Join(listenerDir, "record.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	declarations, _ := os.ReadFile(store.declarationsPath())

	upgrade := f.upgrade(f.old)
	plan, err := upgrade.Plan()
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Listeners) != 1 || plan.Listeners[0].JobID != "listener-1" {
		t.Fatalf("listeners = %+v", plan.Listeners)
	}
	err = upgrade.Begin(plan)
	if err == nil || !strings.Contains(err.Error(), "notebook-r12 (pid ") || !strings.Contains(err.Error(), "kind exec") ||
		strings.Contains(err.Error(), "listener-1") || strings.Contains(err.Error(), "api-r0562") {
		t.Fatalf("refusal = %v", err)
	}
	if upgrade.Started() || len(f.events("stop")) != 0 || !jobState(t, f.old, "api-r0562").live() {
		t.Fatal("a refused upgrade stopped something")
	}
	if _, err := os.Lstat(store.journalPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("refused upgrade wrote a journal: %v", err)
	}
	if after, _ := os.ReadFile(store.declarationsPath()); string(after) != string(declarations) {
		t.Fatal("refused upgrade changed the declarations")
	}
	names, err := DescribeLiveHostJobs(f.stateDir)
	if err != nil || !strings.Contains(names, "notebook-r12") || strings.Contains(names, "listener-1") {
		t.Fatalf("described live jobs = %q, %v", names, err)
	}
}

func TestServiceUpgradePlanChangesNothing(t *testing.T) {
	f := newServiceFixture(t)
	store := f.store()
	f.startOld(store, fakeService{name: "api"})
	before, _ := os.ReadFile(store.declarationsPath())
	plan, err := f.upgrade(f.old).Plan()
	if err != nil {
		t.Fatal(err)
	}
	var out strings.Builder
	plan.Print(&out)
	if !strings.Contains(out.String(), "stop then relaunch: api (job api-r0562") || strings.Contains(out.String(), "s3cr3t") {
		t.Fatalf("plan output:\n%s", out.String())
	}
	after, _ := os.ReadFile(store.declarationsPath())
	if string(before) != string(after) || len(f.events("stop")) != 0 || !jobState(t, f.old, "api-r0562").live() {
		t.Fatal("planning changed something")
	}
	if _, err := os.Lstat(store.journalPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("planning wrote a journal")
	}
}

func TestServiceUpgradeWithoutDeclarationsIsInactive(t *testing.T) {
	f := newServiceFixture(t)
	upgrade := f.upgrade(f.old)
	if active, err := upgrade.Active(); err != nil || active {
		t.Fatalf("active = %v, %v", active, err)
	}
	if _, err := os.Lstat(filepath.Join(f.stateDir, "services")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("checking for declarations created the services directory")
	}
}

// The client dies after the stops; a later run finishes from the journal and
// starts each service exactly once, under the journaled generation.
func TestServiceUpgradeResumesAfterCrashBetweenStopAndRelaunch(t *testing.T) {
	for _, point := range []string{"after-journal", "after-stops"} {
		t.Run(point, func(t *testing.T) {
			f := newServiceFixture(t)
			store := f.store()
			f.startOld(store, fakeService{name: "api"})
			f.startOld(store, fakeService{name: "web", depends: []string{"api"}})
			first := f.upgrade(f.old)
			plan, err := first.Plan()
			if err != nil {
				t.Fatal(err)
			}
			if point == "after-journal" {
				if _, err := first.newJournal(plan); err != nil {
					t.Fatal(err)
				}
			} else if err := first.Begin(plan); err != nil {
				t.Fatal(err)
			}
			first = nil // the client is gone

			// The next upgrade-supervisor run adopts the journal rather than planning anew.
			second := f.upgrade(f.old)
			plan, err = second.Plan()
			if err != nil || !plan.Resume {
				t.Fatalf("resume plan = %+v, %v", plan, err)
			}
			if err := second.Begin(plan); err != nil {
				t.Fatal(err)
			}
			replacement := f.newServer()
			second.jobs = inProcessJobs{replacement}
			if err := second.Relaunch(ServiceResumeOptions{}); err != nil {
				t.Fatal(err)
			}
			if got := f.events("start"); !equalServiceStrings(got, []string{"api", "web", "api", "web"}) {
				t.Fatalf("starts = %v", got)
			}
			for _, name := range []string{"api", "web"} {
				if !jobState(t, replacement, serviceJobID(name, 1)).live() {
					t.Fatalf("%s generation 1 not running", name)
				}
				if jobState(t, replacement, serviceJobID(name, 2)).known {
					t.Fatalf("%s got a second generation", name)
				}
			}
			// A further resume finds nothing to do and starts nothing.
			if err := f.upgrade(replacement).Relaunch(ServiceResumeOptions{}); err != nil {
				t.Fatal(err)
			}
			if len(f.events("start")) != 4 {
				t.Fatal("finished journal relaunched again")
			}
		})
	}
}

// A launch whose answer was lost is queried under the same ID and never
// executed again or under another ID.
func TestServiceUpgradeUncertainLaunchQueriesSameID(t *testing.T) {
	t.Run("lost-response", func(t *testing.T) {
		f := newServiceFixture(t)
		store := f.store()
		f.startOld(store, fakeService{name: "api"})
		upgrade := f.upgrade(f.old)
		plan, _ := upgrade.Plan()
		if err := upgrade.Begin(plan); err != nil {
			t.Fatal(err)
		}
		replacement := f.newServer()
		lossy := &lossyJobs{inProcessJobs: inProcessJobs{replacement}}
		upgrade.jobs = lossy
		if err := upgrade.Relaunch(ServiceResumeOptions{}); err != nil {
			t.Fatal(err)
		}
		if lossy.lost != 1 || !equalServiceStrings(f.events("start"), []string{"api", "api"}) {
			t.Fatalf("lost %d, starts %v", lossy.lost, f.events("start"))
		}
		if jobState(t, replacement, serviceJobID("api", 2)).known {
			t.Fatal("uncertain launch was retried under a new ID")
		}
	})
	t.Run("crash-after-send", func(t *testing.T) {
		f := newServiceFixture(t)
		store := f.store()
		f.startOld(store, fakeService{name: "api"})
		upgrade := f.upgrade(f.old)
		plan, _ := upgrade.Plan()
		if err := upgrade.Begin(plan); err != nil {
			t.Fatal(err)
		}
		// The client recorded its intent and sent the exec, then died.
		entry := upgrade.journal.Entries[0]
		entry.Launch = serviceLaunchIntent
		if err := store.saveJournal(upgrade.journal); err != nil {
			t.Fatal(err)
		}
		replacement := f.newServer()
		if _, err := replacement.hostRPC(hostRequest{RequestID: "req-sent", Operation: "exec", JobID: entry.JobID, Argv: entry.Spec.Argv, Cwd: entry.Spec.Cwd, Env: entry.Spec.Env}); err != nil {
			t.Fatal(err)
		}
		// A later supervisor no longer controls it, yet must not run it twice.
		later := f.newServer()
		resume := f.upgrade(later)
		if err := resume.Relaunch(ServiceResumeOptions{}); err != nil {
			t.Fatal(err)
		}
		if got := f.events("start"); !equalServiceStrings(got, []string{"api", "api"}) {
			t.Fatalf("starts = %v", got)
		}
		services, _ := store.Services()
		if services[0].JobID != entry.JobID {
			t.Fatalf("bound to %s", services[0].JobID)
		}
	})
}

// A relaunch that never becomes healthy is reported, its dependents are not
// started, and nothing is retried.
func TestServiceUpgradeHealthFailureStopsRelaunch(t *testing.T) {
	f := newServiceFixture(t)
	store := f.store()
	f.startOld(store, fakeService{name: "api"})
	f.startOld(store, fakeService{name: "web", depends: []string{"api"}})
	upgrade := f.upgrade(f.old)
	plan, _ := upgrade.Plan()
	if err := upgrade.Begin(plan); err != nil {
		t.Fatal(err)
	}
	// The api now answers 503, which is not accepted.
	for _, entry := range upgrade.journal.Entries {
		if entry.Spec.Name == "api" {
			entry.Spec.Env["RELAY_SERVICE_FAKE_STATUS"] = "503"
			entry.Spec.StartupGraceSeconds = 1
		}
	}
	replacement := f.newServer()
	upgrade.jobs = inProcessJobs{replacement}
	err := upgrade.Relaunch(ServiceResumeOptions{})
	if err == nil || !strings.Contains(err.Error(), "api") {
		t.Fatalf("relaunch = %v", err)
	}
	if jobState(t, replacement, serviceJobID("web", 1)).known {
		t.Fatal("a dependent of an unhealthy service was started")
	}
	if got := f.events("start"); !equalServiceStrings(got, []string{"api", "web", "api"}) {
		t.Fatalf("starts = %v (retried?)", got)
	}
	journal, _ := store.loadJournal()
	if journal == nil || journal.finished() {
		t.Fatal("failed relaunch finished its journal")
	}
	var summary strings.Builder
	upgrade.Summary(&summary)
	if !strings.Contains(summary.String(), "unhealthy after 1s") {
		t.Fatalf("summary:\n%s", summary.String())
	}
}

// A service that will not stop aborts the upgrade; those already stopped are
// relaunched and the stubborn one keeps its job.
func TestServiceUpgradeStopFailureRestoresStoppedServices(t *testing.T) {
	previous := serviceStopTimeout
	serviceStopTimeout = time.Second
	t.Cleanup(func() { serviceStopTimeout = previous })
	f := newServiceFixture(t)
	store := f.store()
	f.startOld(store, fakeService{name: "api", ignore: true})
	f.startOld(store, fakeService{name: "web", depends: []string{"api"}})
	upgrade := f.upgrade(f.old)
	plan, _ := upgrade.Plan()
	err := upgrade.Begin(plan)
	if err == nil || !strings.Contains(err.Error(), "api") || !upgrade.Started() {
		t.Fatalf("begin = %v", err)
	}
	if err := upgrade.Relaunch(ServiceResumeOptions{}); err != nil {
		t.Fatal(err)
	}
	if !jobState(t, f.old, "api-r0562").live() || !jobState(t, f.old, serviceJobID("web", 1)).live() {
		t.Fatal("services were not restored")
	}
	services, _ := store.Services()
	bound := map[string]string{}
	for _, service := range services {
		bound[service.Name] = service.JobID
	}
	if bound["api"] != "api-r0562" || bound["web"] != serviceJobID("web", 1) {
		t.Fatalf("bindings = %v", bound)
	}
}

func TestServiceHealthProbe(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/auth":
			w.WriteHeader(http.StatusUnauthorized)
		case "/moved":
			http.Redirect(w, r, "/auth", http.StatusFound)
		default:
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer server.Close()
	address := strings.TrimPrefix(server.URL, "http://")
	cases := []struct {
		health ServiceHealth
		ok     bool
	}{
		{ServiceHealth{TCP: address}, true},
		{ServiceHealth{TCP: address, HTTPPath: "/"}, true},
		{ServiceHealth{TCP: address, HTTPPath: "/auth"}, false},
		{ServiceHealth{TCP: address, HTTPPath: "/auth", Accept: []int{401, 403, 404}}, true},
		{ServiceHealth{TCP: address, HTTPPath: "/moved", Accept: []int{401}}, false},
		{ServiceHealth{TCP: address, HTTPPath: "/moved", Accept: []int{302}}, true},
		{ServiceHealth{TCP: strconv.Itoa(freeServicePort(t))}, false},
	}
	for _, c := range cases {
		if err := probeServiceHealth(&c.health, time.Second); (err == nil) != c.ok {
			t.Errorf("%+v: %v", c.health, err)
		}
	}
	directory, err := os.MkdirTemp("", "rsvc")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "h.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	go http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) }))
	defer listener.Close()
	if err := probeServiceHealth(&ServiceHealth{Unix: socket, HTTPPath: "/", Accept: []int{404}}, time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestServiceDeclarationsValidateAndStayPerHost(t *testing.T) {
	f := newServiceFixture(t)
	store := f.store()
	spec := func(name string, depends ...string) ServiceSpec {
		return ServiceSpec{Name: name, Command: "serve", Cwd: f.work, DependsOn: depends}
	}
	if _, err := store.Declare(spec("web", "api"), ""); err == nil {
		t.Fatal("missing dependency accepted")
	}
	if _, err := store.Declare(spec("api"), ""); err != nil {
		t.Fatal(err)
	}
	declared, err := store.Declare(spec("web", "api"), "")
	if err != nil || declared.StartupGraceSeconds != defaultServiceStartupGrace {
		t.Fatalf("declare = %+v, %v", declared, err)
	}
	if _, err := store.Declare(spec("api", "web"), ""); err == nil || !strings.Contains(err.Error(), "cycle") {
		t.Fatalf("cycle = %v", err)
	}
	if err := store.Undeclare("api"); err == nil {
		t.Fatal("undeclared a dependency")
	}
	for _, bad := range []ServiceSpec{
		{Name: "bad name", Command: "x", Cwd: f.work},
		{Name: "x", Command: "x", Argv: []string{"x"}, Cwd: f.work},
		{Name: "x", Command: "x", Cwd: "relative"},
		{Name: "x", Command: "x", Cwd: f.work, Health: &ServiceHealth{}},
		{Name: "x", Command: "x", Cwd: f.work, Health: &ServiceHealth{TCP: "1", Accept: []int{200}}},
	} {
		if _, err := store.Declare(bad, ""); err == nil {
			t.Errorf("accepted %+v", bad)
		}
	}
	info, err := os.Stat(store.declarationsPath())
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("declarations mode = %v, %v", info, err)
	}
	other, _ := OpenServiceStore(f.stateDir, "node-b")
	if services, err := other.Services(); err != nil || len(services) != 0 {
		t.Fatalf("another host sees %d services, %v", len(services), err)
	}
	if active, _ := other.HasWork(); active {
		t.Fatal("another host would act on these declarations")
	}
	release, err := store.Lock(false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Lock(false); err == nil {
		t.Fatal("service lock is not exclusive")
	}
	release()
}

// The upgrade client reaches the supervisor over the node stream on its
// socket, as an older supervisor serves it.
func TestServiceJobsOverSupervisorSocket(t *testing.T) {
	f := newServiceFixture(t)
	directory, err := os.MkdirTemp("", "rsvc")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "s.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go f.old.serveConnection(connection)
		}
	}()
	jobs := socketServiceJobs{socket: socket, timeout: 10 * time.Second}
	if status, err := serviceStatus(jobs, "never-started"); err != nil || status.known {
		t.Fatalf("unknown job = %+v, %v", status, err)
	}
	if _, err := jobs.call(hostRequest{RequestID: serviceRequestID(), Operation: "exec", JobID: "sleeper", Argv: []string{"/bin/sleep", "30"}, Cwd: f.work}); err != nil {
		t.Fatal(err)
	}
	status, err := serviceStatus(jobs, "sleeper")
	if err != nil || status.record.State != "running" || status.record.PID <= 1 {
		t.Fatalf("status = %+v, %v", status, err)
	}
	t.Cleanup(func() { _ = syscall.Kill(-status.record.PID, syscall.SIGKILL) })
	if _, err := jobs.call(hostRequest{RequestID: serviceRequestID(), Operation: "cancel", JobID: "sleeper"}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		status, err = serviceStatus(jobs, "sleeper")
		if err == nil && !status.live() {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("cancelled job = %+v, %v", status, err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	missing := socketServiceJobs{socket: filepath.Join(directory, "absent.sock")}
	if _, err := missing.call(hostRequest{RequestID: serviceRequestID(), Operation: "status", JobID: "x"}); !serviceUnavailable(err) {
		t.Fatalf("absent supervisor = %v", err)
	}
}

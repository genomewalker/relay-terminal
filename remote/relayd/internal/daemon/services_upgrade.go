package daemon

// Supervisor upgrade with declared services. The running supervisor decides
// whether it may be replaced, and an older one cannot stop services itself,
// so the new relayd client orchestrates through RPCs every recent supervisor
// serves (status, cancel, exec):
//
//  1. plan: declared services with a live job are the stop set; any other
//     live host job (peer listeners aside) refuses the upgrade, naming it;
//  2. journal the full launch spec and the next generation of every service
//     in the stop set, durably, before the first stop;
//  3. stop in reverse dependency order and wait for each job to exit;
//  4. the caller prepares and replaces the supervisor as before;
//  5. relaunch in dependency order as svc-<name>-g<N>, waiting for health
//     within each service's startup grace.
//
// If anything fails after the first stop, the caller relaunches from the
// journal against whichever supervisor is serving. A launch whose outcome is
// unknown is only ever queried and resent under the same job ID, which the
// supervisor never executes twice. The journal survives a crash; the next
// upgrade-supervisor or `relayd service resume` finishes it.

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"text/tabwriter"
	"time"
)

const (
	serviceJournalStopping    = "stopping"
	serviceJournalRelaunching = "relaunching"
	serviceJournalFinished    = "finished"

	serviceLaunchIntent  = "intent"
	serviceLaunchRunning = "running"
	serviceLaunchFailed  = "failed"
	serviceLaunchKept    = "kept"
)

var (
	serviceStopTimeout     = 30 * time.Second
	serviceHandoffWait     = 40 * time.Second
	serviceHealthInterval  = 250 * time.Millisecond
	serviceNoProbeSettle   = 2 * time.Second
	serviceStatusPollDelay = 100 * time.Millisecond
)

type serviceJournalEntry struct {
	Spec         ServiceSpec `json:"spec"`
	Level        int         `json:"level"`
	OldJobID     string      `json:"old_job_id"`
	OldPID       int         `json:"old_pid,omitempty"`
	HealthBefore string      `json:"health_before"`
	Stopped      bool        `json:"stopped"`
	Generation   int         `json:"generation"`
	JobID        string      `json:"job_id"`
	Launch       string      `json:"launch,omitempty"`
	PID          int         `json:"pid,omitempty"`
	HealthAfter  string      `json:"health_after,omitempty"`
	Error        string      `json:"error,omitempty"`
}

type serviceJournal struct {
	Version   int                    `json:"version"`
	Host      string                 `json:"host"`
	CreatedAt string                 `json:"created_at"`
	Phase     string                 `json:"phase"`
	Entries   []*serviceJournalEntry `json:"entries"`
}

func (j *serviceJournal) finished() bool { return j.Phase == serviceJournalFinished }

func (s *ServiceStore) loadJournal() (*serviceJournal, error) {
	var journal serviceJournal
	if err := readServiceJSON(s.journalPath(), &journal); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	if journal.Version != serviceFileVersion || journal.Host != s.host {
		return nil, errors.New("service journal belongs to another host or format; refusing to use it")
	}
	return &journal, nil
}

func (s *ServiceStore) saveJournal(journal *serviceJournal) error {
	return writeServiceJSON(s.journalPath(), journal)
}

// ServiceUpgrade orchestrates one host's declared services around a
// supervisor replacement. Create it with NewServiceUpgrade, call Acquire, and
// Release when done.
type ServiceUpgrade struct {
	Store    *ServiceStore
	stateDir string
	jobs     serviceJobs
	journal  *serviceJournal
	release  func()
}

// NewServiceUpgrade talks to the supervisor at socket. An empty state
// directory means the supervisor's default.
func NewServiceUpgrade(stateDir, socket string) (*ServiceUpgrade, error) {
	if stateDir == "" {
		stateDir = defaultWorkerStateDir()
	}
	store, err := OpenServiceStore(stateDir, "")
	if err != nil {
		return nil, err
	}
	return &ServiceUpgrade{Store: store, stateDir: stateDir, jobs: socketServiceJobs{socket: socket}}, nil
}

// Active reports whether this host has declarations or an unfinished journal.
func (u *ServiceUpgrade) Active() (bool, error) { return u.Store.HasWork() }

// Acquire holds the host's service lock until Release. It is idempotent: a
// second flock on a new descriptor would wait on this process's own lock.
func (u *ServiceUpgrade) Acquire() error {
	if u.release != nil {
		return nil
	}
	release, err := u.Store.Lock(true)
	if err != nil {
		return err
	}
	u.release = release
	return nil
}

func (u *ServiceUpgrade) Release() {
	if u.release != nil {
		u.release()
		u.release = nil
	}
}

// ServicePlan is what an upgrade would do; computing it changes nothing.
type ServicePlan struct {
	Host      string
	Resume    bool
	Stop      []ServicePlanEntry // reverse dependency order
	Idle      []ServicePlanEntry // declared but not running: left alone
	Blockers  []ServiceLedgerJob // undeclared live jobs: the upgrade defers
	Listeners []ServiceLedgerJob // drained and resumed by the supervisor
	journal   *serviceJournal
}

type ServicePlanEntry struct {
	Name  string
	JobID string
	PID   int
	Level int
}

// Plan reads the declarations, any unfinished journal and the ledger.
func (u *ServiceUpgrade) Plan() (ServicePlan, error) {
	plan := ServicePlan{Host: u.Store.host}
	journal, err := u.Store.loadJournal()
	if err != nil {
		return plan, err
	}
	file, err := u.Store.load()
	if err != nil {
		return plan, err
	}
	levels, err := serviceLaunchLevels(file.Services)
	if err != nil {
		return plan, err
	}
	live, err := scanLiveHostJobs(u.stateDir)
	if err != nil {
		return plan, err
	}
	liveByID := map[string]ServiceLedgerJob{}
	for _, job := range live {
		liveByID[job.JobID] = job
	}
	declaredJobs := map[string]bool{}
	if journal != nil && !journal.finished() {
		plan.Resume, plan.journal = true, journal
		for _, entry := range journal.Entries {
			declaredJobs[entry.OldJobID], declaredJobs[entry.JobID] = true, true
			if !entry.Stopped {
				job := liveByID[entry.OldJobID]
				plan.Stop = append(plan.Stop, ServicePlanEntry{Name: entry.Spec.Name, JobID: entry.OldJobID, PID: job.PID, Level: entry.Level})
			}
		}
		reverseServicePlan(plan.Stop)
	}
	byName := map[string]ServiceDeclaration{}
	for _, service := range file.Services {
		byName[service.Name] = service
		if service.JobID != "" {
			declaredJobs[service.JobID] = true
		}
	}
	if !plan.Resume {
		for level, names := range levels {
			for _, name := range names {
				service := byName[name]
				entry := ServicePlanEntry{Name: name, JobID: service.JobID, Level: level}
				if job, ok := liveByID[service.JobID]; ok && service.JobID != "" {
					entry.PID = job.PID
					plan.Stop = append(plan.Stop, entry)
				} else {
					plan.Idle = append(plan.Idle, entry)
				}
			}
		}
		reverseServicePlan(plan.Stop)
	}
	for _, job := range live {
		switch {
		case declaredJobs[job.JobID]:
		case job.Kind == hostJobKindPeerListener:
			plan.Listeners = append(plan.Listeners, job)
		default:
			plan.Blockers = append(plan.Blockers, job)
		}
	}
	return plan, nil
}

func reverseServicePlan(entries []ServicePlanEntry) {
	for i, j := 0, len(entries)-1; i < j; i, j = i+1, j-1 {
		entries[i], entries[j] = entries[j], entries[i]
	}
}

// BlockerError names undeclared live jobs. Nothing has been stopped.
func (p ServicePlan) BlockerError() error {
	if len(p.Blockers) == 0 {
		return nil
	}
	names := make([]string, len(p.Blockers))
	for i, job := range p.Blockers {
		names[i] = job.describe()
	}
	return fmt.Errorf("upgrade deferred: %d undeclared live host jobs: %s; declare them with `relayd service declare` or stop them; nothing was stopped",
		len(p.Blockers), strings.Join(names, ", "))
}

// Print writes the plan without command bodies or environment values.
func (p ServicePlan) Print(w io.Writer) {
	fmt.Fprintf(w, "declared services on %s:\n", p.Host)
	if p.Resume {
		fmt.Fprintln(w, "  an unfinished upgrade journal will be completed first")
	}
	if len(p.Stop) == 0 {
		fmt.Fprintln(w, "  stop: none")
	}
	for _, entry := range p.Stop {
		fmt.Fprintf(w, "  stop then relaunch: %s (job %s, pid %d)\n", entry.Name, entry.JobID, entry.PID)
	}
	for _, entry := range p.Idle {
		job := entry.JobID
		if job == "" {
			job = "none bound"
		}
		fmt.Fprintf(w, "  not running, left alone: %s (job %s)\n", entry.Name, job)
	}
	for _, job := range p.Listeners {
		fmt.Fprintf(w, "  peer listener drained by the supervisor: %s\n", job.describe())
	}
	for _, job := range p.Blockers {
		fmt.Fprintf(w, "  undeclared live job (defers the upgrade): %s\n", job.describe())
	}
}

// Begin journals and stops the stop set. With an unfinished journal it
// continues that journal instead of planning again. When it returns an error
// after stopping anything, the caller must call Relaunch to restore.
func (u *ServiceUpgrade) Begin(plan ServicePlan) error {
	if plan.Resume {
		u.journal = plan.journal
	} else {
		if err := plan.BlockerError(); err != nil {
			return err
		}
		if len(plan.Stop) == 0 {
			return nil
		}
		journal, err := u.newJournal(plan)
		if err != nil {
			return err
		}
		u.journal = journal
	}
	if u.journal.Phase != serviceJournalStopping {
		return nil
	}
	for i := len(u.journal.Entries) - 1; i >= 0; i-- {
		entry := u.journal.Entries[i]
		if entry.Stopped {
			continue
		}
		if err := u.stop(entry); err != nil {
			entry.Error = err.Error()
			_ = u.Store.saveJournal(u.journal)
			return fmt.Errorf("cannot stop service %s: %v", entry.Spec.Name, err)
		}
		entry.Stopped = true
		if err := u.Store.saveJournal(u.journal); err != nil {
			return err
		}
	}
	u.journal.Phase = serviceJournalRelaunching
	return u.Store.saveJournal(u.journal)
}

// Started reports whether Begin journaled anything that Relaunch must finish.
func (u *ServiceUpgrade) Started() bool { return u.journal != nil && !u.journal.finished() }

// newJournal allocates each service's next generation durably, then writes
// the journal before any stop. A generation lost to a crash between the two
// is simply never used.
func (u *ServiceUpgrade) newJournal(plan ServicePlan) (*serviceJournal, error) {
	file, err := u.Store.load()
	if err != nil {
		return nil, err
	}
	if file.Generations == nil {
		file.Generations = map[string]int{}
	}
	byName := map[string]ServiceDeclaration{}
	for _, service := range file.Services {
		byName[service.Name] = service
	}
	journal := &serviceJournal{Version: serviceFileVersion, Host: u.Store.host, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano), Phase: serviceJournalStopping}
	for i := len(plan.Stop) - 1; i >= 0; i-- {
		stop := plan.Stop[i]
		service, ok := byName[stop.Name]
		if !ok || service.JobID != stop.JobID {
			return nil, fmt.Errorf("service %s changed while planning; nothing was stopped", stop.Name)
		}
		generation := file.Generations[stop.Name]
		if service.Generation > generation {
			generation = service.Generation
		}
		generation++
		file.Generations[stop.Name] = generation
		journal.Entries = append(journal.Entries, &serviceJournalEntry{
			Spec: service.ServiceSpec, Level: stop.Level, OldJobID: stop.JobID, OldPID: stop.PID,
			HealthBefore: serviceHealthWord(service.Health), Generation: generation, JobID: serviceJobID(stop.Name, generation),
		})
	}
	if err := u.Store.save(file); err != nil {
		return nil, err
	}
	if err := u.Store.saveJournal(journal); err != nil {
		return nil, err
	}
	return journal, nil
}

// stop cancels a job its supervisor controls and waits for it to exit. A job
// the supervisor no longer controls cannot be cancelled over RPC; it is never
// signalled from here.
func (u *ServiceUpgrade) stop(entry *serviceJournalEntry) error {
	status, err := serviceStatus(u.jobs, entry.OldJobID)
	if err != nil {
		return err
	}
	if !status.live() {
		return nil
	}
	if status.record.State != "running" {
		return fmt.Errorf("job %s is %s and not controlled by this supervisor; stop it by hand", entry.OldJobID, status.record.State)
	}
	if _, err := u.jobs.call(hostRequest{RequestID: serviceRequestID(), Operation: "cancel", JobID: entry.OldJobID}); err != nil {
		return err
	}
	deadline := time.Now().Add(serviceStopTimeout)
	for {
		status, err := serviceStatus(u.jobs, entry.OldJobID)
		if err == nil && !status.live() {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("job %s did not exit within %s of SIGTERM", entry.OldJobID, serviceStopTimeout)
		}
		time.Sleep(serviceStatusPollDelay)
	}
}

// ServiceResumeOptions: RetryFailed gives a service whose relaunch has a
// definite failed outcome a new generation. An unknown outcome never does.
type ServiceResumeOptions struct {
	RetryFailed bool
}

// Relaunch finishes the journal against the supervisor serving now: services
// still running their old job are kept, stopped ones are launched level by
// level, and each level must be healthy before the next starts.
func (u *ServiceUpgrade) Relaunch(options ServiceResumeOptions) error {
	if u.journal == nil {
		journal, err := u.Store.loadJournal()
		if err != nil {
			return err
		}
		if journal == nil || journal.finished() {
			return nil
		}
		u.journal = journal
	}
	journal := u.journal
	if options.RetryFailed {
		if err := u.retryFailed(); err != nil {
			return err
		}
	}
	maxLevel := 0
	for _, entry := range journal.Entries {
		if entry.Level > maxLevel {
			maxLevel = entry.Level
		}
	}
	var failures []string
	for level := 0; level <= maxLevel && len(failures) == 0; level++ {
		var waiting []*serviceJournalEntry
		for _, entry := range journal.Entries {
			if entry.Level != level {
				continue
			}
			if !entry.Stopped {
				u.keep(entry)
				continue
			}
			if entry.Launch == serviceLaunchFailed {
				failures = append(failures, entry.Spec.Name)
				continue
			}
			if err := u.launch(entry); err != nil {
				entry.Error = err.Error()
				failures = append(failures, entry.Spec.Name)
				continue
			}
			waiting = append(waiting, entry)
		}
		if err := u.Store.saveJournal(journal); err != nil {
			return err
		}
		var group sync.WaitGroup
		for _, entry := range waiting {
			group.Add(1)
			go func(entry *serviceJournalEntry) {
				defer group.Done()
				u.awaitHealth(entry)
			}(entry)
		}
		group.Wait()
		for _, entry := range waiting {
			if entry.Launch == serviceLaunchFailed || strings.HasPrefix(entry.HealthAfter, "unhealthy") {
				failures = append(failures, entry.Spec.Name)
			}
		}
		if err := u.Store.saveJournal(journal); err != nil {
			return err
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf("relaunch stopped at %s; later services were not started; fix the cause and run `relayd service resume`",
			strings.Join(failures, ", "))
	}
	if err := u.bindRelaunched(); err != nil {
		return err
	}
	journal.Phase = serviceJournalFinished
	return u.Store.saveJournal(journal)
}

func (u *ServiceUpgrade) keep(entry *serviceJournalEntry) {
	if entry.Launch == serviceLaunchKept {
		return
	}
	entry.Launch, entry.JobID, entry.PID = serviceLaunchKept, entry.OldJobID, entry.OldPID
	entry.HealthAfter = serviceHealthWord(entry.Spec.Health)
}

// launch starts entry.JobID at most once. It always asks the supervisor about
// the same job ID first; an exec is sent only for an ID the supervisor does
// not know, and an exec whose answer was lost is followed by a status query,
// never by a new ID.
func (u *ServiceUpgrade) launch(entry *serviceJournalEntry) error {
	request := hostRequest{Operation: "exec", JobID: entry.JobID, Command: entry.Spec.Command, Argv: entry.Spec.Argv,
		Cwd: entry.Spec.Cwd, Env: entry.Spec.Env}
	handoffDeadline := time.Now().Add(serviceHandoffWait)
	for attempt := 0; attempt < 4; attempt++ {
		status, err := serviceStatus(u.jobs, entry.JobID)
		if err != nil {
			if _, refused := serviceRefused(err); !refused {
				continue
			}
			return err
		}
		if status.known {
			u.adopt(entry, status)
			return nil
		}
		entry.Launch = serviceLaunchIntent
		if err := u.Store.saveJournal(u.journal); err != nil {
			return err
		}
		request.RequestID = serviceRequestID()
		_, err = u.jobs.call(request)
		if err == nil {
			continue // the status query above reads the outcome
		}
		message, refused := serviceRefused(err)
		if !refused {
			continue // unknown outcome: query the same ID again
		}
		if serviceUnavailable(err) {
			return fmt.Errorf("launch not sent: %s", message)
		}
		if strings.Contains(message, "upgrade handoff in progress") && time.Now().Before(handoffDeadline) {
			attempt--
			time.Sleep(500 * time.Millisecond)
			continue
		}
		entry.Launch = serviceLaunchFailed
		return fmt.Errorf("launch refused: %s", message)
	}
	return fmt.Errorf("launch outcome of %s unknown; run `relayd service resume`, which queries it before anything else", entry.JobID)
}

func (u *ServiceUpgrade) adopt(entry *serviceJournalEntry, status serviceJobStatus) {
	entry.PID = status.record.PID
	if status.live() {
		entry.Launch = serviceLaunchRunning
		return
	}
	entry.Launch = serviceLaunchFailed
	entry.Error = "job " + hostJobOutcome(status.record)
}

func (u *ServiceUpgrade) awaitHealth(entry *serviceJournalEntry) {
	grace := time.Duration(entry.Spec.StartupGraceSeconds) * time.Second
	deadline := time.Now().Add(grace)
	if entry.Spec.Health == nil {
		settle := serviceNoProbeSettle
		if settle > grace {
			settle = grace
		}
		deadline = time.Now().Add(settle)
	}
	var last error
	for {
		status, err := serviceStatus(u.jobs, entry.JobID)
		if err == nil && status.known && !status.live() {
			u.adopt(entry, status)
			entry.HealthAfter = "unhealthy: exited during startup"
			return
		}
		if entry.Spec.Health != nil {
			if last = probeServiceHealth(entry.Spec.Health, serviceProbeTimeout); last == nil {
				entry.HealthAfter = "healthy"
				return
			}
		}
		if time.Now().After(deadline) {
			if entry.Spec.Health == nil {
				entry.HealthAfter = "none"
				return
			}
			entry.HealthAfter = fmt.Sprintf("unhealthy after %s: %v", grace, last)
			return
		}
		time.Sleep(serviceHealthInterval)
	}
}

// retryFailed gives each definitely failed launch a fresh generation.
func (u *ServiceUpgrade) retryFailed() error {
	file, err := u.Store.load()
	if err != nil {
		return err
	}
	if file.Generations == nil {
		file.Generations = map[string]int{}
	}
	changed := false
	for _, entry := range u.journal.Entries {
		if !entry.Stopped || (entry.Launch != serviceLaunchFailed && entry.Launch != serviceLaunchRunning) {
			continue
		}
		status, err := serviceStatus(u.jobs, entry.JobID)
		if err != nil {
			return err
		}
		if status.live() {
			continue
		}
		generation := file.Generations[entry.Spec.Name]
		if entry.Generation > generation {
			generation = entry.Generation
		}
		generation++
		file.Generations[entry.Spec.Name] = generation
		entry.Generation, entry.JobID = generation, serviceJobID(entry.Spec.Name, generation)
		entry.Launch, entry.PID, entry.HealthAfter, entry.Error = "", 0, "", ""
		changed = true
	}
	if !changed {
		return nil
	}
	if err := u.Store.save(file); err != nil {
		return err
	}
	return u.Store.saveJournal(u.journal)
}

// bindRelaunched points each declaration at its relaunched job.
func (u *ServiceUpgrade) bindRelaunched() error {
	file, err := u.Store.load()
	if err != nil {
		return err
	}
	for _, entry := range u.journal.Entries {
		if entry.Launch != serviceLaunchRunning {
			continue
		}
		for i := range file.Services {
			if file.Services[i].Name == entry.Spec.Name && file.Services[i].JobID == entry.OldJobID {
				file.Services[i].JobID, file.Services[i].Generation = entry.JobID, entry.Generation
			}
		}
	}
	return u.Store.save(file)
}

// Summary prints one row per journaled service. It never prints commands or
// environment values.
func (u *ServiceUpgrade) Summary(w io.Writer) {
	if u.journal == nil {
		return
	}
	table := tabwriter.NewWriter(w, 0, 4, 2, ' ', 0)
	fmt.Fprintln(table, "SERVICE\tOLD JOB (PID)\tNEW JOB (PID)\tHEALTH BEFORE\tHEALTH AFTER")
	for _, entry := range u.journal.Entries {
		newJob := "-"
		switch entry.Launch {
		case serviceLaunchKept:
			newJob = "kept " + entry.OldJobID
		case "":
		default:
			newJob = fmt.Sprintf("%s (%d)", entry.JobID, entry.PID)
		}
		after := entry.HealthAfter
		if after == "" {
			after = "-"
		}
		if entry.Launch == serviceLaunchFailed || entry.Launch == serviceLaunchIntent {
			after = entry.Launch
			if entry.Error != "" {
				after += ": " + entry.Error
			}
		}
		fmt.Fprintf(table, "%s\t%s (%d)\t%s\t%s\t%s\n", entry.Spec.Name, entry.OldJobID, entry.OldPID, newJob, entry.HealthBefore, after)
	}
	table.Flush()
}

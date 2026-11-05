// Package workorigin authenticates the transport on which a native Work
// provider supplies MCP metadata. Metadata alone is not an origin proof.
package workorigin

import (
	"errors"
	"fmt"
	"regexp"
)

const HelperPath = "/Applications/Relay.app/Contents/MacOS/relay-mcp"
const ProviderPath = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
const FrontendPath = "/Applications/Relay.app/Contents/MacOS/relay-work-mcp"
const CLIPath = "/Applications/Relay.app/Contents/MacOS/relayd"
const ApplicationPath = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"

var threadPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// Process is kernel identity, never argv or environment.
type Process struct {
	PID         int    `json:"pid"`
	Parent      int    `json:"parent"`
	UID         uint32 `json:"uid"`
	StartMicros int64  `json:"start_micros"`
	Executable  string `json:"executable"`
}
type Pipe struct {
	Handle, Peer       uint64
	Readable, Writable bool
}
type Evidence struct {
	Caller, Worker                         Process
	CallerInput, WorkerInput               Pipe
	CallerParentFD, WorkerParentFD         int
	CallerParentOutput, WorkerParentOutput Pipe
	Helper, Provider, Application          Process
	Input                                  Pipe
	ProviderFD                             int
	ProviderOutput                         Pipe
}
type Source struct {
	Thread    string   `json:"thread"`
	Transport Evidence `json:"transport"`
}
type sourceReader interface {
	process(int) (Process, error)
	pipe(int, int) (Pipe, error)
	pipes(int) (map[int]Pipe, error)
	uid() uint32
	trustedFrontend(Process) bool
}

// InspectMCP requires an installed Relay MCP helper whose stdin is the pipe
// written by the direct native Work provider, itself owned by ChatGPT. Merely
// running a helper below the provider (e.g. shell exec with redirected input)
// is insufficient. Identity is re-read after the descriptor checks.
func InspectMCP(helperPID int) (Evidence, error) { return inspectMCP(nativeReader{}, helperPID) }
func Authenticate(helperPID int, protectedThread string) (Source, error) {
	if !threadPattern.MatchString(protectedThread) {
		return Source{}, errors.New("native Work thread metadata unavailable")
	}
	evidence, err := InspectMCP(helperPID)
	if err != nil {
		return Source{}, err
	}
	return Source{Thread: protectedThread, Transport: evidence}, nil
}
func (e Evidence) Revalidate() error { return revalidate(nativeReader{}, e) }
func revalidate(r sourceReader, e Evidence) error {
	var current Evidence
	var err error
	if e.Caller.PID > 0 {
		current, err = inspectCaller(r, e.Caller.PID)
	} else if e.Worker.PID > 0 {
		current, err = inspectWorker(r, e.Worker.PID)
	} else {
		current, err = inspectMCP(r, e.Helper.PID)
	}
	if err != nil {
		return err
	}
	if current != e {
		return errors.New("native Work transport incarnation changed")
	}
	return nil
}
func inspectMCP(r sourceReader, pid int) (Evidence, error) {
	var e Evidence
	fail := func() (Evidence, error) { return Evidence{}, errors.New("native Work MCP transport unavailable") }
	if pid <= 1 {
		return fail()
	}
	var err error
	e.Helper, err = r.process(pid)
	if err != nil || e.Helper.PID != pid || e.Helper.UID != r.uid() || (e.Helper.Executable != HelperPath && !r.trustedFrontend(e.Helper)) || e.Helper.StartMicros <= 0 {
		return fail()
	}
	e.Provider, err = r.process(e.Helper.Parent)
	if err != nil || e.Provider.PID <= 1 || e.Provider.UID != r.uid() || e.Provider.Executable != ProviderPath || e.Provider.StartMicros <= 0 {
		return fail()
	}
	e.Application, err = r.process(e.Provider.Parent)
	if err != nil || e.Application.PID <= 1 || e.Application.UID != r.uid() || e.Application.Executable != ApplicationPath || e.Application.StartMicros <= 0 {
		return fail()
	}
	e.Input, err = r.pipe(pid, 0)
	if err != nil || !e.Input.Readable || e.Input.Writable || e.Input.Handle == 0 || e.Input.Peer == 0 || e.Input.Handle == e.Input.Peer {
		return fail()
	}
	peers, err := r.pipes(e.Provider.PID)
	if err != nil {
		return fail()
	}
	found := false
	for fd, p := range peers {
		if p.Writable && !p.Readable && p.Handle == e.Input.Peer && p.Peer == e.Input.Handle {
			if found {
				return Evidence{}, errors.New("ambiguous native Work input pipe")
			}
			e.ProviderFD = fd
			e.ProviderOutput = p
			found = true
		}
	}
	if !found {
		return fail()
	}
	for _, before := range []Process{e.Helper, e.Provider, e.Application} {
		after, err := r.process(before.PID)
		if err != nil || after != before {
			return fail()
		}
	}
	input, err := r.pipe(pid, 0)
	if err != nil || input != e.Input {
		return fail()
	}
	peer, err := r.pipe(e.Provider.PID, e.ProviderFD)
	if err != nil || peer != e.ProviderOutput {
		return fail()
	}
	return e, nil
}
func unavailable(err error) error { return fmt.Errorf("native Work kernel inspection: %w", err) }

// AuthenticateCaller derives all process identities from the kernel peer CLI.
// The CLI's stdin must be written by the trusted worker. If a stable frontend
// is used, the worker's stdin must in turn be written by that frontend.
func AuthenticateCaller(cliPID int, protectedThread string) (Source, error) {
	if !threadPattern.MatchString(protectedThread) {
		return Source{}, errors.New("native Work thread metadata unavailable")
	}
	e, err := inspectCaller(nativeReader{}, cliPID)
	if err != nil {
		return Source{}, err
	}
	return Source{Thread: protectedThread, Transport: e}, nil
}
func parentPipe(r sourceReader, child, parent int) (Pipe, int, Pipe, error) {
	input, err := r.pipe(child, 0)
	if err != nil || !input.Readable || input.Writable || input.Handle == 0 || input.Peer == 0 {
		return Pipe{}, 0, Pipe{}, errors.New("native caller input pipe unavailable")
	}
	outputs, err := r.pipes(parent)
	if err != nil {
		return Pipe{}, 0, Pipe{}, err
	}
	fd := -1
	var output Pipe
	for candidate, p := range outputs {
		if p.Writable && !p.Readable && p.Handle == input.Peer && p.Peer == input.Handle {
			if fd < 0 || candidate < fd {
				fd = candidate
				output = p
			}
		}
	}
	if fd < 0 {
		return Pipe{}, 0, Pipe{}, errors.New("native caller pipe has no verified parent writer")
	}
	again, err := r.pipe(child, 0)
	if err != nil || again != input {
		return Pipe{}, 0, Pipe{}, errors.New("native caller input changed")
	}
	current, err := r.pipe(parent, fd)
	if err != nil || current != output {
		return Pipe{}, 0, Pipe{}, errors.New("native caller parent writer changed")
	}
	return input, fd, output, nil
}

// AuthenticateWorker verifies the provider-origin metadata transport before a
// request worker mints the daemon packet. The daemon repeats the check for its
// kernel peer CLI using AuthenticateCaller.
func AuthenticateWorker(workerPID int, protectedThread string) (Source, error) {
	if !threadPattern.MatchString(protectedThread) {
		return Source{}, errors.New("native Work thread metadata unavailable")
	}
	e, err := inspectWorker(nativeReader{}, workerPID)
	if err != nil {
		return Source{}, err
	}
	return Source{Thread: protectedThread, Transport: e}, nil
}
func inspectWorker(r sourceReader, pid int) (Evidence, error) {
	var empty Evidence
	worker, err := r.process(pid)
	if err != nil || worker.Executable != HelperPath || worker.UID != r.uid() || worker.StartMicros <= 0 {
		return empty, errors.New("native Work request worker unavailable")
	}
	parent, err := r.process(worker.Parent)
	if err != nil {
		return empty, err
	}
	var e Evidence
	if parent.Executable == ProviderPath {
		return inspectMCP(r, worker.PID)
	}
	if !r.trustedFrontend(parent) {
		return empty, errors.New("native Work frontend code identity unavailable")
	}
	e, err = inspectMCP(r, parent.PID)
	if err != nil {
		return empty, err
	}
	e.Worker = worker
	// Each hop holds its writer open for the reader's lifetime and frames one
	// request, so a live writer is required here.
	e.WorkerInput, e.WorkerParentFD, e.WorkerParentOutput, err = parentPipe(r, worker.PID, parent.PID)
	if err != nil {
		return empty, err
	}
	again, err := r.process(worker.PID)
	if err != nil || again != worker {
		return empty, errors.New("native Work worker incarnation changed")
	}
	return e, nil
}
func inspectCaller(r sourceReader, cliPID int) (Evidence, error) {
	var empty Evidence
	cli, err := r.process(cliPID)
	if err != nil || cli.Executable != CLIPath || cli.UID != r.uid() || cli.StartMicros <= 0 {
		return empty, errors.New("native Work CLI identity unavailable")
	}
	e, err := inspectWorker(r, cli.Parent)
	if err != nil {
		return empty, err
	}
	e.Caller = cli
	e.CallerInput, e.CallerParentFD, e.CallerParentOutput, err = parentPipe(r, cli.PID, cli.Parent)
	if err != nil {
		return empty, err
	}
	again, err := r.process(cliPID)
	if err != nil || again != cli {
		return empty, errors.New("native Work caller incarnation changed")
	}
	return e, nil
}

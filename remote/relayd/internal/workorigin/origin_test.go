package workorigin

import (
	"errors"
	"testing"
)

type fakeReader struct {
	processes   map[int]Process
	descriptors map[int]map[int]Pipe
	reads       int
	change      bool
}

func (f *fakeReader) uid() uint32 { return 501 }
func (f *fakeReader) process(pid int) (Process, error) {
	f.reads++
	p, ok := f.processes[pid]
	if !ok {
		return Process{}, errors.New("absent")
	}
	if f.change && f.reads > 3 {
		p.StartMicros++
	}
	return p, nil
}
func (f *fakeReader) pipe(pid, fd int) (Pipe, error) {
	p, ok := f.descriptors[pid][fd]
	if !ok {
		return Pipe{}, errors.New("not a pipe")
	}
	return p, nil
}
func (f *fakeReader) pipes(pid int) (map[int]Pipe, error) { return f.descriptors[pid], nil }
func fixture() *fakeReader {
	return &fakeReader{processes: map[int]Process{30: {PID: 30, Parent: 20, UID: 501, StartMicros: 3, Executable: HelperPath}, 20: {PID: 20, Parent: 10, UID: 501, StartMicros: 2, Executable: ProviderPath}, 10: {PID: 10, Parent: 1, UID: 501, StartMicros: 1, Executable: ApplicationPath}}, descriptors: map[int]map[int]Pipe{30: {0: {Handle: 100, Peer: 200, Readable: true}}, 20: {17: {Handle: 200, Peer: 100, Writable: true}}}}
}
func TestNativeWorkTransportNeedsProviderOwnedInput(t *testing.T) {
	f := fixture()
	e, err := inspectMCP(f, 30)
	if err != nil || e.ProviderFD != 17 {
		t.Fatalf("positive: %+v %v", e, err)
	}
	cases := map[string]func(*fakeReader){
		"wrong helper":        func(f *fakeReader) { p := f.processes[30]; p.Executable = "/tmp/relay-mcp"; f.processes[30] = p },
		"shell parent":        func(f *fakeReader) { p := f.processes[20]; p.Executable = "/bin/sh"; f.processes[20] = p },
		"standalone provider": func(f *fakeReader) { p := f.processes[10]; p.Executable = "/bin/sh"; f.processes[10] = p },
		"foreign uid":         func(f *fakeReader) { p := f.processes[20]; p.UID = 502; f.processes[20] = p },
		"redirected input":    func(f *fakeReader) { delete(f.descriptors[30], 0) },
		"different pipe":      func(f *fakeReader) { f.descriptors[20][17] = Pipe{Handle: 900, Peer: 100, Writable: true} },
		"one sided spoof":     func(f *fakeReader) { f.descriptors[20][17] = Pipe{Handle: 200, Peer: 900, Writable: true} },
		"read end only":       func(f *fakeReader) { f.descriptors[20][17] = Pipe{Handle: 200, Peer: 100, Readable: true} },
		"duplex input": func(f *fakeReader) {
			f.descriptors[30][0] = Pipe{Handle: 100, Peer: 200, Readable: true, Writable: true}
		},
		"process reused":             func(f *fakeReader) { f.change = true },
		"ambiguous parent endpoints": func(f *fakeReader) { f.descriptors[20][18] = f.descriptors[20][17] },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			f := fixture()
			mutate(f)
			if _, err := inspectMCP(f, 30); err == nil {
				t.Fatal("accepted invalid native transport")
			}
		})
	}
}
func TestNativeThreadIsStrict(t *testing.T) {
	for _, s := range []string{"", "forged", "../thread", "01A18B32-f284-7220-91a2-6a81cde6db14"} {
		if threadPattern.MatchString(s) {
			t.Fatalf("accepted %q", s)
		}
	}
}

func (f *fakeReader) trustedFrontend(p Process) bool { return p.Executable == FrontendPath }
func TestCallerRequiresEveryNativePipeHop(t *testing.T) {
	f := fixture()
	f.processes[40] = Process{PID: 40, Parent: 30, UID: 501, StartMicros: 4, Executable: CLIPath}
	f.descriptors[40] = map[int]Pipe{0: {Handle: 300, Peer: 400, Readable: true}}
	f.descriptors[30][5] = Pipe{Handle: 400, Peer: 300, Writable: true}
	if _, err := inspectCaller(f, 40); err != nil {
		t.Fatal(err)
	}
	f = fixture()
	front := f.processes[30]
	front.Executable = FrontendPath
	f.processes[30] = front
	f.processes[40] = Process{PID: 40, Parent: 30, UID: 501, StartMicros: 4, Executable: HelperPath}
	f.processes[50] = Process{PID: 50, Parent: 40, UID: 501, StartMicros: 5, Executable: CLIPath}
	f.descriptors[40] = map[int]Pipe{0: {Handle: 300, Peer: 400, Readable: true}, 9: {Handle: 600, Peer: 500, Writable: true}}
	f.descriptors[30][5] = Pipe{Handle: 400, Peer: 300, Writable: true}
	f.descriptors[50] = map[int]Pipe{0: {Handle: 500, Peer: 600, Readable: true}}
	e, err := inspectCaller(f, 50)
	if err != nil {
		t.Fatal(err)
	}
	if err := revalidate(f, e); err != nil {
		t.Fatal(err)
	}
	w, err := inspectWorker(f, 40)
	if err != nil {
		t.Fatal(err)
	}
	if err := revalidate(f, w); err != nil {
		t.Fatal(err)
	}
	saved := f.descriptors[30][5]
	delete(f.descriptors[30], 5)
	if _, err := inspectCaller(f, 50); err == nil {
		t.Fatal("accepted substituted worker input")
	}
	f.descriptors[30][5] = saved
	delete(f.descriptors[40], 9)
	if _, err := inspectCaller(f, 50); err == nil {
		t.Fatal("accepted CLI input without the worker's live writer")
	}
}

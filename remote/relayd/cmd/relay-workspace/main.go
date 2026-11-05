// Command relay-workspace is the authenticated CLI for a captured Relay
// workspace. It never retries mutations.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	relayAddress    = "http://127.0.0.1:47471"
	responseLimit   = 8 * 1024 * 1024
	requestLimit    = 1048576
	socketTimeout   = 30 * time.Second
	statusWaitMilli = 15000
)

const usage = `usage: relay-workspace [-h] (--tab TAB | --pane PANE | --host HOST)
                       [--directory DIRECTORY]
                       {context,screen,request,exec,image} [arguments ...]
`

const help = usage + `
Authenticated CLI for a captured Relay workspace. Never retries mutations.

positional arguments:
  {context,screen,request,exec,image}
  arguments

options:
  -h, --help            show this help message and exit
  --tab TAB             Exact Relay tab UUID
  --pane PANE           Exact Relay pane UUID; resolves its existing tab
  --host HOST           Exact configured Relay host alias or This Mac
  --directory DIRECTORY
                        Absolute working directory with --host
`

var operations = []string{"context", "screen", "request", "exec", "image"}

// usageError is argparse's parser.error: usage on stderr and exit status 2.
type usageError string

func (e usageError) Error() string { return string(e) }

// exitCode ends the command with a status after its output was written.
type exitCode int

func (e exitCode) Error() string { return fmt.Sprintf("exit %d", int(e)) }

type arguments struct {
	tab, pane, host *string
	directory       string
	operation       string
	arguments       []string
}

type workspace struct {
	baseURL string
	helper  string
	getenv  func(string) string
	stdin   io.Reader
	stdout  io.Writer
	stderr  io.Writer
	newHex  func() string
	client  *http.Client
}

func main() {
	binary, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "Relay: "+err.Error())
		os.Exit(1)
	}
	w := &workspace{
		baseURL: relayAddress,
		// The signed helper beside this binary supplies the Relay token.
		helper: filepath.Join(filepath.Dir(binary), "relay-mcp"),
		getenv: os.Getenv,
		stdin:  os.Stdin,
		stdout: os.Stdout,
		stderr: os.Stderr,
		newHex: randomHex,
		client: socketTimeoutClient(socketTimeout),
	}
	os.Exit(w.run(os.Args[1:]))
}

func randomHex() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic(err)
	}
	value[6] = value[6]&0x0f | 0x40 // uuid4().hex
	value[8] = value[8]&0x3f | 0x80
	return hex.EncodeToString(value[:])
}

// socketTimeoutClient bounds every connect, read and write by timeout, as a
// urllib socket timeout does, without bounding a whole slow transfer.
func socketTimeoutClient(timeout time.Duration) *http.Client {
	dialer := &net.Dialer{Timeout: timeout}
	return &http.Client{Transport: &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			conn, err := dialer.DialContext(ctx, network, address)
			if err != nil {
				return nil, err
			}
			return &deadlineConn{Conn: conn, timeout: timeout}, nil
		},
		DisableKeepAlives: true,
	}}
}

type deadlineConn struct {
	net.Conn
	timeout time.Duration
}

func (c *deadlineConn) Read(p []byte) (int, error) {
	_ = c.Conn.SetReadDeadline(time.Now().Add(c.timeout))
	return c.Conn.Read(p)
}

func (c *deadlineConn) Write(p []byte) (int, error) {
	_ = c.Conn.SetWriteDeadline(time.Now().Add(c.timeout))
	return c.Conn.Write(p)
}

func (w *workspace) run(argv []string) int {
	args, err := parseArguments(argv)
	if err == nil {
		err = w.execute(args)
	}
	var refusal usageError
	var code exitCode
	switch {
	case err == nil:
		return 0
	case errors.Is(err, errHelp):
		fmt.Fprint(w.stdout, help)
		return 0
	case errors.As(err, &refusal):
		fmt.Fprint(w.stderr, usage+"relay-workspace: error: "+string(refusal)+"\n")
		return 2
	case errors.As(err, &code):
		return int(code)
	default:
		fmt.Fprintln(w.stderr, "Relay: "+err.Error())
		return 1
	}
}

var errHelp = errors.New("help")

// parseArguments follows the argparse definition: one of --tab, --pane or
// --host; --directory; an operation and its arguments. Options may appear
// anywhere before "--", long options may be abbreviated, and an unknown
// option is refused rather than taken as an argument.
func parseArguments(argv []string) (*arguments, error) {
	args := &arguments{directory: "/"}
	var positional []string
	var unrecognized []string
	var group string
	options := []string{"--tab", "--pane", "--host", "--directory", "--help"}
	for i := 0; i < len(argv); i++ {
		token := argv[i]
		if token == "--" {
			positional = append(positional, argv[i+1:]...)
			break
		}
		if !strings.HasPrefix(token, "-") || token == "-" || isNegativeNumber(token) {
			positional = append(positional, token)
			continue
		}
		if token == "-h" {
			return nil, errHelp
		}
		name, value, inline := strings.Cut(token, "=")
		if !strings.HasPrefix(name, "--") {
			unrecognized = append(unrecognized, token)
			continue
		}
		var matches []string
		for _, option := range options {
			if option == name {
				matches = []string{option}
				break
			}
			if strings.HasPrefix(option, name) {
				matches = append(matches, option)
			}
		}
		if len(matches) > 1 {
			return nil, usageError(fmt.Sprintf("ambiguous option: %s could match %s", name, strings.Join(matches, ", ")))
		}
		if len(matches) == 0 {
			unrecognized = append(unrecognized, token)
			continue
		}
		option := matches[0]
		if option == "--help" {
			if inline {
				return nil, usageError("argument -h/--help: ignored explicit argument " + pyStringRepr(value))
			}
			return nil, errHelp
		}
		if !inline {
			if i+1 >= len(argv) || strings.HasPrefix(argv[i+1], "-") && argv[i+1] != "-" && !isNegativeNumber(argv[i+1]) {
				return nil, usageError(fmt.Sprintf("argument %s: expected one argument", option))
			}
			i++
			value = argv[i]
		}
		if option == "--directory" {
			args.directory = value
			continue
		}
		if group != "" && group != option {
			return nil, usageError(fmt.Sprintf("argument %s: not allowed with argument %s", option, group))
		}
		group = option
		v := value
		switch option {
		case "--tab":
			args.tab = &v
		case "--pane":
			args.pane = &v
		case "--host":
			args.host = &v
		}
	}
	if len(positional) > 0 {
		args.operation = positional[0]
		valid := false
		for _, operation := range operations {
			valid = valid || operation == args.operation
		}
		if !valid {
			return nil, usageError(fmt.Sprintf("argument operation: invalid choice: %s (choose from %s)",
				pyStringRepr(args.operation), quotedChoices()))
		}
		args.arguments = positional[1:]
	}
	switch {
	case len(positional) == 0:
		return nil, usageError("the following arguments are required: operation")
	case group == "":
		return nil, usageError("one of the arguments --tab --pane --host is required")
	case len(unrecognized) > 0:
		return nil, usageError("unrecognized arguments: " + strings.Join(unrecognized, " "))
	}
	return args, nil
}

func quotedChoices() string {
	quoted := make([]string, len(operations))
	for i, operation := range operations {
		quoted[i] = pyStringRepr(operation)
	}
	return strings.Join(quoted, ", ")
}

// isNegativeNumber is argparse's test for an argument that only looks like an
// option; this parser defines no option resembling a number.
func isNegativeNumber(token string) bool {
	if len(token) < 2 || token[0] != '-' {
		return false
	}
	seenDigit, seenDot := false, false
	for _, c := range token[1:] {
		switch {
		case c >= '0' && c <= '9':
			seenDigit = true
		case c == '.' && !seenDot:
			seenDot = true
		default:
			return false
		}
	}
	return seenDigit
}

// canonicalUUID is str(uuid.UUID(value)) for the hexadecimal spellings it
// accepts: optional urn:uuid: prefix, braces and hyphens.
func canonicalUUID(value string) (string, bool) {
	value = strings.ReplaceAll(strings.ReplaceAll(value, "urn:", ""), "uuid:", "")
	value = strings.ReplaceAll(strings.Trim(value, "{}"), "-", "")
	if len(value) != 32 {
		return "", false
	}
	if _, err := hex.DecodeString(value); err != nil {
		return "", false
	}
	value = strings.ToLower(value)
	return value[0:8] + "-" + value[8:12] + "-" + value[12:16] + "-" + value[16:20] + "-" + value[20:], true
}

func set(value *string) bool { return value != nil && *value != "" }

func (w *workspace) headers() (http.Header, error) {
	command := exec.Command(w.helper, "--use-relay-token", "--print-http-headers")
	command.Stderr = w.stderr
	output, err := command.Output()
	if err != nil {
		var exited *exec.ExitError
		if errors.As(err, &exited) {
			return nil, fmt.Errorf("Command '[%s, '--use-relay-token', '--print-http-headers']' returned non-zero exit status %d.",
				pyStringRepr(w.helper), exited.ExitCode())
		}
		return nil, err
	}
	value, err := decodeJSON(output)
	if err != nil {
		return nil, err
	}
	supplied, ok := value.(*object)
	if !ok {
		return nil, fmt.Errorf("'%s' object has no attribute 'get'", pyTypeName(value))
	}
	authorization, err := supplied.index("Authorization")
	if err != nil {
		return nil, err
	}
	token, ok := authorization.(string)
	if !ok {
		return nil, fmt.Errorf("'%s' object has no attribute 'removeprefix'", pyTypeName(authorization))
	}
	headers := http.Header{}
	headers.Set("X-Relay-Token", strings.TrimPrefix(token, "Bearer "))
	headers.Set("Content-Type", "application/json")
	if caller := supplied.get("X-Relay-Caller-Token"); truthy(caller) {
		text, ok := caller.(string)
		if !ok {
			return nil, errors.New("invalid X-Relay-Caller-Token header value")
		}
		headers.Set("X-Relay-Caller-Token", text)
	}
	if caller := w.getenv("RELAY_CALLER_TOKEN"); caller != "" {
		headers.Set("X-Relay-Caller-Token", caller)
	}
	return headers, nil
}

// request is one GET (body nil) or POST to the local Relay API. Any non-2xx
// status, oversized reply or reply carrying a truthy "error" fails.
func (w *workspace) request(headers http.Header, path string, body any) (*object, error) {
	method, payload := http.MethodGet, io.Reader(nil)
	if body != nil {
		method, payload = http.MethodPost, bytes.NewReader(encodeJSON(body))
	}
	request, err := http.NewRequest(method, w.baseURL+path, payload)
	if err != nil {
		return nil, err
	}
	request.Header = headers.Clone()
	response, err := w.client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("<urlopen error %v>", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode > 299 {
		detail, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return nil, fmt.Errorf("Relay HTTP %d: %s", response.StatusCode, strings.ToValidUTF8(string(detail), "�"))
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, responseLimit+1))
	if err != nil {
		return nil, err
	}
	if len(data) > responseLimit {
		return nil, errors.New("Response exceeded CLI limit")
	}
	value, err := decodeJSON(data)
	if err != nil {
		return nil, err
	}
	answer, ok := value.(*object)
	if !ok {
		return nil, fmt.Errorf("'%s' object has no attribute 'get'", pyTypeName(value))
	}
	if message := answer.get("error"); truthy(message) {
		return nil, errors.New(pyStr(message))
	}
	return answer, nil
}

func (w *workspace) execute(args *arguments) error {
	headers, err := w.headers()
	if err != nil {
		return err
	}
	// Discover location once, without changing focus or injecting terminal
	// input. Tab and pane UUIDs have the same shape, so a pane passed as --tab
	// resolves to its tab instead of failing as an unknown tab.
	var pane *object
	tab := args.tab
	if set(args.pane) || set(args.tab) {
		supplied := args.tab
		if set(args.pane) {
			supplied = args.pane
		}
		identifier, ok := canonicalUUID(*supplied)
		if !ok {
			return usageError("An exact pane or tab UUID is required")
		}
		state, err := w.request(headers, "/api/state", nil)
		if err != nil {
			return err
		}
		tabs, err := stateTabs(state)
		if err != nil {
			return err
		}
		type match struct{ tab, pane *object }
		var matches []match
		var tabMatches []*object
		for _, candidate := range tabs {
			panes, err := listField(candidate, "panes")
			if err != nil {
				return err
			}
			for _, item := range panes {
				itemObject, ok := item.(*object)
				if !ok {
					return fmt.Errorf("'%s' object is not subscriptable", pyTypeName(item))
				}
				id, err := lowerID(itemObject)
				if err != nil {
					return err
				}
				if id == identifier {
					matches = append(matches, match{candidate, itemObject})
				}
			}
		}
		for _, candidate := range tabs {
			id, err := lowerID(candidate)
			if err != nil {
				return err
			}
			if id == identifier {
				tabMatches = append(tabMatches, candidate)
			}
		}
		switch {
		case set(args.pane) || len(tabMatches) == 0:
			if len(matches) != 1 {
				return usageError("Pane is absent or ambiguous in the current Relay workspace")
			}
			pane = matches[0].pane
			if tab, err = stringField(matches[0].tab, "id"); err != nil {
				return err
			}
		case len(tabMatches) == 1:
			if tab, err = stringField(tabMatches[0], "id"); err != nil {
				return err
			}
			if args.operation == "screen" {
				return usageError("screen requires --pane; a tab can contain several terminals")
			}
		default:
			return usageError("Tab is absent or ambiguous in the current Relay workspace")
		}
	}

	if args.operation == "screen" {
		return w.screen(headers, args, pane, tab)
	}

	var context *object
	if set(args.host) {
		if !strings.HasPrefix(args.directory, "/") || strings.ContainsRune(args.directory, 0) {
			return usageError("--directory must be an absolute path")
		}
		context = newObject("host", *args.host, "directory", args.directory, "binding", "explicit_cli")
	} else {
		var tabID any
		if tab != nil {
			tabID = *tab
		}
		if context, err = w.request(headers, "/api/workspace/context", newObject("tab_id", tabID)); err != nil {
			return err
		}
	}
	if args.operation == "context" {
		fmt.Fprintln(w.stdout, string(encodeJSON(context)))
		return nil
	}

	hostRequest := func(fields *object) (any, error) {
		host, err := context.index("host")
		if err != nil {
			return nil, err
		}
		directory, err := context.index("directory")
		if err != nil {
			return nil, err
		}
		fields = fields.copy()
		fields.set("host", host)
		fields.set("cwd", directory)
		fields.set("request_id", "rpc-"+w.newHex())
		answer, err := w.request(headers, "/api/host/request", fields)
		if err != nil {
			return nil, err
		}
		return answer.index("result")
	}

	switch args.operation {
	case "image":
		if !set(tab) {
			return usageError("image requires --tab with a captured workspace context")
		}
		if len(args.arguments) != 1 {
			return usageError("image requires one path")
		}
		// The native endpoint captures its own context once for the transfer.
		image, err := w.request(headers, "/api/workspace/image", newObject("tab_id", *tab, "path", args.arguments[0]))
		if err != nil {
			return err
		}
		data, err := image.index("data")
		if err != nil {
			return err
		}
		decoded, err := strictBase64(data)
		if err != nil {
			return err
		}
		_, err = w.stdout.Write(decoded)
		return err
	case "request":
		if len(args.arguments) > 1 {
			return usageError("request takes one JSON object or reads stdin")
		}
		var raw []byte
		if len(args.arguments) == 1 {
			raw = []byte(args.arguments[0])
		} else if raw, err = io.ReadAll(io.LimitReader(w.stdin, requestLimit+1)); err != nil {
			return err
		}
		if len(raw) > requestLimit {
			return errors.New("Request too large")
		}
		value, err := decodeJSON(raw)
		if err != nil {
			return err
		}
		fields, ok := value.(*object)
		if !ok {
			return usageError("request requires a JSON object")
		}
		result, err := hostRequest(fields)
		if err != nil {
			return err
		}
		fmt.Fprintln(w.stdout, string(encodeJSON(result)))
		return nil
	}
	return w.exec(args, context, hostRequest)
}

func (w *workspace) screen(headers http.Header, args *arguments, pane *object, tab *string) error {
	if pane == nil {
		return usageError("screen requires --pane with an existing terminal UUID")
	}
	if len(args.arguments) > 0 {
		return usageError("screen takes no additional arguments")
	}
	id, err := stringField(pane, "id")
	if err != nil {
		return err
	}
	answer, err := w.request(headers, "/api/panes/"+*id+"/viewport", nil)
	if err != nil {
		return err
	}
	connection, err := pane.index("connection")
	if err != nil {
		return err
	}
	phase, err := pane.index("phase")
	if err != nil {
		return err
	}
	answer.set("tab_id", *tab)
	answer.set("connection", connection)
	answer.set("phase", phase)
	answer.set("untrusted_output", true)
	if !truthy(answer.get("text")) {
		answer.set("availability", "empty_or_unmounted_viewport")
		answer.set("message", "No rendered screen is available; this does not prove the worker is stuck. No input was sent.")
	}
	fmt.Fprintln(w.stdout, string(encodeJSON(answer)))
	return nil
}

func (w *workspace) exec(args *arguments, context *object, hostRequest func(*object) (any, error)) error {
	if len(args.arguments) == 0 {
		return usageError("exec requires an executable and arguments")
	}
	jobID := "job-" + w.newHex()
	if _, clash := context.lookup("job_id"); clash {
		return errors.New("dict() got multiple values for keyword argument 'job_id'")
	}
	announcement := newObject("job_id", jobID)
	for _, key := range context.keys {
		announcement.set(key, context.values[key])
	}
	// Print the durable ID before dispatch, including when the outcome is unknown.
	fmt.Fprintln(w.stderr, string(encodeJSON(announcement)))
	argv := make([]any, len(args.arguments))
	for i, argument := range args.arguments {
		argv[i] = argument
	}
	started, err := hostRequest(newObject("operation", "exec", "job_id", jobID, "argv", argv))
	if err != nil {
		return err
	}
	startedObject, ok := started.(*object)
	if !ok {
		return fmt.Errorf("'%s' object is not subscriptable", pyTypeName(started))
	}
	state, err := startedObject.index("state")
	if err != nil {
		return err
	}
	if state != "running" && state != "exited" {
		return errors.New("Execution was not admitted; inspect job " + jobID)
	}
	offsets := newObject("stdout_offset", 0, "stderr_offset", 0)
	for {
		fields := newObject("operation", "status", "job_id", jobID, "wait_millis", statusWaitMilli)
		for _, key := range offsets.keys {
			fields.set(key, offsets.values[key])
		}
		value, err := hostRequest(fields)
		if err != nil {
			return err
		}
		result, ok := value.(*object)
		if !ok {
			return fmt.Errorf("'%s' object has no attribute 'get'", pyTypeName(value))
		}
		for _, stream := range []struct {
			name   string
			writer io.Writer
		}{{"stdout", w.stdout}, {"stderr", w.stderr}} {
			data := result.get(stream.name)
			if !truthy(data) {
				data = ""
			}
			decoded, err := strictBase64(data)
			if err != nil {
				return err
			}
			if _, err := stream.writer.Write(decoded); err != nil {
				return err
			}
			offset, err := result.index(stream.name + "_offset")
			if err != nil {
				return err
			}
			offsets.set(stream.name+"_offset", offset)
		}
		jobValue, err := result.index("job")
		if err != nil {
			return err
		}
		job, ok := jobValue.(*object)
		if !ok {
			return fmt.Errorf("'%s' object is not subscriptable", pyTypeName(jobValue))
		}
		state, err := job.index("state")
		if err != nil {
			return err
		}
		if state == "unknown_after_daemon_restart" {
			return errors.New("Outcome unknown; inspect job " + jobID + "; do not replay")
		}
		if (state == "exited" || state == "failed") && !truthy(result.get("stdout")) && !truthy(result.get("stderr")) {
			code, present := job.lookup("exit_code")
			if !present {
				return exitCode(1)
			}
			return w.exitWith(code)
		}
	}
}

// exitWith is sys.exit(value): None is success, an int is the status, and
// anything else is printed to stderr with status 1.
func (w *workspace) exitWith(value any) error {
	switch t := value.(type) {
	case nil:
		return nil
	case bool:
		if t {
			return exitCode(1)
		}
		return nil
	case *big.Int:
		if !t.IsInt64() {
			return exitCode(255)
		}
		return exitCode(int(t.Int64() & 0xff))
	}
	fmt.Fprintln(w.stderr, pyStr(value))
	return exitCode(1)
}

// strictBase64 is base64.b64decode(value, validate=True).
func strictBase64(value any) ([]byte, error) {
	text, ok := value.(string)
	if !ok {
		return nil, fmt.Errorf("argument should be a bytes-like object or ASCII string, not '%s'", pyTypeName(value))
	}
	if strings.ContainsAny(text, "\r\n") {
		return nil, errors.New("Non-base64 digit found")
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(text)
	if err != nil {
		return nil, errors.New("Invalid base64-encoded string")
	}
	return decoded, nil
}

func stateTabs(state *object) ([]*object, error) {
	sessions, err := listField(state, "sessions")
	if err != nil {
		return nil, err
	}
	var tabs []*object
	for _, session := range sessions {
		sessionObject, ok := session.(*object)
		if !ok {
			return nil, fmt.Errorf("'%s' object is not subscriptable", pyTypeName(session))
		}
		items, err := listField(sessionObject, "tabs")
		if err != nil {
			return nil, err
		}
		for _, item := range items {
			tab, ok := item.(*object)
			if !ok {
				return nil, fmt.Errorf("'%s' object is not subscriptable", pyTypeName(item))
			}
			tabs = append(tabs, tab)
		}
	}
	return tabs, nil
}

func listField(o *object, key string) ([]any, error) {
	value, err := o.index(key)
	if err != nil {
		return nil, err
	}
	items, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("'%s' object is not iterable", pyTypeName(value))
	}
	return items, nil
}

func stringField(o *object, key string) (*string, error) {
	value, err := o.index(key)
	if err != nil {
		return nil, err
	}
	text, ok := value.(string)
	if !ok {
		return nil, fmt.Errorf("'%s' object is not a string", pyTypeName(value))
	}
	return &text, nil
}

func lowerID(o *object) (string, error) {
	id, err := stringField(o, "id")
	if err != nil {
		return "", err
	}
	return strings.ToLower(*id), nil
}

package main

import (
	"flag"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/relay-terminal/relayd/internal/daemon"
)

const serviceUsage = "usage: relayd service {declare NAME [flags] [-- ARGV...]|undeclare NAME|list|status NAME|resume [--retry-failed]}"

type repeatedFlag []string

func (r *repeatedFlag) String() string     { return strings.Join(*r, ",") }
func (r *repeatedFlag) Set(v string) error { *r = append(*r, v); return nil }

// runService manages this host's declared services: the long-running host
// jobs a supervisor upgrade may stop and relaunch. Output names commands by
// their first word at most and never shows environment values.
func runService(arguments []string) {
	if len(arguments) == 0 {
		fatal(serviceUsage)
	}
	switch arguments[0] {
	case "declare":
		runServiceDeclare(arguments[1:])
	case "undeclare":
		runServiceUndeclare(arguments[1:])
	case "list":
		runServiceList(arguments[1:])
	case "status":
		runServiceStatus(arguments[1:])
	case "resume":
		runServiceResume(arguments[1:])
	default:
		fatal(serviceUsage)
	}
}

func serviceNameArgument(arguments []string, usage string) (string, []string) {
	if len(arguments) == 0 || strings.HasPrefix(arguments[0], "-") {
		fatal(usage)
	}
	return arguments[0], arguments[1:]
}

func runServiceDeclare(arguments []string) {
	name, rest := serviceNameArgument(arguments, "usage: relayd service declare NAME --cwd DIR (--command STRING | -- ARGV...) [flags]")
	flags := flag.NewFlagSet("service declare", flag.ExitOnError)
	stateDir := flags.String("state-dir", "", "worker state directory")
	command := flags.String("command", "", "shell command, run as /bin/sh -lc like host exec")
	cwd := flags.String("cwd", "", "absolute working directory")
	var env, depends repeatedFlag
	flags.Var(&env, "env", "KEY=VALUE environment entry (repeatable)")
	flags.Var(&depends, "depends-on", "service on this host that must be healthy first (repeatable or comma-separated)")
	healthTCP := flags.String("health-tcp", "", "health probe address host:port, or a port on 127.0.0.1")
	healthUnix := flags.String("health-unix", "", "health probe Unix socket")
	healthPath := flags.String("health-http-path", "", "HTTP path to GET for the health probe")
	healthAccept := flags.String("health-accept", "", "comma-separated HTTP statuses that count as healthy (default 200-399)")
	grace := flags.Duration("startup-grace", 90*time.Second, "how long a relaunched service may take to become healthy")
	job := flags.String("job", "", "bind the declaration to the running host job that serves it now")
	fromJob := flags.String("from-job", "", "bind to this running job and read its command and cwd from /proc (Linux)")
	_ = flags.Parse(rest)

	spec := daemon.ServiceSpec{Name: name, Command: *command, Argv: flags.Args(), Cwd: *cwd,
		StartupGraceSeconds: int(grace.Round(time.Second) / time.Second)}
	bind := *job
	if *fromJob != "" {
		if *job != "" && *job != *fromJob {
			fatal("give either --job or --from-job")
		}
		bind = *fromJob
		if spec.Command == "" && len(spec.Argv) == 0 {
			var err error
			adoptedCwd := ""
			spec.Command, spec.Argv, adoptedCwd, err = daemon.AdoptedServiceCommand(*stateDir, *fromJob)
			if err != nil {
				fatal(err.Error())
			}
			if spec.Cwd == "" {
				spec.Cwd = adoptedCwd
			}
		}
	}
	if len(env) > 0 {
		spec.Env = map[string]string{}
		for _, entry := range env {
			key, value, ok := strings.Cut(entry, "=")
			if !ok {
				fatal("--env takes KEY=VALUE")
			}
			spec.Env[key] = value
		}
	}
	for _, list := range depends {
		for _, dependency := range strings.Split(list, ",") {
			if dependency = strings.TrimSpace(dependency); dependency != "" {
				spec.DependsOn = append(spec.DependsOn, dependency)
			}
		}
	}
	if *healthTCP != "" || *healthUnix != "" || *healthPath != "" || *healthAccept != "" {
		spec.Health = &daemon.ServiceHealth{TCP: *healthTCP, Unix: *healthUnix, HTTPPath: *healthPath}
		for _, field := range strings.Split(*healthAccept, ",") {
			if field = strings.TrimSpace(field); field == "" {
				continue
			}
			code, err := strconv.Atoi(field)
			if err != nil {
				fatal("--health-accept takes HTTP status numbers")
			}
			spec.Health.Accept = append(spec.Health.Accept, code)
		}
	}
	if bind != "" {
		if err := daemon.RequireLiveServiceJob(*stateDir, bind); err != nil {
			fatal(err.Error())
		}
	}
	store, err := daemon.OpenServiceStore(*stateDir, "")
	if err != nil {
		fatal(err.Error())
	}
	release, err := store.Lock(false)
	if err != nil {
		fatal(err.Error())
	}
	defer release()
	declaration, err := store.Declare(spec, bind)
	if err != nil {
		fatal(err.Error())
	}
	job2 := declaration.JobID
	if job2 == "" {
		job2 = "none bound; an upgrade leaves it alone until it is bound with --job"
	}
	fmt.Printf("declared service %s on %s (%s, job %s)\n", declaration.Name, store.Host(), serviceCommandName(declaration.ServiceSpec), job2)
}

func runServiceUndeclare(arguments []string) {
	name, rest := serviceNameArgument(arguments, "usage: relayd service undeclare NAME")
	flags := flag.NewFlagSet("service undeclare", flag.ExitOnError)
	stateDir := flags.String("state-dir", "", "worker state directory")
	_ = flags.Parse(rest)
	store, err := daemon.OpenServiceStore(*stateDir, "")
	if err != nil {
		fatal(err.Error())
	}
	release, err := store.Lock(false)
	if err != nil {
		fatal(err.Error())
	}
	defer release()
	if err := store.Undeclare(name); err != nil {
		fatal(err.Error())
	}
	fmt.Printf("undeclared service %s; its job keeps running and now defers supervisor upgrades again\n", name)
}

func runServiceList(arguments []string) {
	flags := flag.NewFlagSet("service list", flag.ExitOnError)
	stateDir := flags.String("state-dir", "", "worker state directory")
	_ = flags.Parse(arguments)
	store, err := daemon.OpenServiceStore(*stateDir, "")
	if err != nil {
		fatal(err.Error())
	}
	services, err := store.Services()
	if err != nil {
		fatal(err.Error())
	}
	table := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(table, "SERVICE\tCOMMAND\tJOB\tPID\tSTATE\tDEPENDS ON")
	for _, service := range services {
		pid, state := daemon.ServiceJobState(*stateDir, service.JobID)
		job := service.JobID
		if job == "" {
			job = "-"
		}
		fmt.Fprintf(table, "%s\t%s\t%s\t%d\t%s\t%s\n", service.Name, serviceCommandName(service.ServiceSpec), job, pid, state, strings.Join(service.DependsOn, ","))
	}
	table.Flush()
}

func runServiceStatus(arguments []string) {
	name, rest := serviceNameArgument(arguments, "usage: relayd service status NAME")
	flags := flag.NewFlagSet("service status", flag.ExitOnError)
	stateDir := flags.String("state-dir", "", "worker state directory")
	_ = flags.Parse(rest)
	store, err := daemon.OpenServiceStore(*stateDir, "")
	if err != nil {
		fatal(err.Error())
	}
	services, err := store.Services()
	if err != nil {
		fatal(err.Error())
	}
	for _, service := range services {
		if service.Name != name {
			continue
		}
		pid, state := daemon.ServiceJobState(*stateDir, service.JobID)
		keys := make([]string, 0, len(service.Env))
		for key := range service.Env {
			keys = append(keys, key)
		}
		fmt.Printf("service:       %s on %s\n", service.Name, store.Host())
		fmt.Printf("command:       %s\n", serviceCommandName(service.ServiceSpec))
		fmt.Printf("cwd:           %s\n", service.Cwd)
		fmt.Printf("env keys:      %s\n", strings.Join(sortedStrings(keys), ","))
		fmt.Printf("depends on:    %s\n", strings.Join(service.DependsOn, ","))
		fmt.Printf("job:           %s (generation %d), pid %d, %s\n", service.JobID, service.Generation, pid, state)
		fmt.Printf("startup grace: %ds\n", service.StartupGraceSeconds)
		fmt.Printf("health now:    %s\n", service.Health.Probe())
		return
	}
	fatal("service " + name + " is not declared on " + store.Host())
}

func runServiceResume(arguments []string) {
	flags := flag.NewFlagSet("service resume", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "supervisor socket")
	stateDir := flags.String("state-dir", "", "worker state directory")
	retry := flags.Bool("retry-failed", false, "give services whose relaunch definitely failed a new generation")
	_ = flags.Parse(arguments)
	upgrade, err := daemon.NewServiceUpgrade(*stateDir, *socket)
	if err != nil {
		fatal(err.Error())
	}
	if err := upgrade.Acquire(); err != nil {
		fatal(err.Error())
	}
	defer upgrade.Release()
	err = upgrade.Relaunch(daemon.ServiceResumeOptions{RetryFailed: *retry})
	upgrade.Summary(os.Stdout)
	if err != nil {
		upgrade.Release()
		fatal(err.Error())
	}
	fmt.Println("no unfinished service journal remains")
}

func serviceCommandName(spec daemon.ServiceSpec) string {
	if len(spec.Argv) > 0 {
		return spec.Argv[0]
	}
	// Only the first word, and never an assignment, which may hold a value.
	fields := strings.Fields(spec.Command)
	if len(fields) == 0 || strings.Contains(fields[0], "=") {
		return "sh -lc ..."
	}
	return "sh -lc " + fields[0] + " ..."
}

func sortedStrings(values []string) []string {
	sort.Strings(values)
	return values
}

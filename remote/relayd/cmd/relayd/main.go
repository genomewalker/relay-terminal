package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"github.com/relay-terminal/relayd/internal/agentlaunch"
	"github.com/relay-terminal/relayd/internal/daemon"
	"github.com/relay-terminal/relayd/internal/desktoproute"
	"github.com/relay-terminal/relayd/internal/loopbackproxy"
	"github.com/relay-terminal/relayd/internal/protocol"
	relayterminfo "github.com/relay-terminal/relayd/internal/terminfo"
)

var relaydVersion = "0.5.3"

const supervisorProtocolVersion = 2

func main() {
	configureRuntime()
	invocation := os.Getenv("RELAY_INVOKED_AS")
	if invocation == "" {
		invocation = filepath.Base(os.Args[0])
	}
	if invocation == "rcode" {
		runRCode(os.Args[1:])
		return
	}
	if invocation == "claude" || invocation == "codex" {
		runAgent(append([]string{invocation}, os.Args[1:]...))
		return
	}
	if len(os.Args) < 2 {
		fatal("usage: relayd <daemon|node|attach|observe|observe-many|sessions|terminate|forget|gc|event|agent|agent-launchers|artifact|files|terminfo|live-status|upgrade-supervisor|upgrade-workers|communication|peer-serve>")
	}
	switch os.Args[1] {
	case "desktop-route":
		ctx, stop, err := desktopSignalContext()
		if err != nil {
			fatal(err.Error())
		}
		defer stop()
		if err := desktoproute.Run(ctx, os.Args[2:], os.Stdin, os.Stdout); err != nil {
			fatal(err.Error())
		}
	case "desktop-remote":
		// SIGTERM requests the native inbox's bounded backlog drain. A clean
		// zero exit is required before the supervisor can hand its route over.
		ctx, stop, err := desktopSignalContext()
		if err != nil {
			fatal(err.Error())
		}
		defer stop()
		if err := desktoproute.RunRemote(ctx, os.Args[2:], os.Stdin, os.Stdout); err != nil {
			fatal(err.Error())
		}
	case "desktop-group":
		ctx, stop, err := desktopSignalContext()
		if err != nil {
			fatal(err.Error())
		}
		defer stop()
		if err := desktoproute.RunGroup(ctx, os.Args[2:], os.Stdin, os.Stdout); err != nil {
			fatal(err.Error())
		}
	case "subscription-quota":
		data, err := daemon.ReadSubscriptionQuota(context.Background(), os.Args[2:])
		if err != nil {
			fatal(err.Error())
		}
		if _, err := os.Stdout.Write(append(data, '\n')); err != nil {
			fatal(err.Error())
		}
	case "subscription-quota-statusline":
		if len(os.Args) != 3 {
			fatal("usage: relayd subscription-quota-statusline ENCODED_COMMAND")
		}
		code, err := daemon.RunSubscriptionQuotaStatusline(context.Background(), os.Args[2], os.Stdin, os.Stdout, os.Stderr)
		if err != nil {
			fatal(err.Error())
		}
		os.Exit(code)
	case "native-group":
		if err := daemon.RunNativeGroup(context.Background(), os.Args[2:], os.Stdin, os.Stdout); err != nil {
			fatal(err.Error())
		}
	case "agent-conversation":
		if err := daemon.RunAgentConversation(context.Background(), os.Args[2:], os.Stdout); err != nil {
			fatal(err.Error())
		}
	case "agent-maintenance":
		if err := daemon.RunAgentMaintenance(context.Background(), os.Args[2:], os.Stdout); err != nil {
			fatal(err.Error())
		}
	case "pane-messaging":
		if err := daemon.RunPaneMessaging(context.Background(), os.Args[2:], os.Stdout); err != nil {
			fatal(err.Error())
		}
	case "codex-managed-backend":
		runManagedStockCodexBackend(os.Args[2:])
	case "codex-proxy":
		runStockCodexProxy(os.Args[2:])
	case "loopback-proxy":
		runLoopbackProxy(os.Args[2:])
	case "plugin":
		runPlugin()
	case "daemon":
		runDaemon(os.Args[2:])
	case "node":
		runNode(os.Args[2:])
	case "pane-health-controller-rpc":
		runPaneHealthControllerRPC(os.Args[2:])
	case "worker":
		runWorker(os.Args[2:])
	case "worker-reexec-probe":
		runWorkerReexecProbe(os.Args[2:])
	case "upgrade-workers":
		runUpgradeWorkers(os.Args[2:])
	case "attach":
		runAttach(os.Args[2:])
	case "observe":
		runObserve(os.Args[2:])
	case "observe-many":
		runObserveMany(os.Args[2:])
	case "sessions":
		runSessions(os.Args[2:])
	case "preserve-catalog":
		runPreserveCatalog(os.Args[2:])
	case "prompt-owner-binding":
		if len(os.Args) != 3 {
			fatal("usage: relayd prompt-owner-binding PANE")
		}
		record, err := daemon.ReadVerifiedPromptOwnerBinding(os.Args[2])
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, record); err != nil {
			fatal(err.Error())
		}
	case "account-transcript-check":
		// The binding validator a resumed agent must pass, run against a
		// target account before a move exits its source agent.
		if len(os.Args) != 5 {
			fatal("usage: relayd account-transcript-check PROVIDER CONFIG_DIR|- TRANSCRIPT")
		}
		override := os.Args[3]
		if override == "-" {
			override = ""
		}
		if err := daemon.ValidateAccountTranscript(os.Args[4], os.Args[2], override); err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, map[string]bool{"bindable": true}); err != nil {
			fatal(err.Error())
		}
	case "claude-move-onboarding":
		// Run before a Claude account move exits its source agent; a
		// nonzero exit refuses the move.
		result, err := claudeMoveOnboarding(os.Args[2:])
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, result); err != nil {
			fatal(err.Error())
		}
	case "rotation-native-bridge":
		if len(os.Args) != 3 {
			fatal("usage: relayd rotation-native-bridge PANE")
		}
		if err := daemon.RunNativeRotationBridge(os.Args[2], os.Stdin, os.Stdout); err != nil {
			fatal(err.Error())
		}
	case "rotation-supervisor-rpc":
		if len(os.Args) != 4 {
			fatal("usage: relayd rotation-supervisor-rpc PANE CLIENT_ID")
		}
		request, err := io.ReadAll(io.LimitReader(os.Stdin, 8193))
		if err != nil || len(request) > 8192 {
			fatal("invalid host rotation request")
		}
		response, err := daemon.CallHostRotation(os.Args[2], os.Args[3], request)
		if err != nil {
			fatal(err.Error())
		}
		if _, err := os.Stdout.Write(append(response, '\n')); err != nil {
			fatal(err.Error())
		}
	case "prompt-editor-rpc":
		if len(os.Args) != 4 {
			fatal("usage: relayd prompt-editor-rpc PANE CLIENT_ID")
		}
		request, err := io.ReadAll(io.LimitReader(os.Stdin, (2<<20)+1))
		if err != nil || len(request) > 2<<20 {
			fatal("invalid prompt editor request")
		}
		response, err := daemon.CallPromptEditor(os.Args[2], os.Args[3], request)
		if err != nil {
			fatal(err.Error())
		}
		if _, err := os.Stdout.Write(append(response, '\n')); err != nil {
			fatal(err.Error())
		}
	case "prompt-editor":
		if len(os.Args) != 3 {
			fatal("usage: relayd prompt-editor FILE")
		}
		fallback, err := daemon.RunPromptEditorFile(os.Getenv("RELAY_SESSION"), os.Args[2])
		if err != nil {
			fatal(err.Error())
		}
		if fallback {
			editor := os.Getenv("RELAY_PROMPT_ORIGINAL_VISUAL")
			if editor == "" {
				editor = os.Getenv("RELAY_PROMPT_ORIGINAL_EDITOR")
			}
			if editor == "" {
				editor = "vi"
			}
			if err := syscall.Exec("/bin/sh", []string{"sh", "-c", "exec " + editor + " \"$@\"", "relay-prompt-editor", os.Args[2]}, daemon.OriginalPromptEditorEnvironment(agentExecEnvironment(os.Environ()))); err != nil {
				fatal(err.Error())
			}
		}
	case "agent-binding":
		record, err := readAgentBindingArgs(os.Args[2:], daemon.ReadVerifiedAgentBinding, daemon.ReadNativeAgentBinding)
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, record); err != nil {
			fatal(err.Error())
		}
	case "agent-harnesses":
		report, err := daemon.ReadPaneHarnesses(os.Args[2:])
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, report); err != nil {
			fatal(err.Error())
		}
	case "agent-process-identity":
		if len(os.Args) != 5 {
			fatal("usage: relayd agent-process-identity PANE PID PROVIDER")
		}
		pid, err := strconv.Atoi(os.Args[3])
		if err != nil {
			fatal("invalid native agent PID")
		}
		start, err := daemon.NativeAgentIncarnation(os.Args[2], pid, os.Args[4])
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, map[string]any{"process_start": start}); err != nil {
			fatal(err.Error())
		}
	case "worker-identities":
		if len(os.Args) != 2 {
			fatal("usage: relayd worker-identities")
		}
		report, err := daemon.AuditWorkerIdentities()
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, report); err != nil {
			fatal(err.Error())
		}
	case "network":
		if len(os.Args) != 2 {
			fatal("usage: relayd network")
		}
		snapshot, err := daemon.NewServer().NetworkSnapshot()
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, snapshot); err != nil {
			fatal(err.Error())
		}
	case "recover":
		runRecover(os.Args[2:])
	case "terminate":
		runTerminate(os.Args[2:])
	case "forget":
		runForget(os.Args[2:])
	case "gc":
		runGC(os.Args[2:])
	case "gc-host-jobs":
		runGCHostJobs(os.Args[2:])
	case "event":
		runEvent(os.Args[2:])
	case "agent-launch":
		runAgentLaunch(os.Args[2:])
	case "rotation-launch":
		runRotationLaunch(os.Args[2:])
	case "rotation-exec":
		runRotationExec(os.Args[2:])
	case "rotation-send":
		runRotationSend(os.Args[2:])
	case "rotation-receipt":
		runRotationReceipt(os.Args[2:])
	case "rotation-status":
		runRotationStatus(os.Args[2:])
	case "rotation-text-reconcile":
		runRotationTextReconcile(os.Args[2:])
	case "codex-runtime":
		runCodexRuntime(os.Args[2:])
	case "codex-start-parameters":
		runCodexStartParameters(os.Args[2:])
	case "claude-status-capture":
		runClaudeStatusCapture(os.Args[2:])
	case "claude-statusline":
		runClaudeStatusLine(os.Args[2:])
	case "claude-start-parameters":
		runClaudeStartParameters(os.Args[2:])
	case "rotation-codex-launch":
		runCodexRotationLaunch(os.Args[2:])
	case "rotation-codex-exec":
		runCodexRotationExec(os.Args[2:])
	case "native-chat":
		runNativeChat(os.Args[2:])
	case "agent":
		runAgent(os.Args[2:])
	case "agent-launchers":
		runAgentLaunchers(os.Args[2:])
	case "codex-relay-profile":
		runCodexRelayProfile(os.Args[2:])
	case "codex-pane-resume-plan":
		if len(os.Args) != 5 {
			fatal("usage: relayd codex-pane-resume-plan PANE EXPECTED_SESSION TARGET_SESSION")
		}
		plan, err := daemon.ReadCodexPaneResumePlan(os.Args[2], os.Args[3], os.Args[4])
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, plan); err != nil {
			fatal(err.Error())
		}
	case "resume-plan":
		if len(os.Args) != 3 {
			fatal("usage: relayd resume-plan PANE")
		}
		plan, err := daemon.ReadSavedConversationPlan(os.Args[2])
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, plan); err != nil {
			fatal(err.Error())
		}
	case "communication-actor":
		pid := os.Getppid()
		if len(os.Args) == 3 {
			var err error
			pid, err = strconv.Atoi(os.Args[2])
			if err != nil {
				fatal("invalid communication client PID")
			}
		} else if len(os.Args) != 2 {
			fatal("usage: relayd communication-actor [CLIENT_PID]")
		}
		actor, err := daemon.ReadCommunicationActor(pid)
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, actor); err != nil {
			fatal(err.Error())
		}
	case "peer-inbound-class":
		// Read-only: the native messaging adapter predicts a recipient's
		// cross-session hold before writing to its inbox.
		if len(os.Args) != 4 {
			fatal("usage: relayd peer-inbound-class PID SESSION")
		}
		pid, err := strconv.Atoi(os.Args[2])
		if err != nil {
			fatal("invalid recipient PID")
		}
		class, reason := daemon.ReadRecipientInboundClass(pid, os.Args[3])
		if err := daemon.EncodeJSON(os.Stdout, map[string]string{"class": class, "reason": reason}); err != nil {
			fatal(err.Error())
		}
	case "communication", "communication-shepherd":
		request, decodeErr := daemon.DecodeCommunicationRequest(os.Stdin)
		if decodeErr != nil {
			fatal("invalid communication request")
		}
		if os.Args[1] == "communication-shepherd" && (!request.ShepherdReport || request.Operation != "assistant_send") {
			fatal("a shepherd report envelope is required")
		}
		request, actorErr := daemon.ReconcileCommunicationActor(request, os.Getppid())
		if actorErr != nil {
			fatal(actorErr.Error())
		}
		result, err := daemon.ExecuteCommunication(request)
		if err != nil {
			fatal(err.Error())
		}
		if err := daemon.EncodeJSON(os.Stdout, result); err != nil {
			fatal(err.Error())
		}
	case "peer-serve":
		flags := flag.NewFlagSet("peer-serve", flag.ExitOnError)
		listen := flags.String("listen", "", "explicit host:port to listen on")
		_ = flags.Parse(os.Args[2:])
		if *listen == "" || flags.NArg() != 0 {
			fatal("usage: relayd peer-serve --listen HOST:PORT")
		}
		if err := daemon.ServeCommunicationPeers(*listen); err != nil {
			fatal(err.Error())
		}
	case "resume-saved":
		runResumeSaved(os.Args[2:])
	case "artifact":
		runArtifact(os.Args[2:])
	case "files":
		runFiles(os.Args[2:])
	case "terminfo":
		runTerminfo(os.Args[2:])
	case "live-status":
		runLiveStatus(os.Args[2:])
	case "upgrade-supervisor":
		runUpgradeSupervisor(os.Args[2:])
	case "--version", "version":
		fmt.Println("relayd " + relaydVersion)
	default:
		fatal("unknown command: " + os.Args[1])
	}
}

func runTerminfo(arguments []string) {
	if len(arguments) > 1 || len(arguments) == 1 && arguments[0] != "status" && arguments[0] != "install" {
		fatal("usage: relayd terminfo [status|install]")
	}
	status, err := relayterminfo.EnsureCurrentUser()
	if encodeErr := daemon.EncodeJSON(os.Stdout, status); encodeErr != nil {
		fatal(encodeErr.Error())
	}
	if err != nil {
		os.Exit(1)
	}
}

func configureRuntime() {
	if maximum := desiredMaxProcs(os.Getenv); maximum > 0 {
		runtime.GOMAXPROCS(maximum)
	}
}

func desiredMaxProcs(getenv func(string) string) int {
	// Respect administrators who already tune Go globally. Relay's override is
	// intentionally separate so one small I/O worker does not inherit all 96+
	// host cores merely because it runs on an HPC node.
	if strings.TrimSpace(getenv("GOMAXPROCS")) != "" {
		return 0
	}
	if value := strings.TrimSpace(getenv("RELAYD_MAX_PROCS")); value != "" {
		parsed, err := strconv.Atoi(value)
		if err == nil && parsed >= 1 && parsed <= 32 {
			return parsed
		}
	}
	return 2
}

func runRCode(arguments []string) {
	flags := flag.NewFlagSet("rcode", flag.ExitOnError)
	diff := flags.Bool("diff", false, "open a diff; one path compares with Git HEAD, two paths compare with each other")
	_ = flags.Parse(arguments)
	paths := flags.Args()
	if len(paths) == 0 || len(paths) > 2 || !*diff && len(paths) != 1 {
		fatal("usage: rcode [--diff] <file> [other-file]")
	}
	resolved := make([]string, 0, len(paths))
	for _, path := range paths {
		absolute, err := filepath.Abs(path)
		if err != nil {
			fatal(err.Error())
		}
		canonical, err := filepath.EvalSymlinks(absolute)
		if err != nil {
			fatal(err.Error())
		}
		info, err := os.Stat(canonical)
		if err != nil || (!info.Mode().IsRegular() && !(!*diff && info.IsDir())) {
			fatal("expected a regular file, or a directory without --diff: " + path)
		}
		resolved = append(resolved, canonical)
	}
	session := os.Getenv("RELAY_SESSION")
	if session == "" {
		fatal("rcode must run inside a Relay-managed terminal pane")
	}
	event, err := editorOpenEvent(resolved, *diff)
	if err != nil {
		fatal(err.Error())
	}
	envelope, err := json.Marshal(struct {
		Agent string          `json:"agent"`
		Event json.RawMessage `json:"event"`
	}{Agent: "relay", Event: event})
	if err != nil {
		fatal(err.Error())
	}
	connection, err := connectOrStart(defaultSocket())
	if err != nil {
		fatal(err.Error())
	}
	defer connection.Close()
	writer := protocol.NewWriter(connection)
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: session, EventOnly: true,
	})
	if err := writer.Write(hello); err != nil {
		fatal(err.Error())
	}
	if err := writer.Write(protocol.Frame{Type: protocol.AgentEvent, Payload: envelope}); err != nil {
		fatal(err.Error())
	}
}

func editorOpenEvent(paths []string, diff bool) ([]byte, error) {
	var requestID [16]byte
	if _, err := rand.Read(requestID[:]); err != nil {
		return nil, err
	}
	// Identical user commands are separate actions, unlike replayed provider
	// transcript records. Give each invocation an identity for event dedup.
	return json.Marshal(struct {
		Type      string   `json:"type"`
		RequestID string   `json:"request_id"`
		Paths     []string `json:"paths"`
		Diff      bool     `json:"diff"`
	}{Type: "open_file", RequestID: fmt.Sprintf("%x", requestID), Paths: paths, Diff: diff})
}

func runFiles(arguments []string) {
	if len(arguments) == 0 {
		fatal("usage: relayd files <workspace|list|read|write|import|git-diff>")
	}
	flags := flag.NewFlagSet("files "+arguments[0], flag.ExitOnError)
	pathBase64 := flags.String("path-b64", "", "base64-encoded absolute path")
	parentSession := flags.String("parent-session", "", "terminal session whose working directory should be used")
	nameBase64 := flags.String("name-b64", "", "base64-encoded import filename")
	queryBase64 := flags.String("query-b64", "", "base64-encoded file search")
	includeUntracked := flags.Bool("include-untracked", false, "include bounded discovery of untracked files")
	expectedModificationNS := flags.Int64("expected-modification-ns", 0, "opaque revision used for conflict detection")
	_ = flags.Parse(arguments[1:])
	path := ""
	if *pathBase64 != "" {
		var err error
		path, err = daemon.DecodePath(*pathBase64)
		if err != nil {
			fatal(err.Error())
		}
	}
	var value any
	var err error
	switch arguments[0] {
	case "workspace":
		value, err = daemon.ResolveWorkspace(*parentSession, path)
	case "list":
		value, err = daemon.ListDirectory(path)
	case "find":
		query, decodeErr := base64.StdEncoding.DecodeString(*queryBase64)
		if decodeErr != nil {
			fatal("invalid search query")
		}
		value, err = daemon.FindEditorFiles(path, string(query))
	case "find-v2":
		query, decodeErr := base64.StdEncoding.DecodeString(*queryBase64)
		if decodeErr != nil {
			fatal("invalid search query")
		}
		value, err = daemon.SearchEditorFiles(path, string(query), *includeUntracked)
	case "read":
		value, err = daemon.ReadEditorFile(path)
	case "write":
		value, err = daemon.WriteEditorFile(path, *expectedModificationNS, os.Stdin)
	case "import":
		name, decodeErr := daemon.DecodePath(*nameBase64)
		if decodeErr != nil {
			fatal(decodeErr.Error())
		}
		workspace, resolveErr := daemon.ResolveWorkspace(*parentSession, path)
		if resolveErr != nil {
			fatal(resolveErr.Error())
		}
		value, err = daemon.ImportFile(workspace.Path, name, os.Stdin)
	case "git-diff":
		value, err = daemon.ReadGitDiff(path)
	default:
		fatal("usage: relayd files <workspace|list|read|write|import|git-diff>")
	}
	if err != nil {
		fatal(err.Error())
	}
	if err := daemon.EncodeJSON(os.Stdout, value); err != nil {
		fatal(err.Error())
	}
}

const maxArtifactBytes = 25 << 20

func runArtifact(arguments []string) {
	flags := flag.NewFlagSet("artifact", flag.ExitOnError)
	pathBase64 := flags.String("path-b64", "", "base64-encoded image path")
	_ = flags.Parse(arguments)
	if *pathBase64 == "" {
		fatal("--path-b64 is required")
	}
	decoded, err := base64.StdEncoding.DecodeString(*pathBase64)
	if err != nil {
		fatal("invalid --path-b64")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fatal(err.Error())
	}
	path, err := resolveArtifactPath(string(decoded), home, os.Getuid())
	if err != nil {
		fatal(err.Error())
	}
	file, err := os.Open(path)
	if err != nil {
		fatal(err.Error())
	}
	defer file.Close()
	if _, err := io.Copy(os.Stdout, io.LimitReader(file, maxArtifactBytes+1)); err != nil {
		fatal(err.Error())
	}
}

func resolveArtifactPath(requested, home string, uid int) (string, error) {
	if !filepath.IsAbs(requested) {
		cleanRelative := filepath.Clean(requested)
		codexRoot := filepath.Join(".codex", "generated_images")
		if cleanRelative != codexRoot && !strings.HasPrefix(cleanRelative, codexRoot+string(filepath.Separator)) {
			return "", fmt.Errorf("relative artifact path is outside .codex/generated_images")
		}
		requested = filepath.Join(home, cleanRelative)
	}
	extension := filepath.Ext(requested)
	switch extension {
	case "", ".png", ".PNG", ".jpg", ".JPG", ".jpeg", ".JPEG", ".gif", ".GIF", ".webp", ".WEBP":
	default:
		return "", fmt.Errorf("unsupported artifact type")
	}
	resolved, err := filepath.EvalSymlinks(filepath.Clean(requested))
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	allowedRoots := []string{filepath.Clean(home), filepath.Join("/tmp", "claude-"+strconv.Itoa(uid))}
	allowed := false
	for _, root := range allowedRoots {
		if canonicalRoot, rootErr := filepath.EvalSymlinks(root); rootErr == nil {
			root = canonicalRoot
		}
		relative, relErr := filepath.Rel(root, resolved)
		if relErr == nil && relative != ".." && !filepath.IsAbs(relative) && !startsWithParent(relative) {
			allowed = true
			break
		}
	}
	temporaryRoot := os.TempDir()
	if canonical, rootErr := filepath.EvalSymlinks(temporaryRoot); rootErr == nil {
		temporaryRoot = canonical
	}
	if !allowed && pathIsWithin(resolved, temporaryRoot) {
		if stat, ok := info.Sys().(*syscall.Stat_t); ok && stat.Uid == uint32(uid) {
			allowed = true
		}
	}
	if !allowed {
		return "", fmt.Errorf("artifact path is outside allowed directories")
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("artifact is not a regular file")
	}
	if info.Size() > maxArtifactBytes {
		return "", fmt.Errorf("artifact exceeds 25 MiB")
	}
	return resolved, nil
}

func pathIsWithin(path, root string) bool {
	relative, err := filepath.Rel(root, path)
	return err == nil && relative != ".." && !filepath.IsAbs(relative) && !startsWithParent(relative)
}

func startsWithParent(path string) bool {
	return path == ".." || len(path) > 3 && path[:3] == ".."+string(filepath.Separator)
}

func runAgentLaunch(arguments []string) {
	flags := flag.NewFlagSet("agent-launch", flag.ExitOnError)
	client := flags.String("client", "", "exact agent client")
	pid := flags.Int("pid", 0, "verified process PID")
	start := flags.String("process-start", "", "verified process start ticks")
	expectedExecutable := flags.String("executable", "", "verified real agent executable")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 {
		fatal("unexpected capture arguments")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fatal("home unavailable")
	}
	if *expectedExecutable == "" {
		resolved, resolveError := findRealAgentExecutable(*client)
		if resolveError != nil {
			fatal("verified agent executable unavailable")
		}
		*expectedExecutable = resolved
	}
	path, err := agentlaunch.CaptureExisting(filepath.Join(home, ".local", "share", "relay", "agent-launches"), *client, *pid, *start, *expectedExecutable)
	if err != nil {
		fatal("launch capture refused; process identity or configuration is unavailable")
	}
	// The snapshot path is returned; arguments and environment are never logged.
	_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"snapshot_path": path})
}

func runAgent(arguments []string) {
	if len(arguments) == 0 {
		fatal("usage: relayd agent <claude|codex> [agent arguments...]")
	}
	switch arguments[0] {
	case "claude":
		runClaude(arguments[1:])
	case "codex":
		runCodex(arguments[1:])
	default:
		fatal("usage: relayd agent <claude|codex> [agent arguments...]")
	}
}

func runResumeSaved(arguments []string) {
	if len(arguments) != 3 || os.Getenv("RELAY_SESSION") == "" || os.Getenv("RELAY_SESSION") == arguments[0] {
		fatal("saved conversation recovery requires a new dedicated pane")
	}
	plan, err := daemon.ReadSavedConversationPlan(arguments[0])
	if err != nil || plan.SessionID != arguments[1] || plan.BindingSHA != arguments[2] {
		fatal("saved conversation changed or is unavailable; no agent was started")
	}
	if err := os.Chdir(plan.Directory); err != nil {
		fatal("saved working directory is unavailable")
	}
	// The conversation lives in its own account directory. The new pane's
	// inherited environment never chooses the account for a resumed session.
	if err := resumeSavedAccount(plan.Provider, plan.ConfigDir); err != nil {
		fatal(err.Error())
	}
	if plan.Provider == "claude" {
		runClaude([]string{"--resume", plan.SessionID})
	} else {
		runCodex([]string{"resume", plan.SessionID})
	}
}

func resumeSavedAccount(provider, configDir string) error {
	name, err := agentlaunch.ConfigDirVariable(provider)
	if err != nil {
		return err
	}
	if inherited := os.Getenv(name); inherited != "" && inherited != configDir {
		fmt.Fprintln(os.Stderr, "Relay: this pane's account differs from the saved conversation's; resuming with the conversation's own account.")
	}
	if configDir == "" {
		return os.Unsetenv(name)
	}
	if !filepath.IsAbs(configDir) || filepath.Clean(configDir) != configDir {
		return errors.New("saved conversation account directory is invalid")
	}
	return os.Setenv(name, configDir)
}

func runClaude(arguments []string) {
	home, err := os.UserHomeDir()
	if err != nil {
		fatal(err.Error())
	}
	admitAccount(home, "claude", false)
	prepareAccount(home, "claude")
	settingsDir := filepath.Join(home, ".relay")
	if err := os.MkdirAll(settingsDir, 0o700); err != nil {
		fatal(err.Error())
	}
	settingsPath := filepath.Join(settingsDir, "claude-hooks.json")
	helper, err := os.Executable()
	if err != nil {
		fatal("Relay helper path is unavailable")
	}
	quotedHelper := "'" + strings.ReplaceAll(helper, "'", "'\"'\"'") + "'"
	encodedHelper, _ := json.Marshal(quotedHelper)
	settings := strings.ReplaceAll(claudeHookSettings, "~/.local/bin/relayd", string(encodedHelper[1:len(encodedHelper)-1]))
	if err := os.WriteFile(settingsPath, []byte(settings), 0o600); err != nil {
		fatal(err.Error())
	}
	executable, err := findRealAgentExecutable("claude")
	if err != nil {
		fatal(err.Error())
	}
	requested := arguments
	configDir := os.Getenv("CLAUDE_CONFIG_DIR")
	if configDir == "" {
		configDir = filepath.Join(home, ".claude")
	}
	// The legacy status settings repeated every Relay hook; its status line is now in claude-hooks.json.
	retiredStatus := filepath.Join(home, ".config", "relay", "claude-hooks-status.json")
	withDefaults := agentaccounts.WithClaudeDefaults(accountModelDefaults("claude", claudeConfigRoot(home)), arguments)
	arguments, err = agentlaunch.ManagedClaudeLaunchArguments(configDir, settingsPath, withDefaults, retiredStatus)
	if err != nil {
		fatal("Claude could not start with Relay launch defaults: " + err.Error())
	}
	// Native rendering observes the official CLI session; it must not replace
	// this invocation with a Relay-owned SDK worker.
	// Continuing a detached background conversation exits in recent Claude CLIs.
	// Use the provider's own chooser instead of guessing which session is latest
	// or stopping a process. Only intercept a plain interactive continuation.
	if target, background := claudeContinuationTarget(executable, arguments); background {
		cwd, _ := os.Getwd()
		if target != "" {
			fmt.Fprintln(os.Stderr, "Relay: reattaching this pane's existing Claude conversation.")
			if err := syscall.Exec(executable, []string{"claude", "attach", target}, agentExecEnvironment(os.Environ())); err != nil {
				fatal(err.Error())
			}
		}
		fmt.Fprintln(os.Stderr, "Relay: a Claude conversation is still running in the background here. Select it to reattach.")
		chooserArguments := []string{"claude", "agents", "--cwd", cwd, "--settings", settingsPath}
		// The chooser keeps the caller's own options without Relay's settings files; defaults apply to launches only.
		for _, argument := range agentlaunch.WithoutRelayClaudeSettings(settingsPath, requested, retiredStatus) {
			if argument != "--continue" && argument != "-c" {
				chooserArguments = append(chooserArguments, argument)
			}
		}
		if err := syscall.Exec(executable, chooserArguments, agentExecEnvironment(os.Environ())); err != nil {
			fatal(err.Error())
		}
	}
	claudeArguments := []string{"claude", "--settings", settingsPath}
	claudeArguments = append(claudeArguments, arguments...)
	if err := syscall.Exec(executable, claudeArguments, captureAgentLaunch(home, "claude", executable, requested, claudeArguments[1:])); err != nil {
		fatal(err.Error())
	}
}

func claudeContinuationTarget(executable string, arguments []string) (string, bool) {
	continuations := 0
	for i := 0; i < len(arguments); i++ {
		switch argument := arguments[i]; {
		case argument == "--continue" || argument == "-c":
			continuations++
		case argument == "--dangerously-skip-permissions" || argument == "--allow-dangerously-skip-permissions":
		// A starting permission mode, such as an account's Relay default, does not select a session.
		case argument == "--permission-mode" && i+1 < len(arguments) && !strings.HasPrefix(arguments[i+1], "-"):
			i++
		case strings.HasPrefix(argument, "--permission-mode=") && argument != "--permission-mode=":
		default:
			return "", false
		}
	}
	if continuations != 1 {
		return "", false
	}
	input, inputErr := os.Stdin.Stat()
	output, outputErr := os.Stdout.Stat()
	if inputErr != nil || outputErr != nil || input.Mode()&os.ModeCharDevice == 0 || output.Mode()&os.ModeCharDevice == 0 {
		return "", false
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, "agents", "--json", "--cwd", cwd)
	command.Env = agentExecEnvironment(os.Environ())
	command.Stdin = nil
	command.Stderr = io.Discard
	var rows []struct {
		Kind      string `json:"kind"`
		CWD       string `json:"cwd"`
		ID        string `json:"id"`
		SessionID string `json:"sessionId"`
		PID       int    `json:"pid"`
	}
	stdout, err := command.StdoutPipe()
	if err != nil || command.Start() != nil {
		return "", false
	}
	data, readErr := io.ReadAll(io.LimitReader(stdout, 131073))
	if len(data) > 131072 {
		cancel()
	}
	waitErr := command.Wait()
	if readErr != nil || waitErr != nil || len(data) > 131072 || json.Unmarshal(data, &rows) != nil {
		return "", false
	}
	retained, _ := daemon.RetainedClaudeSession(os.Getenv("RELAY_SESSION"))
	background := false
	target := ""
	matching := 0
	for _, row := range rows {
		if row.Kind == "background" && row.CWD == cwd && row.ID != "" && row.SessionID != "" && row.PID > 0 {
			background = true
			if retained != "" && row.SessionID == retained {
				matching++
				target = row.ID
			}
		}
	}
	if matching != 1 {
		target = ""
	}
	return target, background
}

func runCodex(arguments []string) {
	home, err := os.UserHomeDir()
	if err != nil {
		fatal(err.Error())
	}
	admitAccount(home, "codex", false)
	prepareAccount(home, "codex")
	executable, err := resolveStockCodexExecutable()
	if err != nil {
		fatal(err.Error())
	}
	withDefaults := agentaccounts.WithCodexDefaults(accountModelDefaults("codex", codexHome(os.Environ())), arguments)
	effective, stop, err := prepareManagedStockCodex(executable, withDefaults, stockCodexEnvironment(os.Environ()))
	if err != nil {
		fatal("Codex could not start with Relay messaging: " + err.Error())
	}
	codexArguments := append([]string{"codex"}, effective...)
	environment := captureAgentLaunch(home, "codex", executable, arguments, codexArguments[1:])
	environment = stockCodexEnvironment(environment)
	if err := syscall.Exec(executable, codexArguments, environment); err != nil {
		stop()
		fatal(err.Error())
	}
}

// admitAccount starts an agent only with the provider default or one of
// this host's registered account folders; a removed account is never started
// again. The folder stays open in the agent, so a removal in progress sees it.
// held: the variable was set by this process (a rotation worker), so it is
// not in the environment a removal reads, and the folder must be held open.
func admitAccount(home, provider string, held bool) {
	name, err := agentlaunch.ConfigDirVariable(provider)
	if err != nil {
		fatal(err.Error())
	}
	admit := agentaccounts.AdmitLaunch
	if held {
		admit = agentaccounts.AdmitHeldLaunch
	}
	if err := admit(home, provider, os.Getenv(name)); err != nil {
		fatal(err.Error())
	}
}

// prepareAccount copies the main account's first-run and trust answers into
// the account this agent starts with, so it never stops at a first-run
// screen. It never blocks the launch.
func prepareAccount(home, provider string) {
	name, err := agentlaunch.ConfigDirVariable(provider)
	if err != nil {
		return
	}
	if note := agentaccounts.PrepareLaunch(home, provider, os.Getenv(name)); note != "" {
		fmt.Fprintln(os.Stderr, "Relay: "+note+".")
	}
}

// accountModelDefaults reads the launching account's model and effort; a
// file that cannot be used is reported and ignored.
func accountModelDefaults(provider, root string) agentaccounts.ModelDefaults {
	defaults, err := agentaccounts.ReadModelDefaults(provider, root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Relay: this account's model defaults were not applied: "+err.Error())
	}
	return defaults
}

func claudeConfigRoot(home string) string {
	if configured := os.Getenv("CLAUDE_CONFIG_DIR"); configured != "" && filepath.IsAbs(configured) {
		return configured
	}
	return filepath.Join(home, ".claude")
}

// Capture before exec, while argv is available verbatim. Exec preserves the
// PID/incarnation. Capture failure does not change the user's requested launch;
// it only makes that process ineligible for automatic rotation.
func captureAgentLaunch(home, client, executable string, requested, effective []string) []string {
	environment := agentExecEnvironment(os.Environ())
	if client == "claude" && os.Getenv("RELAY_PROMPT_EDITOR_ENABLE") == "1" && os.Getenv("RELAY_SESSION") != "" {
		helper, err := os.Executable()
		if err == nil {
			prepared, bridgeErr := daemon.PreparePromptEditorEnvironment(home, helper, os.Getenv("RELAY_SESSION"), environment)
			if bridgeErr == nil {
				environment = prepared
			}
		}
	}
	cwd, err := os.Getwd()
	if err != nil {
		return environment
	}
	path, err := agentlaunch.Save(filepath.Join(home, ".local", "share", "relay", "agent-launches"),
		client, executable, cwd, os.Getenv("RELAY_SESSION"), agentlaunch.ProcessStart(), requested, effective)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Relay could not retain launch parameters; automatic rotation is unavailable for this launch.")
		return environment
	}
	filtered := make([]string, 0, len(environment)+1)
	for _, entry := range environment {
		if !strings.HasPrefix(entry, "RELAY_AGENT_LAUNCH_SNAPSHOT=") {
			filtered = append(filtered, entry)
		}
	}
	return append(filtered, "RELAY_AGENT_LAUNCH_SNAPSHOT="+path)
}

// The shim marker only selects relayd's dispatch path. It must not leak into the agent process:
// hooks spawned by that process call relayd by its real name and need the normal daemon commands.
func agentExecEnvironment(environment []string) []string {
	filtered := make([]string, 0, len(environment))
	for _, entry := range environment {
		name, _, found := strings.Cut(entry, "=")
		if found && name == "RELAY_INVOKED_AS" {
			continue
		}
		filtered = append(filtered, entry)
	}
	return filtered
}

func findRealAgentExecutable(name string) (string, error) {
	selfPath, selfErr := os.Executable()
	var selfInfo os.FileInfo
	if selfErr == nil {
		selfInfo, _ = os.Stat(selfPath)
	}
	if configured := strings.TrimSpace(os.Getenv("RELAY_" + strings.ToUpper(name) + "_BIN")); configured != "" {
		if fallback, ok := agentaccounts.ConfiguredExecutableFallback(name, configured); ok {
			return fallback, nil
		}
		info, err := os.Stat(configured)
		if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
			return "", fmt.Errorf("configured %s executable is not runnable: %s", name, configured)
		}
		if selfInfo != nil && os.SameFile(selfInfo, info) {
			return "", fmt.Errorf("configured %s executable points back to relayd", name)
		}
		absolute, err := filepath.Abs(configured)
		if err != nil {
			return "", err
		}
		return absolute, nil
	}
	relayShimDirectory := ""
	if home, err := os.UserHomeDir(); err == nil {
		relayShimDirectory = filepath.Clean(filepath.Join(home, ".local", "share", "relay", "shims"))
	}
	for _, directory := range filepath.SplitList(os.Getenv("PATH")) {
		if directory == "" {
			directory = "."
		}
		absoluteDirectory, err := filepath.Abs(directory)
		if err == nil && relayShimDirectory != "" && filepath.Clean(absoluteDirectory) == relayShimDirectory {
			continue
		}
		candidate := filepath.Join(directory, name)
		info, err := os.Stat(candidate)
		if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
			continue
		}
		if selfInfo != nil && os.SameFile(selfInfo, info) {
			continue
		}
		if !filepath.IsAbs(candidate) {
			candidate, err = filepath.Abs(candidate)
			if err != nil {
				continue
			}
		}
		return candidate, nil
	}
	return "", fmt.Errorf("%s is not available on PATH", name)
}

const codexHookCommand = `if [ -n "$RELAY_SESSION" ]; then ~/.local/bin/relayd event --session "$RELAY_SESSION" --agent codex; fi`

type codexHookSpec struct {
	event   string
	matcher *string
}

var codexWildcardMatcher = "*"

var codexHookSpecs = []codexHookSpec{
	{event: "session_start", matcher: &codexWildcardMatcher},
	{event: "user_prompt_submit"},
	{event: "pre_tool_use", matcher: &codexWildcardMatcher},
	{event: "permission_request", matcher: &codexWildcardMatcher},
	{event: "post_tool_use", matcher: &codexWildcardMatcher},
	{event: "subagent_start", matcher: &codexWildcardMatcher},
	{event: "subagent_stop", matcher: &codexWildcardMatcher},
	{event: "stop"},
	{event: "session_end", matcher: &codexWildcardMatcher},
}

func codexHookProfile(profilePath string) string {
	var state strings.Builder
	state.WriteString("# Managed by Relay Terminal. Remove this file to uninstall the profile.\n")
	state.WriteString("[tui]\nterminal_resize_reflow_max_rows = 256\n\n")
	for _, spec := range codexHookSpecs {
		key := profilePath + ":" + spec.event + ":0:0"
		state.WriteString("[hooks.state.")
		state.WriteString(strconv.Quote(key))
		state.WriteString("]\ntrusted_hash = ")
		state.WriteString(strconv.Quote(codexHookHash(spec.event, spec.matcher)))
		state.WriteString("\n\n")
	}
	state.WriteString(codexHookEvents)
	return state.String()
}

func codexHookHash(event string, matcher *string) string {
	identity := map[string]any{
		"event_name": event,
		"hooks": []any{map[string]any{
			"type": "command", "command": codexHookCommand, "async": true, "timeout": 3,
		}},
	}
	if matcher != nil {
		identity["matcher"] = *matcher
	}
	serialized, _ := json.Marshal(identity)
	digest := sha256.Sum256(serialized)
	return fmt.Sprintf("sha256:%x", digest)
}

const codexHookEvents = `
[[hooks.SessionStart]]
matcher = "*"
[[hooks.SessionStart.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.PreToolUse]]
matcher = "*"
[[hooks.PreToolUse.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.PermissionRequest]]
matcher = "*"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.PostToolUse]]
matcher = "*"
[[hooks.PostToolUse.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.SubagentStart]]
matcher = "*"
[[hooks.SubagentStart.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.SubagentStop]]
matcher = "*"
[[hooks.SubagentStop.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3

[[hooks.SessionEnd]]
matcher = "*"
[[hooks.SessionEnd.hooks]]
type = "command"
command = '` + codexHookCommand + `'
async = true
timeout = 3
`

const claudeHookSettings = `{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}],
    "PermissionRequest": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}],
    "PostToolUseFailure": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}],
    "Notification": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}],
    "SubagentStart": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}],
    "SubagentStop": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "if [ -n \"$RELAY_SESSION\" ]; then ~/.local/bin/relayd event --session \"$RELAY_SESSION\" --agent claude --bind; fi"}]}]
  },
  "statusLine": {"type": "command", "command": "~/.local/bin/relayd claude-statusline", "refreshInterval": 10}
}`

func runEvent(arguments []string) {
	flags := flag.NewFlagSet("event", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	session := flags.String("session", "", "Relay session ID")
	agent := flags.String("agent", "unknown", "agent kind")
	source := flags.String("source", "hook", "hook, codex-app-server, claude-stream-json, or provider-native")
	stream := flags.Bool("stream", false, "read newline-delimited provider events until EOF")
	bind := flags.Bool("bind", false, "authenticated provider binding channel (requires supporting supervisor)")
	_ = flags.Parse(arguments)
	if *session == "" {
		fatal("--session is required")
	}
	if err := daemon.ValidateNativeAgentSource(*source); err != nil {
		fatal(err.Error())
	}
	if *bind {
		if *source != "hook" || *stream {
			fatal("binding requires a one-shot provider hook")
		}
	}
	// Claude's one-shot hooks may spend time producing their JSON on stdin.
	// Read it before opening the event-only connection: the supervisor can
	// close a connection whose pane worker is unavailable before the hook has
	// finished writing, which otherwise surfaces as a broken-pipe hook error.
	var raw []byte
	if !*stream {
		var err error
		raw, err = io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
		if err != nil {
			fatal(err.Error())
		}
	}
	if *bind {
		// Local kernel/worker verification also works with a retained older
		// supervisor. Failure remains optional telemetry and cannot block a turn.
		if err := daemon.StoreNativeAgentHook(*session, *agent, raw); err != nil && os.Getenv("RELAY_NATIVE_BINDING_DIAGNOSTICS") == "1" {
			message := err.Error()
			if len(message) > 400 {
				message = message[:400]
			}
			fmt.Fprintln(os.Stderr, "Relay native hook binding unavailable:", message)
		}
		if err := daemon.RequireAgentBindingCapability(*socket, *session); err != nil {
			*bind = false
		}
	}
	connection, err := net.Dial("unix", *socket)
	if err != nil {
		if *source == "hook" && !*stream && isEventTransportError(err) {
			return
		}
		fatal(err.Error())
	}
	defer connection.Close()
	writer := protocol.NewWriter(connection)
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: *session, EventOnly: true, BindAgent: *bind,
	})
	if err := writer.Write(hello); err != nil {
		if *source == "hook" && !*stream && isEventTransportError(err) {
			return
		}
		fatal(err.Error())
	}
	emit := func(raw []byte) error {
		if len(raw) == 0 || !json.Valid(raw) {
			return nil
		}
		if *bind && *source == "hook" && !*stream {
			var hook map[string]any
			if json.Unmarshal(raw, &hook) == nil {
				sessionID, _ := hook["session_id"].(string)
				path, _ := hook["transcript_path"].(string)
				if sessionID != "" && len(sessionID) <= 128 && len(path) <= 4096 {
					binding, bindingErr := protocol.JSONFrame(protocol.AgentBinding, map[string]any{
						"provider": *agent, "session_id": sessionID, "transcript_path": path,
					})
					if bindingErr != nil {
						return bindingErr
					}
					if writeErr := writer.Write(binding); writeErr != nil {
						return writeErr
					}
				}
			}
		}
		envelope, canonicalErr := daemon.CanonicalAgentEnvelope(*agent, raw, *source)
		if canonicalErr != nil {
			return canonicalErr
		}
		return writer.Write(protocol.Frame{Type: protocol.AgentEvent, Payload: envelope})
	}
	if *stream {
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 64<<10), 1<<20)
		for scanner.Scan() {
			if err := emit(scanner.Bytes()); err != nil {
				fatal(err.Error())
			}
		}
		if err := scanner.Err(); err != nil {
			fatal(err.Error())
		}
		return
	}
	if err := emit(raw); err != nil {
		// Hook events are best-effort status telemetry. Losing the Relay
		// connection must not turn a completed Claude turn into a hook error.
		if *source == "hook" && isEventTransportError(err) {
			return
		}
		fatal(err.Error())
	}
	if *bind {
		_ = connection.SetReadDeadline(time.Now().Add(3 * time.Second))
		frame, err := protocol.ReadFrame(connection)
		var status protocol.StatusPayload
		if err != nil || frame.Type != protocol.Status || protocol.DecodeJSON(frame, &status) != nil || status.State != "agent_event_received" {
			return
		}
	}

}

func isEventTransportError(err error) bool {
	var netErr *net.OpError
	return errors.As(err, &netErr) ||
		errors.Is(err, syscall.EPIPE) || errors.Is(err, syscall.ECONNRESET)
}

func runDaemon(arguments []string) {
	flags := flag.NewFlagSet("daemon", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	_ = flags.Parse(arguments)
	// Question-thread leases renew and notify from the same long-lived daemon.
	go daemon.RunQuestionThreadPoller(context.Background())
	server := daemon.NewServerWithBuildInfo(relaydVersion, supervisorProtocolVersion)
	// Archive deletion requires every relayd on this node to support tombstones.
	server.SetHostJobPeerSockets([]string{*socket, defaultSocket(), legacySocket()})
	if err := server.Serve(*socket); err != nil {
		fatal(err.Error())
	}
}

func runWorker(arguments []string) {
	flags := flag.NewFlagSet("worker", flag.ExitOnError)
	socket := flags.String("socket", "", "private worker Unix socket path")
	manifest := flags.String("manifest", "", "worker manifest path")
	session := flags.String("session", "", "durable session ID")
	cols := flags.Uint("cols", 120, "terminal columns")
	rows := flags.Uint("rows", 36, "terminal rows")
	resumeStateFD := flags.Int("resume-state-fd", -1, "worker state descriptor left by a re-executing worker")
	resumePTYFD := flags.Int("resume-pty-fd", -1, "PTY master descriptor left by a re-executing worker")
	resumeListenerFD := flags.Int("resume-listener-fd", -1, "socket descriptor left by a re-executing worker")
	resumeShellPID := flags.Int("resume-shell-pid", 0, "pane shell PID owned by a re-executing worker")
	resumeOperation := flags.String("resume-operation", "", "worker upgrade operation ID")
	_ = flags.Parse(arguments)
	token := os.Getenv("RELAY_WORKER_TOKEN")
	commandBase64 := os.Getenv("RELAY_WORKER_COMMAND_B64")
	workingDirectoryBase64 := os.Getenv("RELAY_WORKER_CWD_B64")
	if *socket == "" || *manifest == "" || *session == "" || token == "" {
		fatal("worker requires --socket, --manifest, --session, and RELAY_WORKER_TOKEN")
	}
	decode := func(value, label string) string {
		if value == "" {
			return ""
		}
		decoded, err := base64.StdEncoding.DecodeString(value)
		if err != nil {
			fatal("invalid " + label)
		}
		return string(decoded)
	}
	config := daemon.WorkerConfig{
		SocketPath: *socket, ManifestPath: *manifest,
		SessionID: *session, Token: token,
		Command:            decode(commandBase64, "RELAY_WORKER_COMMAND_B64"),
		WorkingDirectory:   decode(workingDirectoryBase64, "RELAY_WORKER_CWD_B64"),
		RotationControlled: os.Getenv("RELAY_ROTATION_WORKER") == "1",
		Cols:               uint16(*cols), Rows: uint16(*rows),
	}
	if *resumePTYFD >= 0 {
		config.Resume = &daemon.WorkerResume{
			StateFD: *resumeStateFD, PTYFD: *resumePTYFD, ListenerFD: *resumeListenerFD,
			ShellPID: *resumeShellPID, Operation: *resumeOperation,
		}
	}
	if err := daemon.ServeWorker(config); err != nil {
		fatal(err.Error())
	}
}

// runWorkerReexecProbe is run by a pane worker, as the executable it is about
// to exec, on the state it will hand over. It only decodes; it owns nothing.
func runWorkerReexecProbe(arguments []string) {
	flags := flag.NewFlagSet("worker-reexec-probe", flag.ExitOnError)
	stateFD := flags.Int("state-fd", -1, "worker state descriptor")
	_ = flags.Parse(arguments)
	if *stateFD < 3 {
		fatal("usage: relayd worker-reexec-probe --state-fd FD")
	}
	if err := daemon.ProbeWorkerReexecState(os.NewFile(uintptr(*stateFD), "relay-worker-state"), os.Stdout); err != nil {
		fatal(err.Error())
	}
}

// runUpgradeWorkers moves live pane workers on this node to this relayd
// without restarting their shells or agents. Run it after upgrade-supervisor.
func runUpgradeWorkers(arguments []string) {
	flags := flag.NewFlagSet("upgrade-workers", flag.ExitOnError)
	executable := flags.String("executable", "", "relayd to run in the workers (default: this executable)")
	session := flags.String("session", "", "upgrade only this pane")
	stateDir := flags.String("state-dir", "", "worker state directory (default: the daemon's)")
	dryRun := flags.Bool("dry-run", false, "report what would be upgraded")
	timeout := flags.Duration("timeout", 30*time.Second, "per-worker deadline")
	busyRetries := flags.Int("busy-retries", 10, "times to retry a worker whose pane is busy")
	busyRetryInterval := flags.Duration("busy-retry-interval", 30*time.Second, "wait between busy retries")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *busyRetries < 0 || *busyRetryInterval < 0 {
		fatal("usage: relayd upgrade-workers [--session ID] [--executable PATH] [--dry-run] [--busy-retries N] [--busy-retry-interval D]")
	}
	options := daemon.WorkerUpgradeOptions{StateDir: *stateDir, Executable: *executable, DryRun: *dryRun, Timeout: *timeout,
		BusyRetries: *busyRetries, BusyRetryInterval: *busyRetryInterval}
	if *session != "" {
		options.Sessions = []string{*session}
	}
	results, err := daemon.UpgradeWorkers(options)
	if err != nil {
		fatal(err.Error())
	}
	if err := daemon.EncodeJSON(os.Stdout, results); err != nil {
		fatal(err.Error())
	}
	for _, result := range results {
		if result.Result == "failed" || result.Result == "unconfirmed" {
			os.Exit(1)
		}
	}
}

func runAttach(arguments []string) {
	flags := flag.NewFlagSet("attach", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	session := flags.String("session", "", "durable session ID")
	parentSession := flags.String("parent-session", "", "session whose working directory should be inherited")
	workspace := flags.String("workspace", "", "durable workspace session ID")
	tab := flags.String("tab", "", "durable tab ID")
	paneTitle := flags.String("pane-title", "", "pane display name")
	contentKind := flags.String("content-kind", "terminal", "pane content kind")
	commandBase64 := flags.String("command-b64", "", "base64-encoded startup command")
	cols := flags.Uint("cols", 120, "terminal columns")
	rows := flags.Uint("rows", 36, "terminal rows")
	lastSequence := flags.Uint64("last-seq", 0, "last received output sequence")
	lastEventSequence := flags.Uint64("last-event-seq", 0, "last received agent event sequence")
	terminalOnly := flags.Bool("terminal-only", false, "exclude agent events from the terminal stream")
	observeProgramStatus := os.Getenv("RELAY_OBSERVE_PROGRAM_STATUS") == "1"
	requireExistingWorker := flags.Bool("require-existing-worker", false, "attach only to an existing pane worker")
	clientID := flags.String("client-id", "", "durable input client identity")
	_ = flags.Parse(arguments)
	if *session == "" {
		fatal("--session is required")
	}
	command := ""
	if *commandBase64 != "" {
		decoded, err := base64.StdEncoding.DecodeString(*commandBase64)
		if err != nil {
			fatal("invalid --command-b64")
		}
		command = string(decoded)
	}
	connection, err := connectOrStart(*socket)
	if err != nil {
		fatal(err.Error())
	}
	defer connection.Close()
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: *session, ParentSessionID: *parentSession, Command: command,
		WorkspaceID: *workspace, TabID: *tab, PaneTitle: *paneTitle, ContentKind: *contentKind,
		Cols: uint16(*cols), Rows: uint16(*rows), LastSeq: *lastSequence, LastEventSeq: *lastEventSequence,
		TerminalOnly: *terminalOnly, ObserveProgramStatus: observeProgramStatus, ClientID: *clientID, RequireExistingWorker: *requireExistingWorker,
		RepaintPulse: os.Getenv("RELAY_ATTACH_REPAINT") == "1",
	})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		fatal(err.Error())
	}
	done := make(chan error, 1)
	go func() {
		_, copyErr := io.Copy(connection, os.Stdin)
		done <- copyErr
	}()
	go func() {
		_, copyErr := io.Copy(os.Stdout, connection)
		done <- copyErr
	}()
	if copyErr := <-done; copyErr != nil {
		fatal(copyErr.Error())
	}
}

// runNode exposes one framed, bidirectional stream for every pane on a node.
// HostEvent is the channel envelope; its inner frame is exactly the existing
// per-pane protocol, which keeps workers and old manifests compatible.
func runNode(arguments []string) {
	flags := flag.NewFlagSet("node", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 {
		fatal("usage: relayd node")
	}
	connection, err := connectOrStart(*socket)
	if err != nil {
		fatal(err.Error())
	}
	defer connection.Close()
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: 1, NodeMux: true})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		fatal(err.Error())
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := loopbackproxy.RelayNodeWithHostRequestHandlers(ctx, os.Stdin, os.Stdout, connection, daemon.HandleNodeHostRotationRequest, daemon.NodeHostAccountsHandler(*socket)); err != nil && err != io.EOF && ctx.Err() == nil {
		fatal("node transport ended: " + err.Error())
	}
}

func runSessions(arguments []string) {
	flags := flag.NewFlagSet("sessions", flag.ExitOnError)
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 {
		fatal("usage: relayd sessions")
	}
	snapshot, err := daemon.NewServer().CatalogSnapshot()
	if err != nil {
		fatal(err.Error())
	}
	if err := daemon.EncodeJSON(os.Stdout, snapshot); err != nil {
		fatal(err.Error())
	}
}

func runRecover(arguments []string) {
	flags := flag.NewFlagSet("recover", flag.ExitOnError)
	session := flags.String("session", "", "pane session ID")
	pid := flags.Int("worker-pid", 0, "existing PTY worker to recover")
	_ = flags.Parse(arguments)
	if *session == "" || *pid <= 1 || flags.NArg() != 0 {
		fatal("usage: relayd recover --session <pane-id> --worker-pid <pid>")
	}
	if err := daemon.NewServer().RecoverWorker(*session, *pid); err != nil {
		fatal(err.Error())
	}
	fmt.Printf("Recovered pane %s using existing worker %d. Reconnect the pane to attach.\n", *session, *pid)
}

func runTerminate(arguments []string) {
	flags := flag.NewFlagSet("terminate", flag.ExitOnError)
	session := flags.String("session", "", "pane session ID")
	forget := flags.Bool("forget", false, "remove the stopped pane from this node's catalog")
	_ = flags.Parse(arguments)
	if *session == "" || flags.NArg() != 0 {
		fatal("usage: relayd terminate --session <pane-id>")
	}
	if err := daemon.NewServer().TerminatePane(*session); err != nil {
		fatal(err.Error())
	}
	if *forget {
		if err := daemon.NewServer().ForgetPane(*session); err != nil {
			fatal(err.Error())
		}
	}
}

func runForget(arguments []string) {
	flags := flag.NewFlagSet("forget", flag.ExitOnError)
	session := flags.String("session", "", "pane session ID")
	_ = flags.Parse(arguments)
	if *session == "" || flags.NArg() != 0 {
		fatal("usage: relayd forget --session <pane-id>")
	}
	if err := daemon.NewServer().ForgetPane(*session); err != nil {
		fatal(err.Error())
	}
}

func runGC(arguments []string) {
	flags := flag.NewFlagSet("gc", flag.ExitOnError)
	olderThan := flags.Duration("older-than", 30*24*time.Hour, "minimum age for exited or stale panes")
	dryRun := flags.Bool("dry-run", false, "list eligible pane IDs without deleting them")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *olderThan < time.Hour {
		fatal("usage: relayd gc [--older-than 720h] [--dry-run]")
	}
	removed, err := daemon.NewServer().CollectGarbage(*olderThan, *dryRun)
	if err != nil {
		fatal(err.Error())
	}
	for _, id := range removed {
		fmt.Println(id)
	}
}

// runGCHostJobs deletes archived host-job folders past the retention. Each
// deleted job ID stays reserved by a tombstone; the report is JSON.
func runGCHostJobs(arguments []string) {
	const usage = "usage: relayd gc-host-jobs [--older-than 7d] [--dry-run] [--state-dir DIR] | --activate | --deactivate"
	flags := flag.NewFlagSet("gc-host-jobs", flag.ExitOnError)
	olderThan := flags.String("older-than", "", "retention for finished archived jobs, in days (7d) or a duration (36h); "+
		"default: RELAYD_HOST_JOB_RETENTION, then the state directory's host-job-retention file, then 7d")
	dryRun := flags.Bool("dry-run", false, "report what would be removed without changing anything")
	activate := flags.Bool("activate", false, "allow archive deletion for this state directory; only after every node sharing it runs a tombstone-aware relayd")
	deactivate := flags.Bool("deactivate", false, "stop archive deletion for this state directory and clear legacy evidence")
	stateDir := flags.String("state-dir", "", "worker state directory")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 || *activate && *deactivate || (*activate || *deactivate) && (*dryRun || *olderThan != "") {
		fatal(usage)
	}
	directory := *stateDir
	if directory != "" {
		var err error
		if directory, err = filepath.Abs(directory); err != nil {
			fatal(err.Error())
		}
	}
	if *deactivate {
		if err := daemon.DeactivateHostJobCleanup(directory); err != nil {
			fatal(err.Error())
		}
		fmt.Println("archive deletion deactivated; legacy evidence cleared")
		return
	}
	if *activate {
		pids, err := tombstoneAwareRelaydPIDs([]string{defaultSocket(), legacySocket()})
		if err != nil {
			fatal(err.Error() + "; not activated")
		}
		activation, err := daemon.ActivateHostJobCleanup(directory, relaydVersion, pids, time.Now())
		if err != nil {
			fatal(err.Error() + "; not activated")
		}
		raw, _ := json.MarshalIndent(activation, "", "  ")
		fmt.Println(string(raw))
		return
	}
	retention := daemon.ResolveHostJobRetention(directory)
	if *olderThan != "" {
		parsed, err := daemon.ParseHostJobRetention(*olderThan)
		if err != nil {
			fatal(usage + ": " + err.Error())
		}
		retention = daemon.HostJobRetention{Duration: parsed, Source: "--older-than"}
	}
	for _, warning := range retention.Warnings {
		fmt.Fprintln(os.Stderr, "relayd: warning:", warning)
	}
	options := daemon.HostJobCleanupOptions{OlderThan: retention.Duration, DryRun: *dryRun, Wait: time.Minute}
	if !*dryRun {
		// The same handshake as the daemon's pass: every relayd on this node
		// must know tombstones and be registered for this state directory.
		pids, err := tombstoneAwareRelaydPIDs([]string{defaultSocket(), legacySocket()})
		if err != nil {
			fatal(err.Error() + "; nothing was deleted")
		}
		options.LiveServerPIDs = pids
	}
	result, err := daemon.CleanupArchivedHostJobs(directory, options)
	daemon.ApplyHostJobRetention(&result, retention)
	raw, _ := json.MarshalIndent(result, "", "  ")
	fmt.Println(string(raw))
	if err != nil {
		fatal(err.Error())
	}
}

// tombstoneAwareRelaydPIDs probes each socket with the daemon's shared
// handshake. A live relayd that does not support tombstones refuses.
func tombstoneAwareRelaydPIDs(sockets []string) ([]int, error) {
	return daemon.ProbeHostJobTombstoneServers(sockets)
}

func runObserve(arguments []string) {
	flags := flag.NewFlagSet("observe", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	session := flags.String("session", "", "durable session ID")
	lastSequence := flags.Uint64("last-seq", 0, "fallback replay position for older workers")
	lastEventSequence := flags.Uint64("last-event-seq", 0, "last received agent event sequence")
	_ = flags.Parse(arguments)
	if *session == "" {
		fatal("--session is required")
	}
	connection, err := connectOrStart(*socket)
	if err != nil {
		fatal(err.Error())
	}
	defer connection.Close()
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: *session, LastSeq: *lastSequence, LastEventSeq: *lastEventSequence, ObserveEvents: true,
	})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		fatal(err.Error())
	}
	done := make(chan error, 2)
	go func() {
		_, copyErr := io.Copy(connection, os.Stdin)
		done <- copyErr
	}()
	go func() {
		_, copyErr := io.Copy(os.Stdout, connection)
		done <- copyErr
	}()
	// Parent death closes SSH stdin. Returning here closes the remote observer
	// instead of leaving an orphaned SSH channel that can exhaust MaxSessions.
	if copyErr := <-done; copyErr != nil {
		fatal(copyErr.Error())
	}
}

func runObserveMany(arguments []string) {
	flags := flag.NewFlagSet("observe-many", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	sessionList := flags.String("sessions", "", "comma-separated session IDs, optionally followed by :last-event-seq")
	_ = flags.Parse(arguments)
	sessions := parseObservedSessions(*sessionList)
	if len(sessions) == 0 {
		fatal("--sessions is required")
	}
	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, os.Stdin)
		close(done)
	}()
	writer := protocol.NewWriter(os.Stdout)
	var workers sync.WaitGroup
	for _, observed := range sessions {
		workers.Add(1)
		go func(observed observedSession) {
			defer workers.Done()
			for {
				select {
				case <-done:
					return
				default:
				}
				connection, err := connectOrStart(*socket)
				if err == nil {
					connectionFinished := make(chan struct{})
					go func() {
						select {
						case <-done:
							// Unblock a quiet observer immediately when its SSH
							// channel closes; otherwise ReadFrame can wait forever.
							_ = connection.Close()
						case <-connectionFinished:
						}
					}()
					hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
						Version: 1, SessionID: observed.id, LastEventSeq: observed.lastEventSequence, ObserveEvents: true,
					})
					err = protocol.NewWriter(connection).Write(hello)
					for err == nil {
						frame, readErr := protocol.ReadFrame(connection)
						if readErr != nil {
							err = readErr
							break
						}
						if frame.Type == protocol.AgentEvent || frame.Type == protocol.Status {
							if writer.Write(protocol.HostEventFrame(observed.id, frame)) != nil {
								_ = connection.Close()
								return
							}
						}
					}
					_ = connection.Close()
					close(connectionFinished)
				}
				select {
				case <-done:
					return
				case <-time.After(time.Second):
				}
			}
		}(observed)
	}
	workers.Wait()
}

type observedSession struct {
	id                string
	lastEventSequence uint64
}

func parseObservedSessions(value string) []observedSession {
	seen := make(map[string]bool)
	sessions := make([]observedSession, 0)
	for _, item := range strings.Split(value, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		id := item
		var sequence uint64
		if separator := strings.LastIndexByte(item, ':'); separator > 0 {
			if parsed, err := strconv.ParseUint(item[separator+1:], 10, 64); err == nil {
				id = item[:separator]
				sequence = parsed
			}
		}
		if id != "" && !seen[id] {
			seen[id] = true
			sessions = append(sessions, observedSession{id: id, lastEventSequence: sequence})
		}
	}
	return sessions
}

func connectOrStart(socket string) (net.Conn, error) {
	if connection, err := dialDaemon(socket, 250*time.Millisecond); err == nil {
		return connection, nil
	}
	if err := daemon.EnsurePrivateRuntimeDir(filepath.Dir(socket)); err != nil {
		return nil, err
	}
	// Many panes commonly reconnect at once after a VPN interruption or an app
	// restart. Serialize supervisor startup so they do not all fork a daemon;
	// the losing children otherwise become zombies for the lifetime of their
	// SSH channel and can eventually exhaust the user's process allowance.
	startLock, err := daemon.OpenPrivateFile(socket+".start.lock", syscall.O_CREAT|syscall.O_RDWR)
	if err != nil {
		return nil, err
	}
	defer startLock.Close()
	deadline := time.Now().Add(3 * time.Second)
	for {
		if err := syscall.Flock(int(startLock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
			break
		}
		if connection, dialErr := dialDaemon(socket, 100*time.Millisecond); dialErr == nil {
			return connection, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("timed out waiting for relayd startup lock")
		}
		time.Sleep(25 * time.Millisecond)
	}
	defer syscall.Flock(int(startLock.Fd()), syscall.LOCK_UN)
	if connection, err := dialDaemon(socket, 250*time.Millisecond); err == nil {
		return connection, nil
	}
	// A terminating supervisor closes its socket before the process releases
	// its lifetime lock. Starting in that narrow window makes the replacement
	// exit immediately as a duplicate. Wait for the lock, while still accepting
	// a supervisor that another client successfully started.
	supervisorDeadline := time.Now().Add(3 * time.Second)
	for {
		available, lockErr := supervisorLockAvailable(socket)
		if lockErr != nil {
			return nil, lockErr
		}
		if available {
			break
		}
		if connection, dialErr := dialDaemon(socket, 100*time.Millisecond); dialErr == nil {
			return connection, nil
		}
		if time.Now().After(supervisorDeadline) {
			return nil, fmt.Errorf("timed out waiting for previous relayd supervisor to exit")
		}
		time.Sleep(25 * time.Millisecond)
	}
	logPath := filepath.Join(filepath.Dir(socket), "relayd.log")
	logFile, err := daemon.OpenPrivateFile(logPath, syscall.O_CREAT|syscall.O_APPEND|syscall.O_WRONLY)
	if err != nil {
		return nil, err
	}
	defer logFile.Close()
	child := exec.Command(os.Args[0], "daemon", "--socket", socket)
	child.Env = daemon.TerminalEnvironment(os.Environ())
	child.Stdin = nil
	child.Stdout = logFile
	child.Stderr = logFile
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := child.Start(); err != nil {
		return nil, err
	}
	childPID := child.Process.Pid
	// The supervisor is session-detached and survives this client, but while
	// the client remains alive it is still the supervisor's Unix parent. Reap a
	// supervisor that exits during an upgrade instead of leaving a zombie next
	// to every long-lived node/attach process. If this client exits first, the
	// detached supervisor is simply adopted by the host's normal reaper.
	go func() { _ = child.Wait() }()
	for attempt := 0; attempt < 80; attempt++ {
		time.Sleep(25 * time.Millisecond)
		if connection, dialErr := dialDaemon(socket, 250*time.Millisecond); dialErr == nil {
			return connection, nil
		}
	}
	return nil, fmt.Errorf("relayd did not start (pid %s)", strconv.Itoa(childPID))
}

func probeDaemon(socket string) bool {
	_, err := probeDaemonStatus(socket)
	return err == nil
}

func probeDaemonStatus(socket string) (protocol.StatusPayload, error) {
	var status protocol.StatusPayload
	connection, err := dialDaemon(socket, 250*time.Millisecond)
	if err != nil {
		return status, err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(500 * time.Millisecond))
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: "_probe", Probe: true,
	})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return status, err
	}
	frame, err := protocol.ReadFrame(connection)
	if err != nil || frame.Type != protocol.Status {
		return status, fmt.Errorf("invalid relayd probe response")
	}
	if err := protocol.DecodeJSON(frame, &status); err != nil || status.State != "ready" {
		return status, fmt.Errorf("relayd is not ready")
	}
	return status, nil
}

func dialDaemon(socket string, timeout time.Duration) (net.Conn, error) {
	connection, err := net.DialTimeout("unix", socket, timeout)
	if err != nil {
		return nil, err
	}
	if err := daemon.RequirePeerUID(connection, os.Getuid()); err != nil {
		connection.Close()
		return nil, err
	}
	return connection, nil
}

// Filesystem discovery is a dependency of socket selection. Tests supply a
// private fixture rather than consulting the user's running supervisor.
var defaultSocketRuntimeProbe = existingOwnedRelaydRuntimeSocket

func defaultSocket() string {
	if runtime := os.Getenv("XDG_RUNTIME_DIR"); runtime != "" {
		return filepath.Join(runtime, "relayd.sock")
	}
	if runtime.GOOS == "linux" {
		if socket := defaultSocketRuntimeProbe(filepath.Join("/run/user", strconv.Itoa(os.Getuid())), os.Getuid()); socket != "" {
			return socket
		}
	}
	// HPC nodes commonly share $HOME. The executable and durable catalog can
	// live there, but a Unix socket must remain local to the node that owns the
	// supervisor and PTYs.
	return filepath.Join("/tmp", "relay-"+strconv.Itoa(os.Getuid()), "relayd.sock")
}

// Noninteractive SSH can omit XDG_RUNTIME_DIR even while the user's existing
// supervisor is running there. Never select a shared, foreign or symlinked path.
func existingOwnedRelaydRuntimeSocket(directory string, uid int) string {
	root, err := os.Lstat(directory)
	if err != nil || !root.IsDir() || root.Mode().Perm()&0077 != 0 {
		return ""
	}
	owner, ok := root.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != uid {
		return ""
	}
	path := filepath.Join(directory, "relayd.sock")
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm()&0077 != 0 {
		return ""
	}
	owner, ok = info.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != uid {
		return ""
	}
	return path
}

func legacySocket() string {
	return filepath.Join("/tmp", "relayd-"+strconv.Itoa(os.Getuid())+".sock")
}

func fatal(message string) {
	fmt.Fprintln(os.Stderr, "relayd:", message)
	os.Exit(1)
}

func runStockCodexProxy(arguments []string) {
	flags := flag.NewFlagSet("codex-proxy", flag.ExitOnError)
	pane := flags.String("pane", "", "exact retained Relay pane")
	session := flags.String("session", "", "explicit stock conversation to resume")
	backend := flags.String("backend", "", "existing stock App Server Unix socket")
	pid := flags.Int("backend-pid", 0, "kernel verified backend PID")
	start := flags.Uint64("backend-start", 0, "kernel verified backend incarnation")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 {
		fatal("unexpected stock proxy arguments")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	err := daemon.ServeStockCodexProxy(ctx, daemon.CodexProxyOptions{Pane: *pane, Session: *session, BackendSocket: *backend, BackendPID: *pid, BackendStart: *start}, os.Stdout)
	if err != nil && !errors.Is(err, context.Canceled) {
		fatal("stock Codex proxy unavailable: " + err.Error())
	}
}

package daemon

// usage-summary derives each pane's agent state over a time window from the
// per-pane agent event journals the workers already keep
// (<state>/events/<pane>.jsonl), so panes on older workers have history too.
// It is read-only. Its output carries only states, fixed reason codes, times
// and pane identity: no prompt, tool input, message or transcript content.

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	UsageSummarySchemaVersion = 1
	UsageSummaryMaxWindow     = 14 * 24 * time.Hour
	usageSummaryMaxReadBytes  = 32 << 20 // per journal; the journal itself compacts above 24 MiB
	usageSummaryMaxSegments   = 2000     // per pane
	usageSummaryMaxWaits      = 500      // per pane
	usageSummaryChunk         = 256 << 10
)

// States and reasons are a closed vocabulary.
const (
	usageWorking  = "working"
	usageNeedsYou = "needs_you"
	usageYourTurn = "your_turn"
	usageIdle     = "idle"
	usageEnded    = "ended"

	usageReasonApproval = "approval"
	usageReasonQuestion = "question"
)

var usagePaneFile = regexp.MustCompile(`^([A-Za-z0-9_-]{1,128})\.jsonl$`)

type UsageSegment struct {
	State  string    `json:"state"`
	Reason string    `json:"reason,omitempty"`
	Start  time.Time `json:"start"`
	End    time.Time `json:"end"`
}

type UsageAsks struct {
	Opened      int       `json:"opened"`
	Answered    int       `json:"answered"`
	Open        int       `json:"open"`
	Unanswered  int       `json:"unanswered"` // the agent session ended or the worker went away first
	WaitSeconds []float64 `json:"wait_seconds"`
}

type UsagePane struct {
	PaneID           string         `json:"pane_id"`
	Agent            string         `json:"agent,omitempty"`
	WorkingDirectory string         `json:"working_directory,omitempty"`
	Live             bool           `json:"live"`
	NodeVerified     bool           `json:"node_verified"`
	CurrentState     string         `json:"current_state,omitempty"`
	CurrentReason    string         `json:"current_reason,omitempty"`
	LastEventAt      *time.Time     `json:"last_event_at,omitempty"`
	Segments         []UsageSegment `json:"segments"`
	Asks             UsageAsks      `json:"asks"`
	Truncated        bool           `json:"truncated,omitempty"`
}

type UsageSummary struct {
	SchemaVersion  int         `json:"schema_version"`
	Host           string      `json:"host"`
	GeneratedAt    time.Time   `json:"generated_at"`
	Since          time.Time   `json:"since"`
	Until          time.Time   `json:"until"`
	Panes          []UsagePane `json:"panes"`
	OtherBootPanes int         `json:"other_boot_panes"` // manifest from another node or an earlier boot
	RejectedFiles  int         `json:"rejected_files"`
}

type usageEvent struct {
	at     time.Time
	agent  string
	state  string
	reason string
}

// usageClassify maps one journal payload to a pane state. Subagent events do
// not change the pane's state: a root Stop is the end of the user's turn even
// while background subagents still report tool use.
func usageClassify(payload []byte) (usageEvent, bool) {
	var v struct {
		Agent      string `json:"agent"`
		RecordedAt string `json:"relay_recorded_at"`
		Event      struct {
			HookEventName    string `json:"hook_event_name"`
			Type             string `json:"type"`
			NotificationType string `json:"notification_type"`
			ToolName         string `json:"tool_name"`
			AgentID          string `json:"agent_id"`
			ParentSessionID  string `json:"parent_session_id"`
			OccurredAt       string `json:"occurred_at"`
		} `json:"event"`
	}
	if json.Unmarshal(payload, &v) != nil || (v.Agent != "claude" && v.Agent != "codex") {
		return usageEvent{}, false
	}
	at, err := time.Parse(time.RFC3339Nano, v.RecordedAt)
	if err != nil {
		if at, err = time.Parse(time.RFC3339Nano, v.Event.OccurredAt); err != nil {
			return usageEvent{}, false
		}
	}
	event := usageEvent{at: at.UTC(), agent: v.Agent}
	if v.Event.AgentID != "" || v.Event.ParentSessionID != "" {
		return usageEvent{}, false
	}
	asksUser := v.Event.ToolName == "AskUserQuestion" || v.Event.ToolName == "ExitPlanMode"
	name := v.Event.HookEventName
	if name == "" {
		name = v.Event.Type
	}
	switch name {
	case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop":
		event.state = usageWorking
	case "PreToolUse":
		event.state = usageWorking
		if asksUser {
			event.state, event.reason = usageNeedsYou, usageReasonQuestion
		}
	case "PermissionRequest":
		event.state, event.reason = usageNeedsYou, usageReasonApproval
		if asksUser {
			event.reason = usageReasonQuestion
		}
	case "Notification":
		switch v.Event.NotificationType {
		case "permission_prompt":
			event.state, event.reason = usageNeedsYou, usageReasonApproval
		case "elicitation_dialog":
			event.state, event.reason = usageNeedsYou, usageReasonQuestion
		case "idle_prompt":
			event.state = usageYourTurn
		default:
			return usageEvent{}, false
		}
	case "Stop", "turn/completed":
		event.state = usageYourTurn
	case "SessionStart":
		event.state = usageIdle
	case "SessionEnd":
		event.state = usageEnded
	default:
		return usageEvent{}, false
	}
	return event, true
}

// usageJournalTail returns, oldest first, the classified events of one
// journal from the last one before since onward, and the time of the newest
// record of any kind. It reads backwards and stops at that boundary.
func usageJournalTail(file *os.File, size int64, since time.Time) (events []usageEvent, newest time.Time, truncated bool, err error) {
	offset, read := size, int64(0)
	var carry []byte
	done := false
	consume := func(line []byte) {
		var record indexedAgentRecord
		if len(line) == 0 || json.Unmarshal(line, &record) != nil || record.Sequence == 0 {
			return
		}
		if newest.IsZero() {
			var stamp struct {
				RecordedAt string `json:"relay_recorded_at"`
			}
			if json.Unmarshal(record.Payload, &stamp) == nil {
				if at, err := time.Parse(time.RFC3339Nano, stamp.RecordedAt); err == nil {
					newest = at.UTC()
				}
			}
		}
		event, ok := usageClassify(record.Payload)
		if !ok {
			return
		}
		events = append(events, event)
		if event.at.Before(since) {
			done = true
		}
	}
	for offset > 0 && !done {
		if read >= usageSummaryMaxReadBytes {
			truncated = true
			break
		}
		length := int64(usageSummaryChunk)
		if offset < length {
			length = offset
		}
		offset -= length
		chunk := make([]byte, length, length+int64(len(carry)))
		if _, err := file.ReadAt(chunk, offset); err != nil && !errors.Is(err, io.EOF) {
			return nil, time.Time{}, false, err
		}
		read += length
		chunk = append(chunk, carry...)
		lines := strings.Split(string(chunk), "\n")
		// The first piece may be the tail of a line that starts earlier.
		carry = []byte(lines[0])
		if offset == 0 {
			carry = nil
		}
		start := 1
		if offset == 0 {
			start = 0
		}
		for i := len(lines) - 1; i >= start && !done; i-- {
			consume([]byte(lines[i]))
		}
	}
	if len(carry) > 0 && !done && !truncated {
		consume(carry)
	}
	for i, j := 0, len(events)-1; i < j; i, j = i+1, j-1 {
		events[i], events[j] = events[j], events[i]
	}
	return events, newest, truncated, nil
}

func usagePrivateRegular(info os.FileInfo) bool {
	owner, ok := info.Sys().(*syscall.Stat_t)
	return info.Mode().IsRegular() && ok && int(owner.Uid) == os.Getuid() && info.Mode().Perm()&0o077 == 0
}

// BuildUsageSummary reads the journals beside workerStateDir. now bounds the
// open segment of a live pane; live reports whether a manifest's worker is
// still the same process on this node.
func BuildUsageSummary(workerStateDir, host, bootID string, since, until, now time.Time,
	live func(workerManifest) bool) (UsageSummary, error) {
	since, until, now = since.UTC(), until.UTC(), now.UTC()
	if !since.Before(until) || until.Sub(since) > UsageSummaryMaxWindow {
		return UsageSummary{}, errors.New("usage window must be positive and at most 14 days")
	}
	if until.After(now) {
		until = now
	}
	summary := UsageSummary{SchemaVersion: UsageSummarySchemaVersion, Host: host, GeneratedAt: now,
		Since: since, Until: until, Panes: []UsagePane{}}
	eventsDir := filepath.Join(filepath.Dir(workerStateDir), "events")
	entries, err := os.ReadDir(eventsDir)
	if errors.Is(err, os.ErrNotExist) {
		return summary, nil
	}
	if err != nil {
		return UsageSummary{}, err
	}
	server := &Server{stateDir: workerStateDir}
	for _, entry := range entries {
		match := usagePaneFile.FindStringSubmatch(entry.Name())
		if match == nil {
			continue
		}
		paneID := match[1]
		pane := UsagePane{PaneID: paneID, Segments: []UsageSegment{}, Asks: UsageAsks{WaitSeconds: []float64{}}}
		if manifest, err := loadManifest(server.manifestPath(paneID)); err == nil {
			if manifest.NodeBootID != bootID {
				summary.OtherBootPanes++
				continue
			}
			pane.NodeVerified = true
			pane.WorkingDirectory = manifest.WorkingDirectory
			pane.Live = live != nil && live(manifest)
		}
		path := filepath.Join(eventsDir, entry.Name())
		info, err := os.Lstat(path)
		if err != nil {
			continue
		}
		if !usagePrivateRegular(info) {
			summary.RejectedFiles++
			continue
		}
		if !pane.Live && info.ModTime().Before(since) {
			continue
		}
		file, err := os.Open(path)
		if err != nil {
			continue
		}
		opened, statErr := file.Stat()
		if statErr != nil || !os.SameFile(info, opened) {
			file.Close()
			summary.RejectedFiles++
			continue
		}
		events, newest, truncated, err := usageJournalTail(file, opened.Size(), since)
		file.Close()
		if err != nil || len(events) == 0 {
			continue
		}
		pane.Truncated = truncated
		if !newest.IsZero() {
			last := newest
			pane.LastEventAt = &last
		}
		usageBuildPane(&pane, events, since, until, newest)
		if len(pane.Segments) == 0 && !pane.Live {
			continue
		}
		summary.Panes = append(summary.Panes, pane)
	}
	sort.Slice(summary.Panes, func(i, j int) bool { return summary.Panes[i].PaneID < summary.Panes[j].PaneID })
	return summary, nil
}

// usageBuildPane turns ordered events into merged, clipped segments. A live
// pane's last state runs to until; otherwise it ends at the newest record.
func usageBuildPane(pane *UsagePane, events []usageEvent, since, until, newest time.Time) {
	type run struct {
		state, reason string
		start, end    time.Time
	}
	runs := make([]run, 0)
	for _, event := range events {
		pane.Agent = event.agent
		// One ask raises several events (PreToolUse, PermissionRequest,
		// Notification); they stay one ask with the reason first seen.
		if n := len(runs); n > 0 && runs[n-1].state == event.state &&
			(runs[n-1].reason == event.reason || event.state == usageNeedsYou) {
			continue
		}
		if n := len(runs); n > 0 {
			runs[n-1].end = event.at
		}
		runs = append(runs, run{state: event.state, reason: event.reason, start: event.at})
	}
	last := &runs[len(runs)-1]
	if pane.Live {
		last.end = until
		if last.state != usageEnded {
			pane.CurrentState, pane.CurrentReason = last.state, last.reason
		}
	} else {
		last.end = newest
		if last.end.Before(last.start) {
			last.end = last.start
		}
	}
	for i, r := range runs {
		if r.state == usageNeedsYou && !r.start.Before(since) && r.start.Before(until) {
			pane.Asks.Opened++
			switch {
			case i+1 < len(runs) && runs[i+1].state != usageEnded:
				pane.Asks.Answered++
				if len(pane.Asks.WaitSeconds) < usageSummaryMaxWaits {
					pane.Asks.WaitSeconds = append(pane.Asks.WaitSeconds, runs[i+1].start.Sub(r.start).Seconds())
				}
			case i+1 == len(runs) && pane.Live:
				pane.Asks.Open++
			default:
				pane.Asks.Unanswered++
			}
		}
		if r.state == usageEnded {
			continue
		}
		start, end := r.start, r.end
		if start.Before(since) {
			start = since
		}
		if end.After(until) {
			end = until
		}
		if !end.After(start) {
			continue
		}
		if len(pane.Segments) == usageSummaryMaxSegments {
			pane.Truncated = true
			continue
		}
		pane.Segments = append(pane.Segments, UsageSegment{State: r.state, Reason: r.reason, Start: start, End: end})
	}
}

// UsageSummaryHere builds the summary for this node from relayd's default
// worker state directory.
func UsageSummaryHere(since, until time.Time) (UsageSummary, error) {
	bootID, err := nodeBootID()
	if err != nil {
		return UsageSummary{}, err
	}
	host, _ := os.Hostname()
	live := func(manifest workerManifest) bool {
		if manifest.WorkerPID <= 1 || manifest.WorkerStartTime == 0 {
			return false
		}
		start, err := processStartTime(manifest.WorkerPID)
		return err == nil && start == manifest.WorkerStartTime
	}
	return BuildUsageSummary(defaultWorkerStateDir(), strings.ToLower(host), bootID, since, until, time.Now(), live)
}

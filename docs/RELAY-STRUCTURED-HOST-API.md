# Structured remote operations without terminal input

Live verified 2026-09-30: the installed CLI returns capabilities for dandy-07, including exec/status and file operations. No probe was executed for this check. The current MCP helper catalog is stale and omits these tools, so use the packaged CLI now; do not open a terminal tab as fallback.

## CLI

Executable: `/Applications/Relay.app/Contents/MacOS/relay-workspace`.

Use `--host dandy-07 --directory /absolute/remote/directory request` and supply one JSON object on stdin. This authenticates locally via the bundled relay-mcp, sends HTTP to Relay's native `/api/host/request`, and uses Relay's persistent SSH transport. It creates no tabs and sends no terminal input. You do not run SSH or SCP commands.

Requirements: Relay running on port 47471, dandy-07 configured with Relay backend, reachable node supporting host_rpc_v1, existing installation-scoped input grant for file operations and execution. `relay_control_info` reports the grant. A missing grant is not permission to bypass it.

Use the existing directory `/projects/caeg/scratch/kbd606/tmp/fqdup-common-suite-20260928/agree-trim-v1` for the requested probe only after the user authorizes structured execution. The prior prohibition on terminal/tab input remains in force. These instructions alone authorize no execution.

## Request shapes

The CLI adds request_id, host and cwd. Generate stable job_id once for every exec or file_write and preserve it across uncertain outcomes. JSON `data`, `stdin`, and returned stdout/stderr are base64 strings.

- Capabilities: `{"operation":"capabilities"}`
- Stat: `{"operation":"file_stat","path":"/absolute/file"}` → size/version.
- Write: `{"operation":"file_write","job_id":"write-UNIQUE","path":"/absolute/file","version":"VERSION_FROM_STAT_OR_missing","data":"BASE64_BYTES"}`. Parent directory must exist. The destination must match its prior version, or explicitly be missing. Maximum raw file bytes 4 MiB; CLI request JSON maximum 1 MiB, so use this path for small artifacts.
- Verify: `{"operation":"file_verify","path":"/absolute/file","version":"VERSION_FROM_STAT"}` → sha256. Compare against local SHA-256. Stat again after writes before verifying/reading.
- Exec: `{"operation":"exec","job_id":"job-UNIQUE","argv":["/opt/software/python/3.11.3/bin/python3.11","/absolute/probe.py"],"timeout_seconds":120}`. Explicit argv avoids shell interpolation. CLI supplies cwd.
- Status: `{"operation":"status","job_id":"job-UNIQUE","stdout_offset":0,"stderr_offset":0,"wait_millis":15000}`. Returned job.state and exit_code establish completion; decode bounded stdout/stderr and preserve returned offsets for subsequent reads. This is a Relay host job ID, distinct from a Slurm ID.
- Read artifact: stat first, then `{"operation":"file_read","path":"/absolute/result.json","version":"VERSION_FROM_STAT","offset":0,"length":65536}`. Decode data; verify returned range sha256 and next_offset. Repeat bounded ranges only if necessary. file_verify provides the whole-file hash.

Execution admission is not completion. On timeout/disconnect, inspect the original job_id; never launch again with another ID. unknown_after_daemon_restart means unresolved. Do not cancel or signal existing jobs/agents.

For convenience, `relay-workspace --host dandy-07 --directory /absolute/remote/directory exec /absolute/executable argument` generates and prints the job ID, then waits with bounded status requests. The explicit request form gives better control over durable IDs.

## MCP names (new helper catalog)

`relay_host_request({host:"dandy-07",request:{...}})` accepts these request fields, adding request identity at the native endpoint. `relay_exec({host,job_id,command,cwd?,env?,timeout_seconds?})`, `relay_exec_status({host,job_id,stdout_offset?,stderr_offset?})` are convenience tools. `relay_workspace_context({tab_id})` and `relay_workspace_request({tab_id,request})` use an existing captured binding; no tab is required with the explicit host API. Discover with relay_available_tools and relay_call_tool only if the live catalog exposes the name. The current catalog does not, so use the installed CLI. No Codex restart is required for that CLI.

Implementation references: scripts/relay-workspace.py, remote/relayd/internal/daemon/host_rpc.go, remote/relayd/internal/daemon/host_files.go, Sources/Relay/RelaySidePanel.swift.

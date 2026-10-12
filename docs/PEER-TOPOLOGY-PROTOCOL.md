# Provider topology reports, v1

Status: Relay reader and graph implementation. Existing Codex/Claude processes
do not yet produce this report. Absence means unknown, never an inferred edge.

An opted-in provider atomically writes a private, user-owned regular file at
`~/.claude/sessions/<pid>.topology.json`, adjacent to its registry record:

```json
{
  "version": 1,
  "pid": 123,
  "sessionId": "source-session",
  "procStart": "123456",
  "updatedMs": 1789941900000,
  "links": [{"pid": 456, "sessionId": "destination-session", "procStart": "654321"}]
}
```

The provider must renew only relationships it still considers available. A
historical send is not sufficient to renew a report. Do not populate this file
by parsing conversations. No payloads, credentials, socket paths or realm data
belong in reports. Mode 0600 and atomic replacement are recommended.

Relay requires both endpoints to resolve to current same-host registry entries
with exact PID, session and process start time, and neither may be a proxy.
Reports expire after 30 seconds and tolerate at most 5 seconds of future skew.
Limits: 16 KiB per file, 64 targets per report, 1024 exported links per scan.
These are same-user assertions, not cryptographic proof of delivery or grants
of authority. Cross-host assertions and child-agent reports are outside v1.

The helper exports redacted `links` alongside `peers`. Each row carries
`sourcePID`, `sourceSession`, `destinationPID`, `destinationSession`, `updatedMs`.
The querying SSH host scopes both endpoints. Swift rejects ambiguous resumed
session bindings, missing endpoints and expired observations before drawing.
The map uses dashed reported edges and an explicit evidence inspector; it does
not label these as Relay-tested connections. No scan sends model prompts.

Provider adoption is a separate deployment gate. Do not restart active agents
or manufacture production reports merely to make an edge appear in a demo.

## Claude team inventory

Discovery additionally exports a bounded `teams` array from Claude's existing
team configuration files. Only teams with one unambiguous live lead session
are included. Each record contains name, leadSessionId and whitelisted member
identity/type/model fields. Prompts, subscriptions and arbitrary fields are
never exported. A maximum of 256 directories, 16 teams and 16 members per team
is inspected/exported; exceeding a cap marks the result partial.

Members have **unknown activity**. They are not added as active graph nodes or
communication edges, and the inspector shows their details only with history
enabled. Parent liveness does not prove child liveness. Lifecycle hooks and
daemon roster validation are separate work; subagent transcripts are not read.

Live dandy check: 26 registered peers, 9 teams, 11 member metadata records,
zero provider link reports. Reader redaction/ambiguity tests and Swift bounds
tests pass. No Claude binary or running agent was changed by this integration.

Validation checkpoint (2026-09-21): the installed app displayed discovered
remote sessions and the connected desktop route. Full inspector acceptance is
not passed: during computer-control checks the app repeatedly disappeared.
A directly launched diagnostic run exited with code 0 and emitted an
NSTableView reentrant-delegate warning; no Relay crash report was found. This
does not establish the cause of termination. The app was reopened with its
existing panes preserved; no terminal input was sent. Do not treat this
checkpoint as proof of end-to-end UI stability or live child-agent discovery.

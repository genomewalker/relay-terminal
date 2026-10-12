# Relay plugin implementation plan

For authoring and publishing packages, start with the
[Plugin development guide](PLUGIN-DEVELOPMENT.md). This document records the
architecture, roadmap and historical verification evidence.

Current staged work and acceptance gaps: [current acceptance record](plugins/CURRENT-ACCEPTANCE.md).
The sections below retain historical evidence. In particular, HPC now has an
unpublished API-3/0.2.0 manifest for separately authorized mutations; the public
0.1.0 prerelease and installed app have not been replaced by this staging pass.

## Native-tool implementation update (2026-09-18)

Six data-only packages now select core-owned native operations via a `tool`
contribution under API version 2 (information/link packages still use API 1).
Manifests are in `docs/plugins/`; implementation is in
`PluginOperations.swift`, `PluginToolsView.swift`, and the `relayd plugin` helper.
This extends the original information/link API; it is not an arbitrary plugin-code
runtime. Older apps reject these manifests rather than pretending to run them.

- HPC jobs: on-demand `squeue --me`, no submission/cancellation.
- Artifacts: directory listing and bounded image/plain-text preview.
- Agent activity: selected-pane snapshot of existing agent/subagent events.
- Git review: tracked status plus staged/unstaged diffs; no external diff/textconv.
- Transfers: download one regular file (8 MiB maximum), verify SHA-256, Save copy.
- Project actions: recognize standard project manifests and suggest commands; never execute.

Enabling validates declared permissions against the operations. Each click in the
workspace tool sheet grants one operation for the captured pane/host/directory.
The store is rechecked before the operation and before showing its result. No
persistent blanket grants or background polling. Switching tabs cannot retarget
a request. Cancel terminates the local helper/SSH process; remote command helpers
also have eight-second command deadlines. The active session worker is not used
or restarted. An old helper returns an unsupported-command error.

At most two helper operations run concurrently per app, with no queued requests.
File reads use Go's directory-rooted handles to reject traversal and symlink
escapes, bounded regular-file reads, and change detection. Transfer content stays
in bounded memory and is atomically saved only through the native save dialog;
directory transfer/resume/progress/file promises are not implemented. Git/Slurm
output is bounded; displayed text is limited to 128 KiB. Commands operate as the
user, not in an OS sandbox; this is why package-supplied executables are prohibited.
Rooted file handles do not defend against a same-user privileged adversary or mounts.

Verification so far: an earlier full 202-test Swift run passed, including activation of all six package
fixtures and subprocess cancellation. All Go packages pass. A temporary helper on
dandy-07 successfully listed actual Slurm jobs and returned a test manifest with a
verified digest; local project detection and Git diff inspection also succeeded.
No existing remote workers/agents were restarted. The live Slurm result was large,
so a 128 KiB display bound was added. The remote rerun returned exactly 131072
bytes and explicitly marked the result truncated. Git subdirectory isolation and
FIFO rejection are covered by additional passing Go tests.

The subsequent 203-test run (after adding the concurrency-budget test) failed in
native terminal input tests; this is an unresolved acceptance failure, not a green
release gate. Investigate and rerun before publishing an installable release.
The isolated 17-test terminal suite also failed (29 issues), including from a clean
scratch build, so concurrent test suites/build caches alone do not explain it.
The final targeted plugin run passed all 12 tests. Keep the running app unchanged
until the terminal discrepancy and installed-app acceptance are resolved.

Evidence: `/tmp/relay-plugin-verification.i51lqp/` contains `plugin-tests.log`,
`swift-tests.log`, `terminal-isolated.log`, `terminal-clean-build.log`, and
`build.log`. All six GitHub repositories now have API-2 manifests on `main`;
no tagged plugin release has been published. The staging app is not the running
`/Applications/Relay.app`, and the temporary remote helper is not the active daemon.

**Not yet accepted:** installed-app interaction, final package download/install,
VoiceOver, remote failure/cancellation under load and performance measurements.
The earlier full roadmap below remains open; these are useful first versions,
not completion of every M3–M5 requirement. App and helper changes are in the working
copy, not yet a released compatible Relay version.

Status: experimental declarative GitHub installer and Settings UI implemented in
source; no programmable execution runtime yet. The full Swift suite passes 198
tests (2026-09-18), including a deterministic complete download-review fixture.
The live install flow is not accepted: see manual verification below.

### Verification on 2026-09-18

- Six plugin tests pass: manifest/source validation, allowed download hosts,
  install/update/rollback/safe mode, corrupt state preservation, and complete
  review with HTTP 404, tag/draft/duplicate asset/host/size/digest failures.
- UI tested from `/private/tmp/relay-plugin-build.hurjXv/Relay.app` (running path
  verified). Settings → Manage plugins opens; empty-state and invalid-source
  error render; Done closes the sheet.
- Resolved validation blocker: normalize surrounding whitespace in repository/tag
  inputs and report empty, oversized, embedded whitespace and invisible controls
  separately. The same manually entered test tag now reaches GitHub and returns
  the expected HTTP 404 for a nonexistent release instead of failing validation.
  Hidden characters inside tags remain rejected. Tests include boundary zero-width
  whitespace, line endings, embedded controls and a padded complete review request.
- Installed the tested build in `/Applications/Relay.app`, SHA-256
  `85a0264f6cd598c1f50965982a5ed7d10e3a4919a899a3b3ad8e0ab5852e70b8`.
  Previous app: `/tmp/relay-plugin-build.hurjXv/Relay.pre-plugin.app`.
  Signature verified. Full GitHub success/install still needs a controlled published
  fixture; an HTTP 404 check does not establish successful installation.
- No package was installed. Original `/Applications/Relay.app` was reopened,
  with remote sessions showing connected. Remote agents were not terminated.
- Latest full test log: `/tmp/relay-plugin-fix-full.log`; release build:
  `/tmp/relay-plugin-build.hurjXv/fix-build.log`.
This document is an acceptance plan, not a claim of production readiness.

## Architecture and invariants

Terminal input, rendering, selection, transport and recovery remain core-owned.
No plugin callback is awaited by those paths. Plugins never receive SSH private
keys or ambient environment secrets. Workspace files cannot grant permissions.

Data flows: GitHub release → bounded download → manifest validation → review of
exact digest/source/permissions → atomic local installation → explicit activation.
Activation eventually connects scoped broker operations to a separately sandboxed
host. Out-of-process execution alone is not a security boundary.

Version 1 starts with a single JSON package (`relay-plugin.json`), not an archive.
It supports plain-text information and explicit HTTPS links. There are no install
hooks, executable entrypoints, HTML, dependency downloads or repository scripts.
Capability-bearing packages can be inspected/stored but cannot activate until the
relevant scoped authorization broker exists. Hashes pin bytes; they do not prove
publisher identity or protect against a malicious publisher.

## Delivery milestones

- [x] M1: bounded manifest, repository identity and SHA-256 pinning; reject unsupported API/schema and executable top-level fields.
- [x] M1: serialized atomic install/update state, explicit activation, fail-closed loading, source collision rejection, one-version rollback and safe-mode suppression.
- [x] M1: cross-process nonblocking lock and fresh state reload per operation; nested-field validation and symlinked state rejection.
- [ ] M1 acceptance: tests pass and independent security review covers nested unknown fields, state corruption, file ownership/symlinks and concurrent app instances.
- [x] M2 implementation: bounded unauthenticated GitHub tagged-release download with constrained redirects, cancellation, timeouts, HTTP errors and optional GitHub asset digest verification. Private repositories and release browsing are not yet supported.
- [x] M2 implementation: Settings → Plugins with exact-tag review, install-disabled, enable/disable, manual update via another release, rollback, confirmed uninstall and plain-text/link contributions.
- [ ] M2 acceptance: deterministic HTTP failure/redirect/cancellation tests and installed-build keyboard/VoiceOver/manual lifecycle checks against a controlled GitHub fixture release.
- [ ] M2: integrity/provenance UI distinguishes pinned content, authenticated publisher and unverified source; define signing/key-rotation policy before claiming publisher verification.
- [ ] M3: grant records scoped to plugin digest, workspace/project and host; broker checks every operation, canonicalizes paths, prevents symlink escapes and revokes in-flight requests.
- [ ] M3: sandboxed runtime choice and threat-model review; prohibit raw processes and network until enforcement exists. Bound memory, messages, requests, queues and execution time; quarantine crash loops.
- [ ] M3: durable event cursors, explicit overflow/resync, cancellation and capability negotiation with actual live remote workers.
- [ ] M4: first-party HPC jobs integration: read-only Slurm listing/status/logs first, explicit separate grants for submit/cancel, on-demand refresh and idle backoff.
- [ ] M4: artifacts: bounded image/Markdown/table preview, no remote HTML execution, explicit fetch and original host/project attribution.
- [ ] M4: agent activity: structured metadata/content distinction, approvals remain provider-owned, subagents and peer messages routed by stable identities.
- [ ] M4: Git review: bounded status/diff, worktree awareness, host-scoped handoff; no implicit staging/commit or agent submission.
- [ ] M4: transfers: cancellable bounded streaming, destination/collision review, incomplete-file cleanup and checksum verification.
- [ ] M4: project actions: explicit user-approved argv/environment/cwd, never implicit execution of instructions in README or repository configuration.
- [ ] M5: CPU/memory/queue diagnostics per plugin, hidden-window behavior, fault injection and recovery verification.
- [ ] M5: package migration/rollback compatibility, multi-instance locking, clean install/upgrade/uninstall and release documentation.

## Storage and updates

Store one atomically replaced installation index containing bounded JSON packages
and previous revisions. No arbitrary archive paths are extracted. Updates remain
disabled until reviewed and activated. Republished content under an installed
version is rejected. A source cannot take over another source's plugin ID.
Uninstallation of code does not authorize deleting user project data.

Store operations acquire a nonblocking cross-process lock and reload current
state before changing it. Contention asks the caller to retry. Before programmable plugins,
split mutable plugin data from package revisions and design reversible migrations.

## Release gates

Test malicious manifests/URLs, oversized downloads, stale review digests, corrupt
state, repository collisions, permission escalation, cancelled operations, missing
helpers, offline SSH, old workers, floods and helper crashes. Verify no changes to
terminal latency or hidden-pane restoration under a repeatable mixed-agent load.
Run installed-app manual checks, not just unit tests. Existing terminal/editor
regressions block release independently of plugin milestones.

Revisit archive packaging, executable languages, a curated catalog and third-party
signing only after first-party extensions demonstrate that the narrow API suffices.

## Authoring a declarative package

Start with `docs/examples/relay-plugin.json`, replace the repository with your own
`owner/repository`, and publish the JSON as a release asset named exactly
`relay-plugin.json`. Enter that repository and exact release tag in Settings →
Plugins → Review release. Inspect the source, digest and permissions before choosing
Install disabled, then Enable. To update, review another tag from the same repository
with a new package version. Link contributions open only when clicked. This is not
VS Code extension compatibility, an agent adapter, or a remote command runtime.

## Persistent download recovery (deployed)

The Transfers tool keeps an explicitly authorized download in a private disk
spool keyed by its reviewed plugin digest, pane, host profile, project root and
relative file path. Closing the tool or Relay leaves its committed prefix on
disk. Reopening the same reviewed target and choosing **Allow download / resume**
rechecks authorization and the remote file identity before continuing. Recovery
does not start a transfer automatically.

Each chunk is checksum-verified, flushed, then recorded with the durable offset
and prefix SHA-256 in an atomic checkpoint. Recovery rebuilds the hash in bounded
chunks, rejects changed local bytes, and truncates any tail that never reached a
committed checkpoint. The final remote SHA-256 is required before Save becomes
available. A per-spool exclusive lock rejects concurrent downloads. Symlinks,
shared permissions and malformed checkpoints fail closed. **Discard partial
copy** removes local progress, including corrupted checkpoints; it does not
modify the remote file. This work does not yet cover persistent uploads or
folder transfers. A separate-process proof using the actual Swift downloader source and installed
Relay helper passed: the second process resumed at 4 MiB, verified the complete
file and discarded its checkpoint. Native GUI acceptance remains pending.

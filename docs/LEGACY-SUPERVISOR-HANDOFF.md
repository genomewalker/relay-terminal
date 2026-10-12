# Legacy supervisor transition

Source investigation, 2026-10-02. No production remote supervisor has been
stopped or replaced by this implementation. Modern supervisors use the existing
atomic host-job admission barrier. Legacy busy or unresolved jobs must defer an
upgrade.

## Proven kernel guard

`work/legacy-supervisor-guard.py` runs as a separate, single-thread guardian.
It seizes and interrupts every supervisor thread and requires a complete set of
verified kernel stop events. It reads no memory or registers. Controller EOF,
abort, crash, error, and a 20-second guardian lease release the stops through
kernel tracer teardown. No `EXITKILL` option is enabled.

Retirement requires private bounded job records and a child census. Unknown
reservations, live launchers, live job process groups, and untracked children
reject retirement. A dead launcher does not establish that its job has ended:
a grandchild can still hold the daemon's output pipe. Only exact durable worker
identities and manifest/argv bindings are allowed as surviving child processes.

Every target thread remains traced and stopped until the guardian sends the
fatal signal. The guardian has not reaped or detached the leader, so its PID
cannot be allocated to a replacement process. It verifies tracer ownership
immediately before that operation and acknowledges exit events for the complete
thread group. There is no separate controller kill after lease expiry.

The remote kernel lacks pidfd support. Its ptrace resume operation also ignores
signal delivery from the interrupt stop. Both cases were found in disposable
process tests; retirement now preserves the stop throughout the fatal operation.

## Actual legacy acceptance

A private copy of the exact running legacy executable was tested, identified by
SHA-256 `270c386131163c3bffbaa0edc22cfdea54914c2142bd7daf492d1eb1d1857f9d`.
It did not advertise the modern upgrade-prepared capability. The fixture proved:

- A real stdin job rejects handoff and continues running.
- A dead launcher with a live process group also rejects handoff.
- Aborting the guard preserves worker, shell, and shell environment state.
- Requests sent after the stop cannot start a new job.
- Unknown journal outcomes survive replacement without execution replay.
- The current helper adopts the exact original worker and shell after retirement,
  preserving their kernel start identities and shell environment.

The before/after production inventory retained all pane, worker, shell, provider,
catalog revision, and supervisor identities. Only disposable processes received
signals. This proves the guard and private handoff, not production deployment.

## Required deployment coordinator

Before production use, implement a durable coordinator that:

1. Binds the socket's kernel peer UID/PID, node boot and start identity, daemon
   argv/socket, executable hash, and actual legacy worker/job state root.
2. Stages and hashes the current helper; flushes a verified old-image backup and
   an upgrade journal before changing any executable path.
3. Serializes owned upgrade attempts and preserves the existing logical helper
   link. Replace the stable physical executable path atomically so stale CLI
   processes cannot relaunch an immutable old release path after the handoff.
4. Acquires the kernel guard, validates the exact target and idle result, records
   the image activation, and retires only through the guardian.
5. Starts or identifies the replacement under the existing supervisor lock,
   checks its executable hash and protocol capabilities, and proves original
   workers, shells, providers, job receipts, and pane identities remain intact.
6. Recovers each journal phase explicitly. Controller loss after retirement is
   an unknown outcome until socket and process identities are inspected. Never
   kill an unexpected replacement or replay execution to make recovery pass.
7. Exercises image-copy, activation, guard expiry, retirement-acknowledgement,
   startup, and rollback failures using private fixtures before rollout.

Kernel semantics were reviewed against the [Linux ptrace implementation](https://raw.githubusercontent.com/torvalds/linux/v4.12/kernel/ptrace.c),
the [ptrace manual](https://man7.org/linux/man-pages/man2/ptrace.2.html), and
[Linux Yama documentation](https://docs.kernel.org/admin-guide/LSM/Yama.html).

## Source startup coordinator evidence (2026-10-02)

`work/legacy-upgrade-transaction.py` now journals a startup nonce before spawning,
records the launched kernel incarnation, and binds readiness to SO_PEERCRED,
boot/start identity, executable hash, argv, state root and routing environment.
Reopening an uncertain attempt identifies that exact peer; an absent peer stays
pending and does not trigger another launch. Image mutation is blocked by an
unresolved startup or a live socket peer. A known exited attempt may be marked
failed only after its launched PID is absent, its socket has no listener, and
no process born at or after the launcher contains the attempt nonce. Older
processes cannot be descendants and do not require environment inspection.

The private Linux fixture passed ten checks in
`/private/tmp/relay-legacy-startup-failure-final.log`, including confirmed failed
startup and baseline-image rollback, interrupted readiness receipt recovery,
actual legacy worker/shell preservation and unknown-job non-replay. All six
production inventory fields were identical. This was receipt interruption in
one controller process, not proof of a separate controller crash.

The stronger separate-controller crash fixture initially exposed remote Python
3.6's missing pidfd APIs in cleanup. The single leftover private daemon was
identified by exact argv, executable SHA and startup nonce, then retired using
the kernel guardian; its fixture was removed. Cleanup now uses that guardian.
The latest run stopped earlier during a rollback absence recheck: a newly born,
same-owner process had an unreadable `/proc/.../environ`. This is deliberately
unresolved, not silently skipped; the separate-controller crash result is still
unproven. The latest run again preserved all production inventory fields.

Remaining gates include durable guardian retirement coordination, recovery of
unknown creation/spawn gaps, a bounded failed-start recovery path that can
handle unrelated protected processes with evidence, baseline daemon restart,
separate-controller crash acceptance and integrated production preservation
verification. These source modules are not a deployed remote upgrade runner.

## Complete source coordinator continuation (2026-10-02)

The stronger fixture now exercises actual separate-controller exit at the
readiness receipt boundary, followed by fresh-controller recovery of the same
nonce-bound kernel peer without launching again. An explicit unreaped zombie
fixture proves exited tasks can be excluded from the nonce scan; unreadable
live tasks still block failure reconciliation. State-root inode identity is
bound and rechecked, including after replacement startup.

`UpgradeRetirement` persists the guardian content hash and process incarnation,
checks every frozen thread, executable hash, argv and state-root identity, then
journals retirement intent before sending the guardian command. Lost terminal
acknowledgements recover from the exact old process's absence or irreversible
zombie state without sending another signal. A busy retirement is journalled
as aborted. Controller EOF and the existing guardian lease retain release
ownership. Unknown guardian outcomes remain explicit.

`UpgradeImages.stage()` flushes the private same-parent candidate before the
freeze. Public activation requires the acknowledged guardian's exact frozen
threads or proved old-process exit. Public activation takes place inside the
admission barrier, before retirement, closing the stale-CLI relaunch window.
`LegacyUpgradeCoordinator` sequences preparation, staging, guarded activation,
retirement, nonce-bound startup and explicit recovery. Confirmed startup failure
can restore and start the known working **running-old** image with a separate
rollback nonce journal. The separately saved installed-old image remains intact:
it may have been a deferred update rather than the working legacy image.

The private verifier covers complete coordinator startup and reopen, busy
rejection, lost retirement and rename receipts, actual controller exit, original
worker/shell identity and shell-state preservation, job non-replay, and baseline
restart. Exact current outcomes are in
`/private/tmp/relay-legacy-coordinator-deferred-rollback.log` and the preservation
JSON. None of these source coordinators has been invoked against production.
The production target read confirms the stable daemon binary is
`~/.local/share/relay/bin/relayd-linux-amd64`; `~/.local/bin/relayd` is a separate
launcher file and must remain intact. The daemon binary's canonical physical
parent is owned and mode 0755. Unknown artifact/spawn gaps stop without adoption
or execution replay. Integrated deployment and independent inventory/capability
verification remain required before declaring remote delivery complete.


## Production rollout (2026-10-02)

The protected attempt `cb230021e91e45ca8e95a71166ae74b0` staged the verified Linux helper, bound and retired the actual idle legacy daemon through the guardian, and started the replacement at the stable physical daemon path. The launcher wrapper was preserved. Startup now restores the original full environment from a private mode 0600 backup and preserves the original working-directory inode; credential contents are not logs or wire payloads.

Initial verification found one memory-only dormant catalog entry that had neither a live worker/shell nor a stored manifest/catalog entry. Guarded catalog reconciliation restored its observed identifier, prior PIDs and creation time as a nonrecoverable missing entry, with no command, worker or shell launch. The exact before-file and repair receipts are retained under the attempt. All 85 observed pane receipts, 83 live worker identities, 77 live shells, 43 providers and 604 original job-directory artifact inventories were retained; five newer job directories appeared separately. Future rollouts should retain the full safe catalog snapshot, including memory-only historical metadata, before retirement.

Final recovery/capability verification status: `{"counts": {"panes": 85, "providers": 43, "shells": 77, "workers": 83}, "folderProtocol": 1, "jobs": 609, "localPreservation": {"auditPrefix": true, "callersRegistry": true, "drafts": true, "panes": true, "workers": true}, "remotePhase": "deployed", "remotePreservation": {"jobs": true, "launcher": true, "panes": true, "providers": true, "shells": true, "stateRoot": true, "supervisor": true, "workerRecords": true, "workers": true}, "supervisorPID": 4169159}`. Authoritative logs are `/private/tmp/relay-remote-upgrade-independent-recovery.log` and `/private/tmp/relay-remote-catalog-reconciliation-run.log`. Transfer UI and actual remote folder/file end-to-end acceptance remain separate requirements.

## Full catalog retention foundation — 2026-10-02

Upgrade inventories now privately retain the complete safe `sessions` snapshot,
including titles, workspace/tab/parent links, commands, directories and creation
timestamps. The preservation check compares these fields for every original
pane in addition to process incarnations and job hashes. Ordinary process
snapshots remain compact. Deployed remote transfer acceptance passed this
stronger metadata check (`/private/tmp/relay-remote-full-catalog-retention.log`).

New source `PreserveCatalogSnapshot` merges only absent same-node pane receipts,
without creating workers or adopting historical PIDs. Existing catalog entries
remain authoritative. Running state in an imported receipt becomes `missing`
and recoverability is false until a real worker manifest independently proves
it. Schema, node, pane IDs, duplicate entries, timestamps, metadata and aggregate
bounds are checked before publication. Atomic catalog storage provides durable
publication and repeat imports do not change the revision.

The source `relayd preserve-catalog --snapshot PRIVATE_FILE` command is offline:
it requires the profile's default supervisor socket and holds the daemon's socket
lock through the merge. It refuses a held supervisor lock, wrong profile socket,
symlink snapshot and nonprivate or multiply linked snapshot. It never launches
or signals a process. Focused Darwin daemon and CLI checks passed, including
original dormant metadata, idempotence and lock contention.

This foundation is not integrated into the upgrade coordinator or deployed.
The coordinator must durably bind the full snapshot to the original peer,
retain the snapshot and import receipt through controller failures, run the
candidate's offline import after proven retirement and before startup, and
verify every original pane's metadata after adoption. Workspace state bodies
are retained in the private snapshot but this pane merge does not import them;
existing durable workspace records remain authoritative. Linux filesystem and
actual private legacy-handoff acceptance remain required before rollout.

## Coordinator integration and private Linux acceptance — 2026-10-02

The source coordinator now captures a full safe snapshot using the bound old
image and original private daemon environment. Candidate capability checking
precedes retirement. A pinned private snapshot and immutable hash/identity
receipt survive reopening. After guardian-proven retirement and image activation,
the candidate performs the offline import before startup. An uncertain import
receipt permits verification under the same daemon/import lock; it does not
repeat a mutation. Startup follows a verified `imported` receipt.

A private Linux fixture using the retained exact legacy ELF passed 17 checks.
It captured a dormant pane's full metadata, removed the fixture's catalog entry
and worker manifest, imported the saved receipt, lost the import acknowledgment,
and reopened through verification only. The catalog bytes and mtime remained
unchanged during recovery, no worker was created, and the new daemon exposed the
original workspace/tab/parent/title/command/directory/creation metadata. Existing
busy-job, live descendant, abort, activation, rollback, environment, controller
exit and unknown-job no-replay checks also passed. Original production catalog
and process identities remained unchanged. Evidence:
`/private/tmp/relay-catalog-coordinator-private.log`.

Fresh candidate `76492e39000e45910058c27c9018729217a0741351a39c0bcc6e8d060bb43a86`
is staged in attempt `56574cd2e4c94018a99d153d3c660a3d`, not deployed. Its current
84-pane baseline passed all ten preservation fields. This revealed that the
previously restored dormant pane `302eaa7c-80e4-460d-98e4-b9604a1bced3` is absent
again from the current stored catalog. The original 85-pane baseline therefore
still requires reconciliation. The earlier published catalog can be reconstructed
byte-for-byte from its retained backup and receipt (SHA256
`a081f0ccc40ab79932aa24a08eaf6954e201b67ce7eb1c70b355f9d42177659d`). Its known dormant
receipt contains historical PIDs and creation time; historical title metadata
was unavailable. No replacement worker should be launched for that receipt.
Restore it through the new offline import before asserting full preservation;
do not repeat an external catalog write while a running daemon may have an
in-flight writer. The cause of its later disappearance is not yet established.

## Retention fix deployed — 2026-10-02

The immediate post-import loss was startup `CollectGarbage(30 days, false)`:
the historical missing receipt was older than 30 days. Preserved snapshot panes
now carry `retained: true`, including existing entries whose other metadata stays
unchanged. Automatic GC skips them; explicit Forget remains available. A private
legacy fixture with 45-day-old receipts passed all 19 checks through real startup,
including import acknowledgment loss, unchanged historical timestamps, preservation
and no replacement worker creation. The provider check preserves every original
kernel incarnation while reporting unrelated additions separately.

Helper 0.5.3 is deployed in attempt `a506b2c72a074b01a42d82cacb005ce1`:
SHA256 `543d8375a271faf83a03a6af3df673e35826d4500d6820e30faabbd6e0f022e8`,
supervisor PID 350035, start ticks 915345720. The newer version also prevents
the installed 0.5.2 native installer from treating a differing payload hash as
an automatic downgrade candidate. All ten current preservation checks and the
historical receipt check passed: 85 panes, 83 workers, 77 shells, 43 providers,
623 original-to-this-attempt job directories. Local panes/workers/drafts/caller
registry/audit prefix were retained. The running helper advertises folder protocol 1.

Independent comparison with the original 85-pane baseline passed original pane
identities, worker/shell/provider incarnations, original job artifact hashes,
worker record PIDs and state root. The launcher hash differs from that older
baseline; it is unchanged by this rollout and exactly matches the installed
native installer's canonical launcher template. This is not evidence of a
byte-identical launcher throughout all earlier phases. Historical title metadata
for the dormant receipt remains unavailable and was not invented.

Actual deployed file/folder transfer, reconnect checkpoint recovery, verified
download, collision preservation, empty directories, zero-byte files and repeated
receipt/cancel checks passed again on 0.5.3. Evidence:
`/private/tmp/relay-catalog-retained-v053-{private,stage,deploy}.log`,
`/private/tmp/relay-catalog-retained-independent.json` (historical launcher hash
comparison is explicitly false), and `/private/tmp/relay-retained-deployed-transfers.log`.

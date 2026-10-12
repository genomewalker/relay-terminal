# Sequential plugin acceptance

## Current override: unattended component work

The user requested work on all other plugins while the Mac is locked, with
manual validation tomorrow. Component implementation/testing may proceed in
sequence without claiming installed-app acceptance. Current changes, limitations
and the next-day checklist are in [NIGHTLY-VALIDATION.md](NIGHTLY-VALIDATION.md).
The historical HPC record below describes earlier builds, not the staged app.

Work on one plugin at a time. Do not advance on a build-only result.
Each plugin requires: focused behavior/failure tests, isolated package lifecycle,
real host/helper checks where relevant, native UI interaction, and a recorded
list of remaining gaps. Whole-app regression and installed-app acceptance remain
separate release gates; a component pass does not waive them.

Order: HPC jobs → artifacts → agent activity → Git review → transfers → project actions.

## 1. HPC jobs — implementation and component verification

### Full HPC acceptance scope (not just the 0.1.0 job list)

User requested completion of the planned features before moving to artifacts.
The broader M4 milestone in `docs/PLUGIN-SYSTEM.md` remains authoritative:

- [x] On-demand owned-job listing and status, local filters and bounded output.
- [ ] Selected-job details with explicit disappeared/finished-job handling.
- [ ] Read-only stdout/stderr previews with bounded tail reads, explicit refresh,
  originating host/job attribution, and no arbitrary path supplied by a manifest.
- [ ] Separate submit permission and per-action review of host, working directory,
  script and resource request. Never retry submission automatically after an
  ambiguous transport failure; reconcile before offering a retry.
- [ ] Separate cancel permission and per-action confirmation of exact owned job
  IDs. Never cancel jobs merely to test the UI or select all jobs by default.
- [ ] Verify timeouts, cancellation, stale snapshots, missing scheduler tools,
  permission revocation and missing/unreadable/large logs with fixtures.
- [ ] Verify package review/install/enable/disable in the installed release app,
  then refresh, search, selection, scrolling and keyboard navigation on dandy-07.
- [ ] Record resource/latency measurements and absence of idle polling; if an
  optional refresh mode is added, pause it while hidden and back off on errors.

Submission and cancellation must not inherit the read-only `remoteOperation`
grant of the existing 0.1.0 package. They need a new reviewed package version and
explicit operation-specific authorization. Existing remote jobs are not test
fixtures. CPU/GPU history charts are not part of this milestone.

Current manual-test blocker: computer control reports that the Mac is locked;
the user must unlock it. Do not bypass this or mark installed-UI acceptance done.

- Structured job identity, name, partition, state, elapsed time, nodes and reason.
- Up to 500 jobs displayed; full observed queue count and explicit partial status.
- Local search/state filters never contact the scheduler. Controls remain fixed
  while the lazy-rendered job list scrolls. Refresh is user initiated.
- Missing Slurm, scheduler failure, malformed/duplicate rows and old helpers fail
  explicitly, rather than masquerading as an empty queue.
- Helper command: fixed `squeue --me` arguments; no submit/cancel operations.

Evidence (2026-09-18):

- Focused Go HPC/plugin tests and the final whole Go suite passed, including
  stderr isolation and an actual bounded scheduler-timeout test.
- 14 targeted Swift tests passed, including HPC response/filter cases and
  install/enable/disable of the package in an isolated store.
- Temporary helper on dandy-07: 1528 jobs observed, 500 loaded, partial=true;
  no active helper/agent was replaced or restarted.
- Actual `PluginHPCJobsView` compiled into a standalone native preview, using only
  synthetic data. Verified by computer control: search 3→2 rows; combined state
  and search → zero; clearing search retains state → one row; empty queue;
  500-row partial list; scroll-to-bottom then search for job 1699 → one row.
- Screenshots verified visible rows and anchored search/state controls. The first
  preview let controls scroll away; this was corrected and manually retested.
- Coordinate-wheel input was unavailable (`noWindowsAvailable`); accessibility
  scroll-to-bottom succeeded. Trackpad/wheel acceptance is not claimed.
- Preview source: `scripts/hpc-plugin-preview.swift`; no Relay workspace or user
  plugin installation was modified. Temporary preview bundle and helper are in
  `/tmp/relay-hpc-acceptance.zXzRRo`; Swift log: `/tmp/relay-hpc-tests.log`.

Follow-up verification (2026-09-18):

- Re-ran all 17 terminal prompt/input tests against the current working tree and
  its local Ghostty dependency: passed. No terminal code was changed during this
  verification; the earlier failures are not attributed to a proven fix.
- Full Swift suite: 205 tests passed (`/tmp/relay-acceptance-full.log`).
- Full Go suite passed again (`/tmp/relay-hpc-final-go.log`).
- Built and signature-verified the release app, installed it in
  `/Applications/Relay.app`, and relaunched it (PID 76839 at verification).
  Installed executable SHA-256:
  `6bd73153952fac96ca86e0f6faffd064cf94bab1be87d355f9a3458f63992bd0`.
- Added `scripts/install-relayd.sh HOST --no-restart` for helper-only deployment.
  Installed on dandy-07 without requesting a supervisor restart; the installed
  helper returned 1522 total jobs, 500 loaded, partial=true.
- Published `genomewalker/relay-plugin-hpc-jobs` tag `v0.1.0` as an explicitly
  experimental prerelease. No stable plugin release is claimed.
- Installed-app GitHub review rejected the visible tag `v0.1.0` with "Invalid
  release tag". Reproduced in optimized mocked and live download tests while
  the live debug test passed. Replacing the bound `CharacterSet.contains`
  method reference in candidate validation with an explicit closure made all
  four optimized review/tag/lifecycle tests pass. Added an optimized CI plugin
  test step and direct valid/control-character tag regression coverage.
  An opt-in live download test (`RELAY_TEST_LIVE_PLUGIN=1`) now exercises the
  real published manifest without installing anything.
- Removed an unnecessary working-directory prerequisite for connection-wide HPC
  queries. Restored panes without a directory can list jobs; file tools still
  fail closed. The scope remains captured at panel opening.
- Final optimized plugin/HPC suite, including the live prerelease review and
  unknown-directory permission boundary: 16 tests passed
  (`/tmp/relay-hpc-final-release-tests.log`).
- Corrected release installed and relaunched from `/Applications/Relay.app`,
  PID 80785 at verification; executable SHA-256
  `d11c467f91be05aa1fca5858aa0c887f0dc2fddf9944ee67984fdd9ffe06e9e0`.
  Signature verification passed. The earlier installation hash above is superseded.
- UI automation reached Review release in the corrected build, then lost its
  native connection (`Sky Computer Use native pipe closed before response`).
  A retry and runtime reset did not recover it. Relay's process remained alive.
  Installation/enabling and real scrolling are NOT verified, and the package
  was not deliberately installed through a filesystem workaround.

Still required before full acceptance: fix/verify installed-app package review,
run HPC through its installed UI, and real trackpad/wheel checks. The earlier regression failure did not reproduce
in this run, but manual terminal acceptance is still necessary. Other plugins
have not advanced.

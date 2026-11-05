# Plugin staging and next-day validation

## September 19 unlocked manual pass

- Installed Relay's plugin toolbar opened and dismissed correctly. Its normal
  plugin store has no enabled packages; no installation/settings were changed.
- Built an isolated window from the actual PluginToolsView, operation runner,
  package manager, artifact/HPC preview code and freshly built local helper.
  Workspace/agent data were stubs, with only four file-oriented packages in a
  temporary store; this is not full-app, remote, agent or scheduler acceptance.
- Clicked Artifacts → refresh → nested folder → README; source toggle worked.
  Found Markdown blocks were concatenated by SwiftUI Text. Restored block
  separators, added a regression assertion, rebuilt and visually verified the fix.
- Git review: listed tracked files, filtered to table.csv and clicked to load its
  staged diff. Transfers: previewed CSV, saved through NSSavePanel into the test
  directory, and verified source/copy SHA-256 equality. Project actions correctly
  identified pnpm and presented suggestions only. An existing outside file was
  rejected with “path leaves the approved directory”.
- Optimized Swift plugin tests after the fix: 24 passed, one optional network test
  skipped. Test harness: `/tmp/relay-tools-qa.CDMiIi`; it was quit after testing.
- Computer control intermittently timed out on launch/relaunch; Finder activation
  and reconnecting the control runtime recovered it. A one-second sample showed
  the test app idle in its event loop (24.2 MiB physical footprint), not hung.
- Nothing pushed, installed into /Applications, or deployed remotely. Real Relay
  remained running with its existing sessions. Broader acceptance remains below.

## September 19 follow-up: navigation and previews

Additional working-copy changes (not installed or released):

- Artifacts and Transfers browse subfolders on demand, with folder-up and
  back-to-folder navigation, local filtering, and one-read-per-click consent.
  No recursive scan or background polling. Root confinement, trailing-slash
  escape tests, bounded listings and the existing 8 MiB download limit remain.
- Artifacts formats Markdown as native attributed text, with a source toggle.
  Links are inert and no web renderer or remote image loading is involved.
- Git review lists changed tracked files first and fetches patches per selected
  file. It handles literal pathspec-like names and deleted files. Rename detection
  is disabled intentionally: cross-scope renames must not reveal outside files.
- Full Go race suite passed; optimized Swift plugin suite passed (24 executed,
  one optional live-GitHub test skipped). Eight fresh local executable smoke
  checks passed using `/tmp/relay-plugin-navigation.dq6mul/relayd` and its disposable
  fixture. The same Swift suite passed again after the final back-to-folder
  navigation change; `go vet ./...` also passed.
- Manual UI attempt returned `cgWindowNotFound`; not manually accepted.

Still outstanding: large/resumable transfers and Finder promises, project action
execution with a separately reviewed permission, missing agent-provider/peer event
adapters, Git editor/agent handoff, real HPC action acceptance, installation and
release. The earlier sections below describe the baseline before this follow-up.

Updated 2026-09-19 (overnight pass).

This is a working-copy verification record, not a release announcement. The user
authorized implementation of all remaining plugins while the Mac is locked;
manual acceptance of HPC no longer blocks non-interactive work on the others.
No running app, active helper, remote agent, or real scheduler job is replaced by
this pass. Do not publish these changes as accepted releases yet.

## Implemented in the working copy

- HPC: owned-job details; bounded stdout/stderr tails; separately authorized
  submit/cancel review and durable action IDs; Slurm 20.11.9 legacy details
  fallback. See [HPC notes](hpc-jobs/README.md). Real mutations are not tested.
- Artifacts: bounded CSV/TSV tables (100 rows, 32 columns), quoted-field parsing,
  UTF-8 boundary handling, inert Markdown/HTML source, downsampled image previews.
  Malformed/wide tables fall back to text. Files remain limited to 8 MiB.
- Agent activity: timestamped, searchable, collapsible snapshots; needs-input
  priority followed by recent activity; stable IDs distinguish duplicate names.
  Up to 100 agents, 20 retained updates per row and 30 recent pane events.
  Only previously captured events appear; this does not add a provider adapter.
- Git review: explicit worktree/Git-directory attribution, approved-directory
  scope, ambient Git-environment isolation, external diff/textconv disabled,
  submodules skipped. Tracked changes only; no staging, commit, or agent handoff.
- Transfers: empty files retain a verifiable payload; wrong-path, missing,
  oversized and unsolicited payloads are rejected. Save rechecks authorization
  and pane ownership after the destination dialog. Save is atomic and uses native
  collision confirmation. Bounded whole-file download, not resumable streaming.
- Project actions: Swift/Go/Rust/Python/CMake/Make detection, npm/pnpm/Yarn/Bun
  lockfile attribution and explicit conflicts. No lockfile means no guessed
  package manager. Escaping manifest symlinks are ignored. Make dry-run is no
  longer suggested as if it were safe.

## Tomorrow's manual checks

1. Record the staged app hash, installed app hash, helper versions and live worker
   versions. Install/relaunch only after coordinating with the user; a rebuilt
   helper on disk does not update existing workers.
2. Review/install/enable each package through Settings, one at a time. Verify
   source/digest/permissions, disable/revoke, safe mode and rollback. HPC's new
   permissions require explicit review; never overwrite its published 0.1.0 asset.
3. Artifacts: preview image, Markdown, quoted CSV, empty and binary fixtures;
   long cells/narrow pane/large font; keyboard and VoiceOver navigation. Confirm
   remote HTML/images never trigger a network load.
4. Agent activity: duplicate names, 150 synthetic agents, needs-input priority,
   expand/collapse, filtering and explicit refresh. Switch tabs while open and
   ensure original host/pane attribution stays fixed. Missing peer events must
   not be presented as a complete communication history.
5. Git: staged/unstaged/deleted/renamed tracked files and a linked worktree;
   inspect scope and partial-result warning; no modified index or invoked hook.
6. Transfers: empty/Unicode/8 MiB files, cancel, overwrite dialog, full disk,
   source change and permission revocation while Save is open. Compare hashes
   for stable fixtures. Remote originals must remain untouched.
7. Project actions: inspect detected project/lockfiles; suggestions must not run
   when opening or refreshing. Check unusual filenames and missing manifests.
8. Recheck terminal input, Claude/Codex scrolling, split/maximize/restore and
   reconnect. These remain independent release blockers.

## Component evidence

- Artifact parser/preview: 2 optimized Swift tests passed, including quoted
  multiline CSV, escaped quotes, malformed/wide data, row bounds, inert HTML,
  binary input and a UTF-8 scalar split at the byte limit.
- Agent snapshot: optimized test passed for 150 agents, needs-input priority,
  duplicate names with stable IDs, search and immutable snapshot behavior.
- Git: race-enabled scope test passed with hostile ambient GIT_DIR,
  GIT_WORK_TREE and injected configuration; outside-file content stayed out.
- Transfers: optimized envelope/integrity test passed for empty, wrong-path,
  unsolicited, missing and oversized-list responses. Go empty-file JSON test
  passed for both artifact and transfer operations.
- Project detection: race-enabled tests passed for seven manifest/lockfile
  scenarios plus the empty-directory case and escaping symlink rejection.
- Combined optimized Swift plugin/HPC tests: **21 passed**.
  `/tmp/relay-remaining-all-swift.log`.
- Full Go race suite and `go vet ./...`: passed.
  `/tmp/relay-remaining-all-go.log`, `/tmp/relay-remaining-vet.log`.
- Actual packaged helper: seven smoke checks passed on the Mac and dandy-07,
  using disposable projects only. The repeatable harness is
  `scripts/test-plugin-helper.sh`: listing, CSV integrity, empty-file integrity,
  pnpm detection, Git attribution, parent traversal and absolute-path rejection.
  No real jobs, user files or active agents were modified.
- Release app built and `/usr/bin/codesign --verify --deep --strict` passed.
  Staged app: `/tmp/relay-hpc-extended.tYTwCb/Relay-plugins.app`.
  Executable SHA-256:
  `b96504b2d5ed77ac65846b21eeffd26e146c5205e62dfc51d6b8a487489a4739`.
  Build log: `/tmp/relay-remaining-build.log`.
- Installed executable hash remains
  `d11c467f91be05aa1fca5858aa0c887f0dc2fddf9944ee67984fdd9ffe06e9e0`.
  The workspace symlink was not changed. The app was not launched or installed.
- Disposable smoke directories are `/tmp/relay-plugin-smoke.FMG0do` locally
  and `/tmp/relay-plugin-smoke.wJCw4y` on dandy-07; the remote executable is a
  temporary copy, not `~/.local/bin/relayd` or a running supervisor/worker.

No native UI test was performed during this locked-Mac pass. A green component
test does not resolve the previously observed whole-terminal regressions.

## Outstanding scope, not hidden behind a green component test

- Native mouse/keyboard/VoiceOver validation requires the unlocked Mac.
- Full terminal tests previously failed 29 assertions in the locked run; do not
  attribute this to the lock as a proven cause. Rerun and investigate unlocked.
- Artifacts now has native Markdown formatting and on-demand folder navigation;
  it does not automatically scan directories recursively.
- Agent activity does not capture missing provider/peer events or issue approvals.
- Git review now provides changed-file navigation, but not editor/agent handoff.
- Transfers do not yet stream large files, promise files to Finder, resume, or
  transfer directories. The visible 8 MiB limit is intentional.
- Project actions do not execute commands. Adding execution needs a separately
  reviewed permission, explicit argv/environment/CWD and process lifecycle tests.
- Release, install and sustained terminal performance acceptance remain pending.

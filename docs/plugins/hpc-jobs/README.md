# HPC jobs: staged 0.2.0

This version is implemented in the working copy, not installed or published.
The public experimental 0.1.0 release remains a read-only job list. Do not use
its acceptance evidence as proof that 0.2.0's mutation UI has been verified.

## Features

- List your Slurm jobs: ID, name, state, partition, elapsed time, nodes and reason.
  Load at most 500 rows, show the observed total, and filter locally. No polling.
- Select Details or Logs from a job row. Each fetch needs a separate explicit
  refresh. Inspect one job or expanded array task, not a range of tasks.
- Details show account, state, partition, job directory and stdout/stderr paths.
  JSON-capable Slurm uses `scontrol --json`. Slurm 20.11 uses strictly validated
  one-line output. Ambiguous fields or unowned jobs are rejected.
- Logs show the most recent 64 KiB of stdout or stderr. They must be regular
  files inside the job directory; escaping symlinks, missing files and unresolved
  `%` substitutions produce errors. Logs are snapshots, not live streams.
- Submit a reviewed batch script of at most 8 KiB. Type SUBMIT and confirm the
  host/directory and script. Resource requests are the visible `#SBATCH`
  directives, not an inferred preset. Requires a known pane working directory.
- Cancel one owned, ordinary job by entering its ID twice and confirming.
  Array cancellation is intentionally unsupported because parent IDs can affect
  the entire array. No bulk cancellation, resubmission, or automatic retry.

## Permissions and compatibility

The source manifest uses plugin API 3 and version 0.2.0. Older applications must
reject it. Query, log-read, submit and cancel permissions are declared separately;
the old read-only package cannot invoke mutations. Every operation is reauthorized
against the enabled package digest before dispatch. Switching tabs cannot retarget
the captured host. Revocation does not undo an action already sent to Slurm.

Submission uses stdin and fixed argv, with `--parsable`, `--export=NIL`, and the
reviewed working directory. Load required modules/environment in the script.
Ambient `SBATCH_*`, `SCANCEL_*` and `SLURM_CLUSTERS` variables are removed from
mutation clients. Cluster policy and installed Slurm support still apply.

## Unknown outcomes and recovery

The helper creates a private receipt at
`~/.local/state/relay/plugin-actions/ACTION-ID.jsonl` before dispatch. It records
the host, directory, operation, script hash (not script contents), and intent.
A response record is appended afterward. Receipt IDs are case-normalized UUIDs.

If SSH drops, the helper times out, or waiting is cancelled, the job may still
have been submitted/cancelled. Inspect Slurm and the receipt before doing anything
else. Replaying the same action ID is rejected. Reopening the UI and creating a
new action is NOT deduplication; do not do it until the earlier outcome is known.
Receipts are capped at 10,000 per host filesystem directory and are never purged
automatically. User deletion of a receipt removes its replay protection.

This is at-most-once dispatch per retained action ID, not distributed exactly-once
execution. Filesystem durability depends on the host filesystem. A receipt write
or sync failure before dispatch prevents execution.

## Acceptance checklist for an unlocked Mac

1. Verify the app/helper build identities; install the staged build only after
   reviewing remaining terminal regression failures. Preserve existing sessions.
2. Review/install-disabled/enable the new manifest through a controlled release;
   test disable/revoke. Do not silently upgrade the published 0.1.0 asset.
3. On dandy-07, list jobs; filter/search; scroll with trackpad and keyboard;
   open Details and both logs; verify host and selected ID stay correct.
4. Test missing/finished jobs, missing log, and very large synthetic log. No
   private log content goes into screenshots or the public repository.
5. Test submit/cancel dialogs against fixture commands first, including refusal,
   dismiss, duplicate click, disconnection, unknown outcome and revocation.
6. A real scheduler mutation requires separately agreed disposable work and
   cluster policy/resource limits. Never use an existing research job as a test.
7. Re-run local/SSH terminal input, selection, clipboard and geometry checks.
   The locked-Mac full suite failed in native input tests; do not waive that gate.

Not included: completed-job accounting, CPU/GPU history charts, live log following,
job arrays cancellation, script-file upload, or automatic periodic refresh.

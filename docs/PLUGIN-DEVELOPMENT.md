# Developing Relay plugins

Relay currently accepts **declarative JSON packages**, not executable extensions.
A package can display information, offer an HTTPS link, or expose an operation
implemented by Relay itself. It cannot load JavaScript, Swift, shell scripts,
webviews, install hooks, or VS Code extensions.

This guide describes the current source tree. Plugin support and newer operations
are experimental; do not assume the latest public Relay DMG includes them. Match
the app and `relayd` build, and check the [validation record](plugins/NIGHTLY-VALIDATION.md)
before distributing a package that depends on staged features.

## Start with a package

Create a public GitHub repository and add a file named `relay-plugin.json`:

```json
{
  "schemaVersion": 1,
  "apiVersion": 1,
  "id": "example.project-guide",
  "name": "Project guide",
  "version": "1.0.0",
  "repository": "example/project-guide",
  "permissions": [],
  "contributions": [
    {
      "id": "getting-started",
      "kind": "information",
      "title": "Project guide",
      "text": "Project instructions shown as plain text. Nothing executes."
    }
  ]
}
```

Replace `example.project-guide` with your chosen stable plugin ID and
`example/project-guide` with your actual `owner/repository`.
The repository field must match the GitHub source used to install the package.
The [copyable starter](examples/relay-plugin.json) and
[first-party packages](plugins/) provide additional examples.

Use a stable plugin ID across releases. IDs, contribution IDs and versions accept
ASCII letters, digits, dots, underscores and hyphens; they cannot be `.` or `..`.
Version strings are identifiers, not an automatic semantic-version upgrade rule.
Use semantic versions by convention and select releases explicitly.

## Contributions and API versions

| Kind | Minimum API | Required fields beyond `id` and `kind` | Behavior |
| --- | --- | --- | --- |
| `information` | 1 | `title`, `text` | Plain text; no action |
| `link` | 1 | `title`, `text`, `url` | User-clicked HTTPS link; no embedded credentials |
| `tool` | 2 | `title`, `text`, `operation` | Calls a core-owned operation after authorization |
| Mutating HPC `tool` | 3 | Same as tool | Separate submit/cancel permissions and per-action review |

All packages use `schemaVersion: 1`. Choose the lowest API supporting your
contributions. Older apps reject unsupported APIs or operation names; there is
no automatic downgrade. Information cannot carry `url` or `operation`; links
cannot carry `operation`; tools cannot carry `url`. Unknown fields are rejected
at the package, permission and contribution levels.

A tool contribution looks like:

```json
{
  "id": "review",
  "kind": "tool",
  "title": "Review project changes",
  "text": "Inspect tracked changes in the selected pane's project.",
  "operation": "gitReview"
}
```

Place it in an API-2 package with this permission:

```json
{"kind": "projectRead", "reason": "Read tracked status and diffs in the selected project."}
```

## Supported operations and permissions

Permissions are an **exact union** of the requirements of all contributions.
Missing required permissions fail validation. Extra permissions prevent activation;
do not request capabilities speculatively. Every permission needs a concrete,
nonempty explanation shown during review.

| Operation | Required permissions | Current behavior |
| --- | --- | --- |
| `hpcJobs` | `remoteOperation` | Owned Slurm queue snapshot, up to 500 rows |
| `hpcDetails` | `remoteOperation` | One owned job/task; JSON or strict legacy Slurm parsing |
| `hpcLogs` | `remoteOperation`, `projectRead` | Last 64 KiB of scheduler-reported stdout/stderr inside its job directory |
| `hpcSubmit` | `jobSubmit` | API 3: explicitly reviewed batch script, up to 8 KiB |
| `hpcCancel` | `jobCancel` | API 3: explicitly confirmed owned numeric job; no arrays |
| `artifacts` | `projectRead` | Bounded regular-file listing, image/text/table previews |
| `agentActivity` | `agentMetadata`, `agentContent` | Snapshot of events already captured for the originating pane |
| `gitReview` | `projectRead` | Scoped tracked status and staged/unstaged diffs; no external diff/textconv |
| `transfers` | `projectRead` | Browse folders; chunk one regular file up to 64 GiB, verify source identity and final digest, pause/resume within the open panel, save a local copy |
| `projectActions` | `projectRead` | Detect project/lockfiles and show suggestions; never execute them |
| `projectRun` | `projectExecute` | API 3: user-reviewed absolute argv, explicit environment and captured cwd; 60-second maximum, typed confirmation and no-replay receipt |

`projectWrite` and `network` are reserved permission names, not available plugin
execution APIs. Opening a link does not grant background network access. No
operation grants a plugin SSH keys or arbitrary process execution.

The host, pane and directory are captured when the tool panel opens. A manifest
cannot choose them. Tab switching does not retarget an in-flight request.
Operations run on demand, with at most two helper requests per app and no waiting
queue. File paths travel as JSON, not interpolated shell source. Directory-rooted
file access rejects escapes; special files are rejected. Commands still run as
the connected user: this is not a general-purpose OS sandbox.

Agent snapshots do not guarantee complete peer-message capture. Markdown/HTML
previews remain inert source text. Git review does not stage or commit. Transfers
do not yet stream large files, resume, or provide Finder drag-out. See the
[current gaps](plugins/NIGHTLY-VALIDATION.md#outstanding-scope-not-hidden-behind-a-green-component-test).

## Validate and test locally

There is no external executable-plugin SDK or standalone manifest-validation CLI
yet. For Relay contributors, use the real Swift decoder and isolated store tests:

```sh
swift test -c release --build-system native --jobs 2 --filter 'plugin|hpc'
(cd remote/relayd && go test -race ./... && go vet ./...)
```

Use Relay's documented build prerequisites; the current working tree may contain
a local Ghostty package override. The optimized test configuration matters:
debug-only tests previously missed a release-tag validation regression.

Add package fixtures to the isolated lifecycle test in
[`PluginOperationTests.swift`](../Tests/RelayTests/PluginOperationTests.swift).
Validate bytes with `RelayPluginPackage.decode(_:repository:)`, then exercise
review/install-disabled/enable/disable/update/rollback in a temporary store.
Never write test packages straight into a user's live installation index.

Test malformed/unknown fields, missing and extra permissions, wrong repository,
unsupported APIs, duplicate IDs, oversized responses, cancellation, revocation,
missing helpers, path escapes and stale pane ownership. New operations need tests
for both the Swift consumer and Go producer. A successful helper response alone
does not prove native UI behavior or terminal responsiveness.

[`test-plugin-helper.sh`](../scripts/test-plugin-helper.sh) checks a staged helper
against a disposable `/tmp` fixture locally or over SSH. The fixture contains
`package.json`, `pnpm-lock.yaml`, `table.csv`, and `empty.txt`, with `table.csv`
staged in Git for Git review checks. The wrapper builds `relay-verify-plugin`;
the helper and fixture must both have explicit `/tmp/` paths. It is a smoke harness, not an installer or complete acceptance
suite. Do not use real jobs or research files as mutation fixtures.

Run `scripts/test-plugin-helper.sh /tmp/relayd /tmp/fixture` from the repository,
or run `go run -buildvcs=false ./cmd/relay-verify-plugin /tmp/relayd /tmp/fixture`
from `remote/relayd`. Both accept an optional `--ssh HOST`. This is a developer
verification command; it is not installed as an application runtime helper.
The native regression suite uses a private fake Git command with canonical
staged output and a private fake SSH executable. Artifact and transfer checks
use the actual staged Go helper and private filesystem. Those fixtures establish
the harness contract, not live Git/SSH interoperability.

## Publish and install

1. Commit the manifest and a README describing functionality, permissions, limits,
   minimum tested Relay/helper builds, and support/contact information.
2. Create a tagged GitHub release, preferably a prerelease while experimental.
   Attach exactly one asset named **`relay-plugin.json`**. A file on `main`, a
   source archive, or a draft release is not an installable package.
3. In a compatible Relay build, open **Settings → Plugins → Review release**.
   Enter `owner/repository` and the exact tag, for example `v1.0.0`.
4. Review the source, content digest and permissions. Choose **Install disabled**,
   then explicitly enable it. Native tools are accessed using the pane's puzzle
   icon, **Plugin tools for this pane**.
5. Manually verify the installed flow, including keyboard/accessibility, failed
   connections, disable/revoke and interaction with existing terminals.

The current loader uses unauthenticated GitHub release downloads: **public repos
only**. Private-repository tokens, a searchable catalog and automatic updates are
not implemented. Downloads are restricted to allowed GitHub HTTPS hosts, bounded
to 256 KiB, and checked against the advertised size and asset digest when present.
A pinned SHA-256 establishes byte identity, not publisher trust or a signature.

For an update, publish a new package version under a new release tag and review it
explicitly. Do not replace the bytes of an installed version: Relay rejects that
as a republished version. Updates and rollback to the retained previous revision
are disabled until explicitly enabled. Another repository cannot take over an
installed plugin ID. Safe mode suppresses plugins; uninstall does not authorize
deletion of project data.

## Implementing a new operation in Relay

An unknown `operation` cannot be added by publishing JSON alone. Until a sandboxed
runtime exists, contribute the behavior to Relay core:

1. Add the operation and minimum permissions in
   [`PluginOperations.swift`](../Sources/Relay/PluginOperations.swift), and update
   validation/API compatibility in [`PluginPackage.swift`](../Sources/Relay/PluginPackage.swift).
2. Implement bounded, cancellable host behavior in
   [`remote/relayd/internal/daemon`](../remote/relayd/internal/daemon/). Do not accept
   package-supplied executables, arbitrary network endpoints or shell source.
3. Add native UI in [`PluginToolsView.swift`](../Sources/Relay/PluginToolsView.swift)
   or a focused view. Keep authorization before dispatch and before disclosure;
   preserve captured scope and cancellation. Do not add work to terminal input,
   render or resize paths, or introduce idle polling by default.
4. For mutations, define separate permissions and an explicit review flow. Handle
   uncertain transport outcomes without blind retries. HPC's durable intent IDs
   prevent replay of the same action; they are not an exactly-once Slurm guarantee.
5. Test, build compatible app/helper artifacts, and document old-helper failure
   behavior before publishing a package requiring the operation. Updating a helper
   file does not replace already-running durable workers.

See the [architecture and roadmap](PLUGIN-SYSTEM.md) and
[acceptance checklist](plugins/ACCEPTANCE.md) for the broader release gates.

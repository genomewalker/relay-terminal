# Unified provider setup

Relay's managed Claude prompt/status resources and failure-event adapter use one
portable bundle on macOS and Linux. The same bundle is installed at
`~/.config/relay/provider-setup`; its asset hashes are recorded alongside it in
`provider-setup-manifest.json`.

On either host:

```sh
~/.config/relay/provider-setup audit
~/.config/relay/provider-setup apply
```

From a provisioned source checkout, use `scripts/relay-provider-setup apply`.
The three native helpers `relay-provider-setup`, `relay-install-shell-ui` and
`relay-repair-chitta-failure` must be installed in `~/.local/bin`. `bundle` emits
a portable shell entry containing the same base64 asset payload on both hosts;
it invokes the installed native `relay-provider-setup` rather than embedding a
platform-specific executable or an interpreter. Transfer it through Relay's
captured host transport. Remote execution must target the explicit host/tab
binding; a local command operates only on the local home directory.

`audit` returns bounded JSON without command bodies or credentials. Exit status
1 means managed-resource drift; 0 means these managed resources match. This is
configuration inspection, not a provider runtime or session health test.

`apply` preserves unrelated Claude settings, custom hooks, authentication, and
the existing outer quota-capture wrapper. It backs up changed files privately
and checks concurrent changes before replacing them. Unknown status renderers
are refused rather than overwritten. It does not restart sessions.

Common resources: Relay prompt, cc-status runtime resolver, native status
capture/display adapter, and the installed Chitta5.73.1 failure-event repair.
The native installer supplies all three audited assets, including
`~/.config/relay/claude-status`. That shell entry retains legacy pane capture
and captures quota through native `relayd subscription-quota-statusline` with
a no-op renderer command. Both captures are silent, best effort and share a
four-second budget. The shared Bash renderer receives the unchanged payload
and environment directly, with its original eight-second deadline, output and
exit behavior; quota-helper failure does not suppress the user's footer. Existing outer
quota wrapper commands and user footer arguments remain intact. Renderer
selection is still the shared cc-status resolver. An unrelated status command,
an ambiguous wrapper, a changed destination or a symlink is refused.
Host capabilities remain explicit: local quota capture may be present while
remote capture is absent. User hook counts may differ; they are reported rather
than overwritten to force equality. Plugin upgrades can replace the adapter;
audit detects the missing repair. Other Chitta versions require a reviewed
adapter migration, not a guessed patch.

The Go-only release can migrate the older four-token quota wrapper with
`relay-provider-setup migrate-quota-statusline SETTINGS_SHA256 LEGACY_SOURCE_SHA256`.
Both hashes must name the reviewed current files. This separate action replaces
only the managed `statusLine.command` with the native `relayd
subscription-quota-statusline` command and preserves the exact base64 renderer
argument, other status fields and other settings. It retains a private preimage
backup and refuses a changed file or an unrecognized wrapper. It does not run
the renderer or invoke provider setup's `apply` action. Install the native
`relayd` and shell UI assets before using the migrated command; archive obsolete
managed Python files only after their callers have been migrated and read back.
Audit and shell UI reinstallation recognize the native successor for that same
owned home. A malformed native renderer or a native command belonging to
another home is refused by reinstallation.

Remaining integration: automatic invocation from app/helper provisioning,
remote quota capture parity, generic plugin-version migration, and live
background-status/Stop-hook acceptance. This bundle does not establish full
Claude/Codex runtime parity or resolve the missing background status footer.

## Terminal independence

Claude/Codex launch, authentication, history, user hooks, and status rendering
must work without a Relay terminal. Shared renderer files do not require the
Relay GUI; Relay event hooks must be silent when `RELAY_SESSION` is absent.
The prompt is gated by interactive mode and `TERM_PROGRAM=relay`. Normal shell
PATH must resolve the official provider executables, excluding Relay shims.
Relay-specific commands such as `rcode` and Relay MCP tools still require Relay.

Relay panes export their own pane ID as `RELAY_PANE_ID` (lowercase UUID), so
a script or agent in the pane can learn which pane it runs in. A value
inherited from a parent pane is always replaced. This applies to panes started
by relayd 0.5.34 or later; panes started by an older worker or host keep their
old environment until they are restarted. Panes started through relayd also
export the same value as `RELAY_SESSION`, which remains for compatibility with
existing hooks and helpers; new integrations should read `RELAY_PANE_ID`.
`RELAY_PANE_ID` is the pane's self-description, not proof of identity: any
process can set it. Relay verifies callers by kernel process ancestry.

Recorded checks, 4 October 2026: local and dandy-07 Claude/Codex version checks
passed with Relay environment removed; both Claude status commands rendered
nonempty output with exit0 and no stderr. All eleven installed local Relay hooks
returned exit0 with empty stdout/stderr outside Relay. Disposable local TUIs
and remote PTY launches reached prompts without model requests. Local Claude
showed the custom footer and exited0; remote proof cleanup completed. Codex's
local UI reported21 hooks needing review, with0active in the inspected event
rows. Hook approval/actual execution is therefore still open. This evidence
covers startup and render behavior, not every model/tool/auth-refresh workflow
or operation with Relay software uninstalled.

Trust follow-up: after the user confirmed trust, standalone Codex0.160.0's
`/hooks` UI reports all21installed hooks active: PreToolUse9, PostToolUse4,
PreCompact1, SessionStart4, SessionEnd1, UserPromptSubmit1, Stop1. The approval
gate is closed. Individual tool/compaction hook execution was not exercised by
this startup check; no model request was sent.

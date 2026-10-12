# Unified provider setup

Relay's managed Claude prompt/status resources and failure-event adapter use one
portable bundle on macOS and Linux. The same bundle is installed at
`~/.config/relay/provider-setup.py`; its asset hashes are recorded alongside it in
`provider-setup-manifest.json`.

On either host:

```sh
python3 ~/.config/relay/provider-setup.py audit
python3 ~/.config/relay/provider-setup.py apply
```

From a source checkout, use `python3 scripts/relay-provider-setup.py apply`.
`bundle` emits the self-contained installer for deployment through Relay's
captured host transport. Remote execution must target the explicit host/tab
binding; a local command operates only on the local home directory.

`audit` returns bounded JSON without command bodies or credentials. Exit status
1 means managed-resource drift; 0 means these managed resources match. This is
configuration inspection, not a provider runtime or session health test.

`apply` preserves unrelated Claude settings, custom hooks, authentication, and
the existing outer quota-capture wrapper. It backs up changed files privately
and checks concurrent changes before replacing them. Unknown status renderers
are refused rather than overwritten. It does not restart sessions.

Common resources: Relay prompt, cc-status runtime resolver, legacy status
capture/display adapter, and the installed Chitta5.73.1 failure-event repair.
Host capabilities remain explicit: local quota capture may be present while
remote capture is absent. User hook counts may differ; they are reported rather
than overwritten to force equality. Plugin upgrades can replace the adapter;
audit detects the missing repair. Other Chitta versions require a reviewed
adapter migration, not a guessed patch.

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

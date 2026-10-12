# Plugin dialog accessibility regression

Verified manually with Computer Use on 2026-09-19, helper 26.916.1001103.

An isolated SwiftUI app compiled the actual `PluginSettingsView`, package,
store and release-loader sources. It used a temporary store, safe mode and
no terminal, workspace, SSH or operation runner. The manager/view now accept
an injected manager/store directory so this isolation does not change the
normal production storage location.

## Observed comparison

| State | Original container | Explicit VStack container |
| --- | --- | --- |
| Empty plugin manager | Accessibility read succeeds | Succeeds |
| Review of public HPC jobs v0.1.0 | Helper pipe closes | Succeeds |
| Installed, disabled HPC card | Helper pipe closes | Succeeds |
| Review and installed card together | Not verified | Succeeds |
| Close and reopen completed review | Not verified | Succeeds |

Changing only the review card left the installed-card crash reproducible.
Changing both GroupBox containers removed both observed failures. This is
evidence of a GroupBox/accessibility-transform interaction, not evidence that
package execution or remote terminals cause the crash. Package code was never
executed. The upstream helper's precise internal index bug is not fixed here.

The isolated application compiled in Swift 6 language mode. No release or
installed Relay application was replaced. The full Settings window, nested
sheet presentation inside Relay, and enabled-plugin cards still require an
integration pass; do not treat these component tests as full-app acceptance.

Upstream matching crash: https://github.com/openai/codex/issues/43573

## Full-app follow-up

The release app built and passed strict deep code-signature verification.
Staged artifact: `/tmp/relay-settings-validation.MPIjN2/Relay.app`.
Executable SHA-256: `0e7ef3bd38d275f28e14279f10de394d28283a8a910dd2b244e3c3328fd4b795`.
The installed `/Applications/Relay.app` was not replaced.

A separate copy with bundle ID `dev.relay.settings-validation` and
`RELAY_SAFE_MODE=1` opened one local pane without restoring remote panes.
Workspace accessibility and the workspace action menu worked. The Settings
menu action and shortcut did not produce an observable Settings window through
Computer Use; manual assistance was requested. Full-app nested-sheet acceptance
therefore remains incomplete.

`swift test -c release --build-system native --jobs 2 --filter 'plugin|Plugin'`
completed successfully: 21 passed, one live-network test skipped. The public
release download was exercised manually in the isolated component test above.

### Completed integration and installation

After the user opened Settings manually, Computer Use successfully completed
Settings → Plugins → review HPC v0.1.0 → Done → reopen Plugins. The retained
review result remained accessible. No plugin was installed in the normal store.
This supersedes the nested-sheet acceptance blocker above, but does not verify
the Settings keyboard shortcut or enabled-plugin cards.

The test process was stopped and the verified release installed at
`/Applications/Relay.app`. Its executable hash matches the staged hash above.
The previous application is retained at
`/tmp/relay-settings-validation.MPIjN2/Relay-previous.app`.
Remote helpers and sessions were not modified. The production app was not
automatically relaunched.

## Visual and idle-overhead pass

The next manager revision uses RelayTheme colors, system typography, explicit
repository/tag labels, separate review and installed sections, and an expandable
digest. It retains explicit stacks rather than GroupBox. Package validation
is cached when the store is loaded instead of being repeated in the view body;
authorization still rechecks the store at operation time.

Manual component checks passed for an installed disabled card, review result,
expanding verification details, invalid-tag feedback, recovery with a valid
tag, and sheet dismissal. A screenshot was inspected for clipping and hierarchy.
The plugin test filter again passed 21 tests with one live-network test skipped.

Two idle samples two seconds apart reported 0.0% CPU, 38 MB memory and four
threads for the isolated manager process (2026-09-19 05:58:48–05:58:50 local).
This is a short component measurement, not a full Relay or battery benchmark.

Polished build installed at `/Applications/Relay.app`, signature verified;
executable SHA-256 `0afde6c42c3282ccbc315c021f53be5e6fc1c2d9cdba5fb55ee2203b2c6e9c2b`.
Previous build retained at `/tmp/relay-plugin-polish.hwW8fb/Relay-previous.app`.
The polished component was tested manually; the full Settings nesting was
verified on the preceding accessibility-fix build. No remote deployment was
performed, and the installed app was not automatically launched.

# Relay configuration from the CLI

Use the installed owner CLI at `/Applications/Relay.app/Contents/MacOS/relay-settings`.
It uses native validation and conflict checks. It does not edit preference plists,
account registries or credential stores behind the application's back.

## Application preferences

```sh
relay-settings schema
relay-settings get
relay-settings get miko_autonomy
relay-settings set miko_actions_per_minute 60
relay-settings set miko_host_key local
relay-settings update --file reviewed-preferences.json
```

The schema includes terminal appearance, workspace/image preferences, intelligence,
maintenance, account routing, keyboard bindings, assistant hotkeys, Miko host and
autonomy/action limits/pause, shepherd settings, quota failover and legacy context
settings. Complex settings round-trip as native JSON objects. Change Miko pause
separately. Unknown keys, invalid types/ranges and stale revisions are refused
before changes. Existing `--request-id` and `--expected-revision` options retain
an exact receipt and protect reviewed changes.

Miko itself cannot use this API to change its own policy, pause, shepherd or
quota-failover configuration. Owner CLI configuration retains the existing
workspace-configuration grant. A CLI interface is not permission to change grants,
ignore a human takeover or bypass a native operation's approval.

## Host API/model limits and credentials

```sh
relay-settings host local text get
relay-settings host local text get max_requests_per_day
relay-settings host local text set max_requests_per_day 300
relay-settings host dandy-07 text update --file reviewed-host-settings.json
```

A host update file is the complete `settings` object returned by `get`.
It includes saved account references and their separate limits. Keep the
monetary limits/account rows when changing a request count. The CLI reads the
configuration identity and uses native compare-and-swap; it never retries a
failed or uncertain mutation. For a reviewed identity, add
`--expected-revision CONFIGURATION_ID`.

Credential operations use `host HOST text request --file PRIVATE_JSON` and the
native request format (`v: 1`, `operation: text_credential_save`,
`text_credential_status`, `text_credential_list`, `text_credential_delete` or
`text_vault_unlock`). Supply secret material only through a private file; it
is not a command argument or diagnostic output. Native credential storage and
validation remain authoritative.

## Host context/capacity policy

```sh
relay-settings host local capacity get
relay-settings host dandy-07 capacity set new_pane_default true
relay-settings host dandy-07 capacity update --file reviewed-capacity-settings.json
```

Native capacity updates use the returned numeric revision. Policy enablement
does not prove a provider supports context retirement/refresh; inspect
`ready`, `reason` and capabilities. Pane enrollment, pause, release and
account moves are runtime operations with their own identity/preservation
contracts; changing policy does not forge those receipts.

## Provider account slots, expectations and launch defaults

```sh
relay-settings host local accounts get
relay-settings host dandy-07 accounts request --file reviewed-account-request.json
```

Request files use the existing native account schema. Supported configuration
actions are `list`, `configure`, `usage`, `launchers`, `repair_launchers`,
`mcp_preview`, `prepare`, `set_expectation` and `set_defaults`.
For example:

```json
{"action":"set_defaults","provider":"claude","label":"business","model":"opus","effort":"high"}
```

These commands share native account validation and storage. They do not sign
out/remove an account, send terminal input, stop a worker or migrate a pane.
Native migration and installation remain separate guarded operations.

`local`/`This Mac` use the installed native node. A remote host is an exact
SSH alias; the CLI invokes the host's installed `~/.local/bin/relayd node`
through SSH. No shell command is constructed from configuration values.

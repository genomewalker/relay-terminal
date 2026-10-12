# Agent activity

Inspect agents already observed by Relay in the selected pane. Open Plugin
tools, choose Agent activity, then refresh. The snapshot is fixed while you read;
it does not reshuffle continuously or poll a remote transcript.

- Up to 100 agents, prioritizing those needing input and recent activity.
- Filter by name, identity or state; expand agent details and recent updates.
- Structured Codex plan updates and Claude TodoWrite checklists.
- Claude TaskCreate/TaskUpdate deltas when successful hooks include task identity.
- Recent pane activity and peer-message events when the provider reports them.

This is not a complete transcript or a peer-delivery service. Missing events are
not inferred. A checklist is not the provider's plan/execute mode; unsupported
mode is explicitly unavailable. Approvals stay in the agent CLI, and viewing
activity never grants execution permission.

The package separately requests agent metadata/content access. Manual installed
snapshot and revoke checks remain deferred until the laptop is unlocked.

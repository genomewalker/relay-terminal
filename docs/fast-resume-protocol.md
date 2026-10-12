# Relay fast-resume protocol proposal

Status: design proposal; not implemented or benchmarked.

## Goal

Target a useful cached screen within 250 ms and a fully interactive warm resume
within one second. Report cold SSH startup separately. A new application
protocol cannot remove SSH authentication, network latency, or remote process
startup from a cold connection.

Measurements motivating this design: historical replay already transfers in
less than a second; the latest warm attachment took 1.36 seconds, while a cold
app launch took 1.86 seconds from attach request to acknowledgement. Local
8 MiB cache restoration also preceded that request by about two seconds.
Those are individual observations, not percentile guarantees.

## Transport and state

Retain SSH encryption and the existing shared connection and binary framing.
Relay already multiplexes panes and batches replay. The proposed addition is
a negotiated checkpoint and resume contract that reduces reconstruction work.

Each pane has a worker incarnation, an attach generation, a checkpoint sequence,
and an ordered event sequence. Events include terminal bytes and resize events.
Do not equate today's record sequence numbers with byte offsets.

On an already authenticated connection, a client sends RESUME containing its
incarnation, checkpoint identity, applied cursor, geometry, and capabilities.
The server responds without another application-level negotiation round trip:

- RESUME_OK and the contiguous event suffix when the client has a valid base.
- CHECKPOINT_BEGIN, bounded checkpoint chunks, then the contiguous suffix when
  the base is absent or incompatible.
- RESET_REQUIRED when the available history cannot establish a valid base.

The server freezes a watermark W while subscribing to subsequent events without
a gap. It sends state through W, a CAUGHT_UP(W) fence, then events after W in
order. Generation checks prevent cancelled connections from committing later.

Checkpoint fidelity includes both screens, cursor and saved cursor, modes,
attributes, colors and palette, hyperlinks, margins, tab stops, wrap state,
pending UTF-8/control parsing, geometry, and supported extension state.
Scrollback needs a supported import representation. A visible-text export or
image is a preview, not a resumable checkpoint. Ghostty import/export support
must be audited and continuation equivalence tested before choosing a format.

## Scheduling

Prioritize input, acknowledgements, current screen state, and live output over
bulk scrollback. Send optional history as independent bounded row blocks;
never replay older raw terminal commands into a terminal already advanced to
the current screen. Use per-pane byte credits and fair scheduling so one large
history cannot monopolize the shared writer. SSH's underlying ordered stream
still has head-of-line blocking; this scheduling cannot eliminate it.

Negotiate optional chunk compression and retain uncompressed fallback. Measure
CPU and latency before choosing compression; it is not the main explanation
for the attachment delays observed so far.

Separate received, applied, and durable cursors. A durable acknowledgement must
be backed by a matching checkpoint and pending parser state. Historical queries,
clipboard actions, and notifications need an explicit replay side-effect policy.

## Compatibility and rollout

Keep older workers running. Negotiate capabilities and retain the existing byte
replay fallback. A faithful checkpoint producer requires a supported sequenced
output/event feed; never compete with the worker by reading its PTY directly.
Do not assume an old worker supports a new read-only subscription or checkpoint
API. Unsupported workers remain on the current path until a safe upgrade is
available. No worker restarts are part of this proposal.

First optimize and measure local checkpoint hydration, connection setup, and
remaining catalog work. Prototype RESUME plus checkpoint/tail only after these
measurements show where the new contract would improve the critical path.

Acceptance: compare continuously processed reference state at W and after more
input, output, and resizes; test interrupted chunks, history rollover, concurrent
panes, cancellation, duplicate delivery, and replay/live boundaries. Report first
cached frame, correct live frame, input readiness, median/p95/max latency, memory,
and unchanged worker PID/start time separately.

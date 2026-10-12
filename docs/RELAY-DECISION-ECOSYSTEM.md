# Relay decision ecosystem

Harnesses supply session observations. Relay's deterministic supervisor interprets
them and publishes findings. Optional decision backends provide advisory results.
Chitta owns durable memory, capsule preparation, and verified handoffs; model
output grants no lifecycle permission.

The supervisor accepts a `RelayDecisionBackend`, permitting a native numeric model
without tying coordination to a particular language model or harness. Replacing
a backend invalidates in-flight output. Publication checks session incarnation,
the exact observation timestamp and a 30-second age bound. Model advice cannot
raise the deterministic escalation stage.

Settings → Agent intelligence provides an artifact path, separately supplied
trusted SHA-256 digest, a load action and status. The opt-in intelligence toggle
controls scoring. With no artifact configured, the existing Apple system-model
path remains available. An invalid configured artifact disables model advice
instead of silently switching providers. Changing the configured file requires
an explicit reload; opening settings or requesting an advisory loads the persisted
configuration.

## Native classifier contract

`relay.local-decision/1` JSON is limited to 64 KiB. It contains:

- `identifier`, `task` (`rotate_now`), and `independentlyLabeled` (true).
- `featureNames` in the exact order defined by `RelayLocalDecisionModel`.
- Equal-length `means`, positive `scales`, and `weights`, plus `intercept`.
- `calibrationSlope` (positive), `calibrationIntercept`, `waitThreshold`, and
  `rotateThreshold`, with an abstention interval between thresholds.
- SHA-256 `trainingDigest`, `splitDigest`, `calibrationDigest`, and `policyDigest`.

The raw margin is `intercept + sum(weight * (value - mean) / scale)`;
calibration applies `sigmoid(calibrationSlope * margin + calibrationIntercept)`.
NaN, infinite, negative counters, overflow, wrong dimensions, wrong feature order,
missing evaluation metadata and digest mismatches reject scoring/loading.
Context occupancy is excluded because existing usage snapshots do not establish
it. Features contain only output rate, retries, progress age, restarts, active
request, reachability, and durable-checkpoint evidence.

Metadata assertions and a file pin identify the reviewed artifact; they do not
independently prove that its training or calibration was sound. Artifact review
must establish that separately. No deployable trained artifact is supplied here.
The historical extraction experiment remains gated on canonical request/turn
accounting, verified lineage, purged splits and independently reviewed labels.
Its current feature schema is different and cannot be exported into this native
contract without collecting matching, verified harness features.

The native classifier currently advises only sessions with deterministic
supervisor findings. Rotation advice asks for review; wait advice does not remove
deterministic findings. Loop/stall prediction and routing remain separate tasks
requiring distinct labels and contracts. Existing deterministic detection remains
active. No automatic rotation, GPU submission or production model replacement is
part of this integration.

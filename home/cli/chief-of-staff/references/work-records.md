# Publish Work records

The coordinator is the sole writer. Workers send evidence to it. Run
`chief-of-staff-init` on activation/resume to register the portfolio, current
space, coordinator terminal and owning core. Explicit `--portfolio PATH` resumes
that portfolio; never use it to take over an active coordinator. Independent
spaces have independent atomic discovery files under `chief-of-staff/work-spaces/`.
No shared index can lose another space's registration.

Publish each event as a JSON file, then run:

```sh
chief-of-staff-work --portfolio "$portfolio" publish --event /path/to/event.json
chief-of-staff-work --portfolio "$portfolio" snapshot
```

`snapshot` replays without writing. `repair` checks coordinator ownership and
atomically republishes the snapshot after an interrupted publication. Neither
command resumes work. Do not edit `work/events/` or `work/snapshot.json` by hand.
Keep narrative task and portfolio Markdown readable and current.

Every event needs a permanent unique `id`, `kind` and `task`. Reuse the exact ID
and content when retrying an uncertain publication. The command returns
`published` or `duplicate` and the original sequence. Conflicting ID reuse fails.
Timestamps come from the writer's clock; sequence establishes durable order.
Original baseline definitions never change. Snapshots are bounded views, with
explicit omission counts; complete events remain in the portfolio.

The file-size bound is 768 KiB; readers impose no unrelated universal list-size
cap. Snapshots retain all unfinished tasks, unresolved issues and each worker's
latest report. Recent resolved issues (normally 64), report samples (64), chart
events (96) and plan versions (32) can be reduced further to meet the file bound;
each omitted collection has an explicit count. If required live state cannot fit,
publication fails before writing the event. Completed/cancelled tasks can leave
the bounded view with an explicit task omission count. Durable history remains.

Snapshot additions keep the existing version and event command schema: `workers`
is the full latest-per-worker roster; `issues_omitted` counts resolved issue
history; verification history includes the accepted checkpoint definition,
version and evidence. Existing snapshots remain readable but label an incomplete
worker roster or unavailable historical evidence. Coordinator `repair` replays
existing events to publish these fields without inventing events or progress.

Publish these first, **before an implementation assignment**:

```json
{"id":"T001-intake","kind":"task","task":"T001","outcome":"Deliver the Work panel","next_action":"Publish the baseline"}
```

```json
{"id":"T001-plan-v1","kind":"plan","task":"T001","checkpoints":[{"id":"records","title":"Structured records","depends":[],"acceptance":"CLI contract checks pass with recorded output"},{"id":"panel","title":"Native Work panel","depends":["records"],"acceptance":"Native mod check and rendered interaction evidence"},{"id":"review","title":"Independent review","depends":["panel"],"acceptance":"Review findings addressed and required checks pass"}]}
```

```json
{"id":"T001-start","kind":"lifecycle","task":"T001","state":"active","next_action":"Implement structured records"}
```

Implementation dispatch requires an active task with a baseline. Research,
review and check roles can bootstrap without a baseline; they still must not
modify coordinator records. Legacy Markdown tasks stay visible as **No baseline**.
For an existing long task, publish its honest remaining plan and explain the
late baseline in Markdown; never backdate checkpoint completion.

Publish a check-in at each meaningful transition and before the current deadline
(five minutes by default). `step` should equal an active checkpoint ID when
applicable. This updates the check-in clock, never the verification clock.

```json
{"id":"T001-checkin-1","kind":"check-in","task":"T001","step":"records","summary":"Record helper implemented; checking interruption recovery","next_action":"Run contract checks"}
```

Declare a longer quiet operation explicitly, for at most a day:

```json
{"id":"T001-quiet-1","kind":"check-in","task":"T001","step":"panel","summary":"Native build running","next_action":"Inspect the build result","quiet_seconds":1800,"quiet_reason":"Expected quiet compile with no intermediate result"}
```

After checking concrete evidence, accept a checkpoint. Dependencies must already
be verified. A second verification of the same current version fails. Evidence
references must name actual results; this command records the coordinator's
acceptance, and cannot establish that an arbitrary assertion is true.

```json
{"id":"T001-records-accepted","kind":"verify","task":"T001","checkpoint":"records","summary":"Contract checks passed","evidence":["/absolute/artifacts/records-checks.txt: command, timestamp and exit 0"]}
```

Record worker reports separately, including their literal navigable terminal.
Polling a busy worker never satisfies a check-in or verifies progress.

```json
{"id":"T001-worker-1","kind":"worker","task":"T001","terminal":"t29s","status":"working","summary":"Implementing the native panel"}
```

An explicit blocker may apply to a checkpoint or the whole task. Set `needs_user`
only for an actual user decision; only this condition triggers a desktop
notification. Repeated refreshes/reopening do not redeliver the same issue.
Notification delivery is at most once per installation, with failed/unconfirmed
attempts labeled in the panel; the decision remains visible until resolved.

```json
{"id":"T001-question-1","kind":"block","task":"T001","issue":"storage-choice","checkpoint":"records","message":"Choose the approved storage location","needs_user":true}
```

```json
{"id":"T001-answer-1","kind":"resolve","task":"T001","issue":"storage-choice","summary":"User approved the private portfolio directory"}
```

Revisions supply the entire current checkpoint set and a short reason. IDs keep
their identity. Changed criteria invalidate that checkpoint's evidence and
dependent verification. Removed checkpoints leave the current count but remain
in the baseline, revisions and event history. A verified count can decrease on
revision. Counts express accepted outcomes, never effort or ETA.

```json
{"id":"T001-plan-v2","kind":"revise","task":"T001","reason":"Added recovery verification","checkpoints":[{"id":"records","title":"Structured records","depends":[],"acceptance":"CLI contract checks pass with recorded output"},{"id":"recovery","title":"Recovery","depends":["records"],"acceptance":"Interrupted snapshot repaired from ordered events"}]}
```

Lifecycle states are `queued`, `active`, `paused`, `cancelled`, `done`.
`done` requires a baseline, all current checkpoints accepted and no unresolved
issues. Explicitly reactivate a completed task before revising its plan; rejected
revisions cannot leave unverified work marked done. A host restart, idle terminal or restored panel never completes or
reactivates a task.

```json
{"id":"T001-done","kind":"lifecycle","task":"T001","state":"done","next_action":"Hand the accepted result to the user"}
```

See `tests/test_work.py` for executable publication behavior and
`scripts/work-fixtures.py` for isolated, labeled panel scenarios. Keep fixtures
outside actual portfolios. The panel reads only snapshots and host observations;
it persists view selection and notification deduplication in Herdr shared state.

# Chief-of-staff portfolio

- Portfolio ID: <unique ID>
- Conversation ID: <identifier, or unavailable>
- Coordinator terminal: <literal HC_TERMINAL_ID>
- Owning core: <HC_TERMINAL_SOCKET>
- Mode: active
- Requested layout / capacity: <tab count, splits per tab or total, coordinator included, and host/session limit>
- Allowed harnesses/models/subscriptions: <user choices and verified current availability>
- Subscription headroom: <known allowance/reset/marginal charge per route, checked-at time, or unknown; separate from API cost>
- Dispatch paused: no
- Intake paused: no
- Next action: <specific action or waiting for user input>

## Backlog (in dispatch order)

| ID | Goal / repository | State | Priority / ordering reason | Dependencies | Record | Next action / blocker |
| --- | --- | --- | --- | --- | --- | --- |

## Live worker inventory (includes idle and blocked workers)

| Terminal ID / core | Tab / split | Task | Role | Harness / subscription / model / effort | Observed status | Worktree / resume ID |
| --- | --- | --- | --- | --- | --- | --- |

## Other owned resources

Record build/test terminals, shared services, integration targets and retained
artifacts. Do not treat unrecorded terminals as portfolio-owned.

## Decisions and transitions

Append intake, launch intents/results, priority changes, state transitions,
verification, cancellations and cleanup decisions. Include request references
when available to distinguish repeated delivery from an explicit new request.

## Handoff / recovery

List unfinished launch intents, task/table discrepancies, resources to reconcile
with hc/Git, user decisions needed, and the next safe action. Another coordinator
may take ownership only on explicit authorization; record the transfer.

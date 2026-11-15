---
name: review-security
description: Review requested trust-boundary changes for concrete security defects using a fresh independent security reviewer session when available.
---

# Security review

Follow [the independent review contract](../review/references/independent-review.md). This skill explicitly requests a fresh independent security agent when a supported delegation tool is available. In Codex, prefer the available project security reviewer or a new default agent with a focused security brief. Confirm the role and tool arguments exist before launching; do not invent a service integration.

Trace untrusted data across actual boundaries: authentication/authorization, input and path validation, serialization, injection, secrets, logs, and external calls. Report exploitable behavior with evidence, affected lines, severity, and a concrete repair. Scanner failures and missing coverage are incomplete verification, not a clean security result.

Remain read-only during review. Stop edits to the candidate while reviewing. Fix findings through the coordinator when authorized, then review the full updated change in a new session. Do not switch or stash a dirty checkout to review another branch; use an isolated checkout.

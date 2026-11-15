---
name: review
description: Review requested code changes for correctness, regressions, and missing verification using a fresh independent reviewer session when available.
---

# Review changes

Infer the requested review focus. Default to a general code review; use [security review](../review-security/SKILL.md) when explicitly requested or a trust-boundary change requires it. No mandatory menu is needed.

Follow [the independent review contract](references/independent-review.md). This skill explicitly requests a fresh independent agent for the review when a supported delegation tool is available. Use the real current role/tool, not a service name whose integration is absent. Never describe a generic agent review as Bugbot.

Findings must name severity, file/line, concrete behavior, evidence, and a proposed correction. Distinguish defects from optional improvements and list incomplete checks. An empty diff means nothing was reviewed. Fix findings when the user's review/fix task or active implementation loop authorizes repairs, then use a new reviewer for the next round.

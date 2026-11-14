---
name: chat-send
description: Prepare, preview, or send a Google Chat message to a configured route using the managed accounts browser.
---

Read only the relevant section of `~/projects/work/notes/.claude/communication-style.md` when authoring the message. Do not load the notes vault. Prepare version 1 text/code JSON using [the payload reference](references/payload.md), then invoke `chat-send --route ALIAS --message FILE` once. A draft request stops at preview. An explicit user request to send authorizes adding `--send --operation STABLE_ID` without a redundant approval round. Reuse that ID when checking or retrying this operation; identical intentional messages need different IDs.

The command uses only task-owned pages in the existing managed accounts browser. Corporate Google OAuth/API integration, gog, cookies, private endpoints, raw CDP, and browser/profile changes are outside this workflow. Do not replace the command's checks with improvised browser actions.

Report the bounded result and receipt path. `needs_attention` requires resolving the stated route, UI, draft, or mention problem. `uncertain` requires `chat-send status --operation ID`; never create a new ID to retry an uncertain send. Delivery through a browser is not exactly once. Default previews remain in a kept task for review. `chat-send cancel --operation ID` clears only an unchanged operation-owned draft and finishes that task. Required mentions need a configured group route and a verified identity chip; DM mentions stop before drafting. Literal names do not count.

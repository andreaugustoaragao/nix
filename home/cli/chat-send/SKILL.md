---
name: chat-send
description: Draft and send Google Chat messages through a minimal Terra/Pi worker, or deliver exact supplied text with the managed accounts browser.
---

For routine drafting from supplied facts, use `chat-send-task --route ALIAS --brief FILE --operation STABLE_ID`. This is the task-specific default: a fresh Pi session, WebAI `gpt-6.1-terra`, low effort, and only the fixed delivery tool. Put the recipient's name, requested action, relevant facts and exact code in a short self-contained brief. Keep research and source retrieval in the caller; do not give the worker the backlog, notes vault or full conversation. Read [the worker reference](references/worker.md) for lifecycle and private results.

An explicit user request to send authorizes `--send` without a redundant approval round. Otherwise the worker stops at preview. Reuse the operation ID to check status; never relaunch an uncertain operation under a new ID. Missing facts or a browser failure return to the caller for attention.

For exact supplied or already reviewed content, skip inference. Prepare version 1 text/code JSON using [the payload reference](references/payload.md), then invoke `chat-send --route ALIAS --message FILE [--attach FILE] [--send --operation STABLE_ID]`. An existing local file is snapshotted and uploaded directly (one file per message); do not turn it into a Drive link or ask a model to draft it. To send a worker preview after approval, use its returned payload and the same operation ID with this deterministic command. Read only the relevant section of `~/projects/work/notes/.claude/communication-style.md` when the caller needs additional writing guidance.

The command uses only task-owned pages in the existing managed accounts browser. Corporate Google OAuth/API integration, gog, cookies, private endpoints, raw CDP, and browser/profile changes are outside this workflow. Do not replace the command's checks with improvised browser actions.

Report the bounded result and receipt path. `needs_attention` requires resolving the stated route, UI, draft, attachment, or mention problem. `uncertain` requires `chat-send status --operation ID`; never create a new ID to retry an uncertain send or upload. Delivery through a browser is not exactly once. Default previews remain in a kept task for review. `chat-send cancel --operation ID` clears only an unchanged operation-owned draft, including its own settled attachment chips, and finishes that task. Required mentions need a configured group route and a verified identity chip; DM mentions stop before drafting. Literal names do not count. Local attachment receipts bind name, size, and sha256; they do not claim remote byte hashes.

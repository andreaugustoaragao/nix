Create a private UTF-8 brief, at most 16 KiB. Include only supported facts and the requested message. The worker cannot research, read files, execute code, select a different destination, or grant itself permission to send. It adds no test label; include one in the brief when sending a test. The sender adds the plain `- sent by Fulcrum` signature.

```sh
chat-send-task --route ALIAS --brief /private/brief.txt --operation STABLE_ID
```

Add `--send` only for a user-authorized send. Preview is the default. For a verified group mention, add `--mention-email person@example.com --mention-query Person`; these values are fixed outside the model. Required DM mentions stop before starting the model. Use the same private `--routes-file FILE` and `--state-dir DIR` options as `chat-send` when selecting isolated configuration/state.

Invoke this command directly from the caller's shell; it already creates a named watchable Herdr Pi terminal, so do not wrap it in another `hc run`. Pi and Herdr must already be installed and WebAI authenticated; the command reports a missing runtime instead of installing or reconfiguring it.

The command launches a fresh interactive Pi session with `litellm/gpt-6.1-terra`, low effort, a compact system prompt and only `deliver_message`. It disables context files, other extensions, MCP, built-in tools, skills and prompt templates. Before sending the brief, it verifies the exact model, provider, system prompt and tool list. Output is capped at 2,048 tokens per request, with at most 4 model requests and a bounded worker deadline. The tool ends the model turn after its receipt, avoiding an extra model summary.

The selected route is snapshotted privately before launch. Recipient, mention, operation and send permission never come from model arguments. A durable job reservation prevents an unknown launch being repeated. A separate durable tool latch permits only one sender invocation, with one read-only status call after uncertainty. The sender retains its own permanent submit marker. Neither worker restarts nor status checks can issue another submission after that marker.

Results include the original native receipt, generated payload, worker job path and raw per-response usage. Jobs live under `STATE_DIR/.workers/OPERATION/` with private permissions. Gateway cost is reported only when present for every model request; missing cost is unknown. Zero placeholders in Pi's catalog are not prices. The reported cost covers worker inference, excluding the caller and browser infrastructure.

Use `chat-send-task status --operation STABLE_ID` for the original operation. Reusing identical create arguments also checks that operation instead of launching Pi again. Changed route, brief, mention or preview/send permission under the same ID is refused. To send an approved preview, call `chat-send` with the returned payload, the same route snapshot, state directory and operation ID; no new model is needed. `chat-send-task cancel --operation STABLE_ID` clears only a matching owned draft through the native sender. Retain all job and sender state after uncertainty.

Browser crash recovery may need coordinator intervention. Inspect the original operation and escalate without changing IDs, re-clicking Send or silently switching models. This profile is the default for routine Chat composition and delivery; substantial research and unrelated coding retain their existing model routes.

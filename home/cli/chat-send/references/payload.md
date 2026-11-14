Create payload files privately (`umask 077`). Example:

```json
{"version":1,"operation_id":"followup-20261114-01","blocks":[{"type":"text","text":"Here is the command:"},{"type":"code","language":"sh","text":"pwd\nprintf '%s\\n' hello"}]}
```

`text` blocks contain plain Chat Markdown, `code` blocks preserve their exact text. The optional `language` field is hint metadata only; Chat receives bare code fences because it renders fence language tags as literal code. Code cannot contain triple backticks; supply nonempty blocks with LF line endings. The CLI adds one final plain `- sent by Fulcrum` signature. A standalone signature supplied in a text block is removed before that addition. Signature text inside code is preserved. HTML is never inserted. Formatting must settle to matching displayed text/code before sending; unsupported Markdown or formatting stops.

A send needs a stable `operation_id` in the payload or `--operation ID`. Preview can generate one; use that returned ID when sending the same payload. Optional `mention` is `{"email":"other@example.com","query":"Other"}`, with optional exact `user_id` and `member_id`. Queries contain 2–24 letters/digits. Group routes select a unique matching real chip and verify surrounding content, code, signature, and published chip identity. DM mentions stop before drafting because selection is unreliable. Interrupted or ambiguous chip selection stops without sending.

Routes live in a private JSON file, default `$XDG_CONFIG_HOME/chat-send/routes.json` (or `~/.config/chat-send/routes.json`); use `--routes-file FILE` to select another. Set directory mode 0700 and file mode 0600. No corporate IDs belong in Nix source. Configure an exact title/account label observed in the managed browser, for example:

```json
{"version":1,"routes":{"example":{"url":"https://chat.google.com/app/chat/EXAMPLE","title":"Example Person - Chat","account":"person@example.com","account_label":"Google Account: Example Person (person@example.com)"}}}
```

Routes default to `"kind":"dm"`. Add `"kind":"group"` only for an independently verified group conversation to enable real mention selection. Only canonical Chat conversation URLs are accepted. The command does not discover recipients or guess accounts. Browser profile unavailability returns bounded diagnostics without reconfiguration. Runtime state defaults to `$XDG_STATE_HOME/chat-send` (or `~/.local/state/chat-send`); `--state-dir DIR` allows an isolated location. Payload copies, receipts, and screenshots are private. Stdout contains no message or chat history. Exit codes: 0 preview/sent/cancelled; 2 needs_attention; 3 uncertain; 1 failed. Cancellation is reported as outcome `preview`, reason `cancelled`.

Use `chat-send status --operation ID` to inspect a preview or reconcile an attempted send. It never sends. Retain state after uncertainty: deleting it discards the retry protection. Browser publication evidence has UI-specific limits; the coordinator must validate the DOM probe against the current live UI before enabling a new shape.

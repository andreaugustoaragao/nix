---
name: email-send
description: Draft, preview, or send work emails via Gmail with zero, one, or multiple attachments from aragao@avaya.com using the deterministic email-send CLI.
---

# Email Send

Use the installed `email-send` CLI for all Gmail compose, preview, and send tasks. Do not hand-drive Gmail compose, recipient chips, attachment uploads, or Sent-folder checks across manual browser turns.

## Command

```bash
email-send \
  --to "<name or email>" \
  [--cc "<name or email>"] \
  [--bcc "<name or email>"] \
  --subject "<subject>" \
  --body "<plain-text body>" \
  [--attach "/abs/path/file1.png:clean-name.png"] \
  [--attach "/abs/path/file2.pdf:report.pdf"] \
  [--operation "<unique-stable-id>" --state-dir "${XDG_STATE_HOME:-$HOME/.local/state}/email-send"] \
  [--send]
```

Use `--body-file <path>` (or `--body-file -` for stdin) instead of `--body` for multi-paragraph messages when shell quoting would be noisy.

## Multiple Attachments

- Repeat `--attach` once per file (`--attach /path/a.png --attach /path/b.pdf --attach /path/c.csv`). There is no single-attachment limit beyond Gmail's own message-size cap.
- Append `:display-name.ext` (`--attach "/tmp/pasted.png:pier-location-change.png"`) to give raw pasted or temp files clean recipient-facing filenames. Duplicate display names are automatically disambiguated (`name-2.ext`).
- If an attached image arrives via a harness-internal path (such as `local://pasted-image-*.png`), copy it to a concrete path in `/tmp/` first, pass that path to `--attach`, and delete the temporary copy after the send receipt returns.
- Upload local files directly as attachments; do not convert them to Drive links unless Andre asks for Drive links.
- Every attachment is hashed (SHA-256) and verified both in the Compose dialog (settled with no active progress bar) and by exact filename on the opened sent message (`[download_url]` / `span.aV3`).

## Recipients & Account Safety

- `--to`, `--cc`, and `--bcc` are repeatable and accept comma-separated values.
- Each entry may be a literal email address or a person name resolved from `~/projects/work/notes/people/*.md` (override with `--vault-root`; supports exact, prefix, and minor typo matching; fails closed on ambiguity).
- `--account` defaults to `aragao@avaya.com` and fails closed if the managed `accounts` browser profile is signed into a different account or logged out.
- Before clicking Send, the CLI verifies exact subject, normalized body text, and exact per-field `To`/`Cc`/`Bcc` chip sets (preventing missing recipients, extra recipients, or `Bcc`→`To` leaks).

## Preview, Send Authorization & Idempotency

- **Default is dry-run preview** (omit `--send`): runs the full Gmail compose and attachment upload verification, discards the draft (unless `--keep-draft` is passed), and prints a JSON receipt with `status: "dry_run"`.
- **Pass `--send` only when Andre explicitly authorizes sending** (e.g., "send this email"). Otherwise stop at preview and present the draft + attachment list for approval.
- **Always pass a unique, stable `--operation <id>` and `--state-dir "${XDG_STATE_HOME:-$HOME/.local/state}/email-send"` on every `--send`** (for example `--operation pier-location-20261124`). Storing receipts under `$XDG_STATE_HOME/email-send` (`0700`/`0600`, matching the CLI default) keeps private email bodies, recipients, and attachment paths outside any Git repo. Keep both `--state-dir` and `--operation` identical across retries.
  - The CLI atomically reserves the operation (`reserved` → `dispatching` immediately before clicking Send → `sent` or `uncertain` on post-click failure).
  - Re-running a `sent` `--operation` returns the stored receipt without resending.
  - An `uncertain` operation fails closed: inspect Gmail Sent manually before acting. Never mint a new `--operation` ID or switch `--state-dir` to blindly retry an `uncertain` send.

## Voice & Tone

- When drafting or polishing Andre's prose, follow `~/projects/work/notes/.claude/communication-style.md` (when available): plain language, direct lead, natural contractions, concise paragraphs, no filler, no em dashes.
- Do **not** append `- sent by Fulcrum` to emails (that signature applies strictly to Google Chat).

## Reporting

Only report an email as sent when the CLI exits `0` with `"status": "sent"` and `"verified_in_sent": true`. Report recipients (`to`, `cc`, `bcc`), `subject`, every attachment's display name and byte size, `sent_message_id` / `sent_message_url`, and the exact sent body.

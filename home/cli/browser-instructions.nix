''
  # Browser control

  Use `browser-task` for browser work. It manages two persistent profiles:
  `accounts` for signed-in services and `development` for local apps, test
  accounts, and frontend checks. Each has its own browser process and data.
  Never auto-discover a browser or attach to the everyday browser. Desktop
  services are configured on Linux; their presence on macOS is not assumed.

  Start with `browser-task start ROLE --label "short task description"`
  (optionally `--url URL`) and retain the returned task UUID. Reuse that task
  while working. `browser-task list` and `browser-task info TASK` inspect
  ownership and state. Create additional pages with
  `browser-task open TASK --page NAME [--url URL]`.

  For browser navigation, reading, clicking, filling, and screenshots, use
  the `dev_browser` tool in Codex and Pi with `task`, `action`, optional
  `page` (default `main`), and optional `timeout` (default 30 seconds).
  Other clients send one JSON action on stdin:

  `printf '%s\n' '{"type":"snapshot"}' | browser-task action TASK --page main --timeout 30`

  Actions include `navigate`, `snapshot`, `evaluate`, `click`, `fill`, `key`,
  `wait`, `scroll`, `viewport`, and `screenshot`. Read the tool schema or run
  `browser-task schema` for their exact arguments. A snapshot returns live
  opaque refs. Use a ref or a unique accessible role and name for `click`,
  `fill`, and `wait`. Take a new snapshot after navigation or page changes;
  a later snapshot or navigation invalidates earlier refs. Inspect page
  state before retrying a failed action.

  `evaluate` accepts a synchronous JavaScript expression in the owned page
  and returns its value. It has no host bindings or host filesystem API.
  Page globals remain until navigation. Do not pass a Promise or use it for browser navigation or
  input. Use typed actions for those operations. The native tool does not
  expose persistent console or network event listeners. Use a screenshot
  action to inspect layout and styling. It returns a private PNG artifact
  path. Capture the screenshot before keeping the task.
  Never create or select tabs through raw browser, CDP, or controller APIs.
  Preserve unrelated, manually opened, and login tabs.

  Run `browser-task finish TASK` only when the browser work is complete.
  Completed task pages remain for one hour, then cleanup closes only those
  registered pages. An action ending, idle time, and an agent turn ending
  do not mean the task is complete. Active tasks have no expiry.

  For user review or a handoff, capture a screenshot, then run
  `browser-task keep TASK` to protect the task indefinitely. Both managed
  profiles are headless, so `show` is unavailable. Interactive login needs
  a deliberate headed profile configuration and rebuild by the operator.
  Use `browser-task resume TASK` before further automation or `finish` on
  a kept task. Resume completed tasks before continuing them as well.

  If a managed profile or task is unavailable, report the specific failure.
  Do not fall back to an everyday browser, install browsers, or change its
  profile or launch flags. Fulcrum's built-in browser is separate from this
  workflow.
''

# Use background browsers for agent tasks

## Activate the configuration

Rebuild the Linux desktop host:

```sh
sudo nixos-rebuild switch --flake /home/aragao/projects/personal/nix#$(hostname)
```

Log out and back in to load the compositor rules and start both browser services.
Restart your coding-agent sessions to load the updated instructions and tool schemas.
Restart everyday Brave and Chrome when convenient to remove their previous debugging flags.

Check the services:

```sh
systemctl --user status agent-browser-accounts agent-browser-development agent-browser-cleanup.timer
```

Both browsers run headless by default. When you ask to see a browser for sign-in, the agent temporarily switches that profile to a real Chromium window:

```sh
agent-browser-mode accounts visible
```

The command returns JSON with a `config` path and a `restarted` flag. A mode change restarts that profile's browser with the same cookies and storage, starting a clean window without restoring previous tabs. After a restart, the agent starts a new task at the application's URL because old task IDs are stale.

The agent focuses the sign-in page with the returned configuration:

```sh
browser-task --config CONFIG_PATH show TASK --page main
```

Sign in directly in Chromium, then tell the agent to continue. The agent restores headless operation with:

```sh
agent-browser-mode accounts headless
```

Both modes use temporary overrides under `$XDG_RUNTIME_DIR`. The Nix defaults stay headless. Repeating the current mode does not restart an already running browser. Use `development` instead of `accounts` for test applications.

If you explicitly request **Browser assistance**, the agent can open the native screenshot app instead:

```sh
browser-task assist TASK --page main --prompt "Sign in to the test app, then return control."
```

The native Rune window displays the current domain, page URL, and screenshot. Click the screenshot, scroll, use keyboard navigation, or select a discovered field and enter a value in **Private input**. **Send input to page** fills the selected field or types into the focused page element. Discovered buttons and links update after each action. Screenshots refresh automatically every two seconds while you are not editing; turn that off or refresh manually when needed.

Agent actions and task lifecycle changes are blocked for the whole handoff. Choose **Return control to agent** when finished. **Keep paused** or closing the window keeps the task protected; the agent must explicitly resume it later. If the app crashes, run `browser-task assist-cancel TASK`, then inspect and resume the task. This never closes its tabs.

Input values pass through local pipes and are not written to the task registry, command arguments, or agent transcripts. Assistance screenshots stay in memory. The live website still receives entered values, and the agent can inspect the page again after you return control. Requests are bound to the page document and origin; a redirect requires a fresh screenshot before more input.

Google may reject automated browsers. CAPTCHAs can be handled visually when supported by the page, but browser/OS dialogs, passkeys, and security keys may need a separate supported sign-in method. The app does not bypass provider restrictions or adopt unrelated popups. OAuth API access does not create a signed-in browser session.
Use test accounts in development.
The profiles keep separate cookies and storage. Closing a task's tabs preserves its profile's login sessions.
These profiles run as your desktop user. They are not a security sandbox against other processes running as you.
Fulcrum continues to use its own built-in private browser and sign-in controls.

## Give an agent browser work

Describe the task normally. Codex, Pi, Claude, and OpenCode receive the same routing instructions.
Requests to inspect an app you develop use `development`. Requests involving signed-in services use `accounts`.
Specify the profile in your request when the distinction is ambiguous.

To configure another agent client, include the policy from
[`home/cli/browser-instructions.nix`](../home/cli/browser-instructions.nix)
in that client's persistent instructions and make `browser-task` available on its PATH.

An agent starts a task and retains the returned UUID:

```sh
browser-task start development --label "Inspect checkout" --url http://localhost:3000
```

Codex and Pi use the `dev_browser` tool. It accepts `task`, `action`, optional `page`, and optional `timeout`. Read its schema for the action arguments. Other clients send one JSON action through the CLI:

```sh
printf '%s\n' '{"type":"snapshot"}' | browser-task action TASK --page main --timeout 30
```

Replace `TASK` with the UUID. The snapshot includes opaque refs for live elements. Use a ref or a unique accessible role and name for `click`, `fill`, and `wait`. For example:

```sh
printf '%s\n' '{"type":"click","target":{"role":"button","name":"Continue"}}' \
  | browser-task action TASK --page main --timeout 30
```

Take a new snapshot after navigation or page changes. A later snapshot or navigation invalidates earlier refs. `evaluate` runs one synchronous JavaScript expression in the owned page and returns its value. It has no host bindings or host filesystem API and rejects Promise results. Page globals remain until navigation. Capture a screenshot to inspect a page. The action returns a private PNG artifact path:

```sh
printf '%s\n' '{"type":"screenshot","full_page":true}' \
  | browser-task action TASK --page main --timeout 30
```

Create additional task pages through the helper:

```sh
browser-task open TASK --page comparison --url http://localhost:3000/cart
```

Finish the task after the browser work is complete:

```sh
browser-task finish TASK
```

## Inspect and keep a result

List tasks and capture a screenshot of the page you want to inspect:

```sh
browser-task list
printf '%s\n' '{"type":"screenshot","full_page":true}' \
  | browser-task action TASK --page main --timeout 30
```

Capture the screenshot before keeping the task. Run `browser-task keep TASK` to protect it indefinitely. Kept tasks block further automation until resumed. To see a real browser window, ask the agent to switch that profile temporarily with `agent-browser-mode`, then use `browser-task --config CONFIG_PATH show TASK --page main`.

To continue the agent's work or start a new cleanup deadline:

```sh
browser-task resume TASK
browser-task finish TASK
```

## Manage leftover tabs

Completed task tabs close on the first minute tick at least one hour after `finish`.
Repeating `finish` preserves the original deadline. Cleanup does not clear cookies or close other tasks' tabs.
Active tasks, kept tasks, manually opened tabs, and unregistered popups have no expiry.

If an agent abandons an active task, inspect it with `browser-task info TASK` and finish it when its work is complete.
Close unwanted manual tabs or popups in the browser. The helper deliberately does not infer their ownership.

After a browser restart, start a new task. Old task IDs cannot adopt restored tabs.
Cleanup discards expired records from the old browser instance without closing tabs in the new one.
Inspect any restored tabs manually.

To run eligible cleanup immediately or inspect service failures:

```sh
browser-task cleanup
journalctl --user -u agent-browser-accounts -u agent-browser-development -u agent-browser-cleanup
```

If an action is interrupted, inspect its task before resuming. The helper keeps the task and recovers or fences uncertain work during `resume`.
If an interrupted click, fill, or key action cannot be confirmed complete, close that task page before resuming. Use a new page name for its replacement.
If a managed browser is unavailable, restore its service. Do not attach an agent to your everyday browser as a fallback.

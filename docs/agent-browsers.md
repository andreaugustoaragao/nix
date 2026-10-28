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

Both browsers run headless, with no desktop windows or launcher entries.
Use screenshots to inspect their pages. To sign in interactively or renew a login, set that profile's `headless` field to `false` in `pkgs/browser-profiles.nix`, rebuild, and restart its browser service. The headed profile regains its launcher and compositor workspace. A restart requires new task IDs because old IDs cannot adopt restored tabs.
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

Capture the screenshot before keeping the task. Run `browser-task keep TASK` to protect it indefinitely. Kept tasks block further automation until resumed. `show` works only for profiles configured as headed; the default headless profiles return screenshot guidance without changing task state.

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

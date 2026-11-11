# Browser assistance

A native Rune window for signing in and interacting with managed agent browser
pages. Agents open it with:

```sh
browser-task assist TASK --page main --prompt "Sign in, then return control."
```

Open **Browser assistance** from the desktop launcher to select an active task,
or run `nix run .#browser-assist` before activation. To open a specific page:

```sh
nix run .#browser-assist -- --task TASK --page main
```

The screenshot accepts clicks, wheel scrolling, and keyboard navigation. Type
into **Private input**, then choose **Send input to page**. Select a discovered
field to replace its contents, or click a field in the screenshot to type into
its current selection. Page buttons and links also appear beside the screenshot.
All private input is masked, including email addresses and verification codes.

Screenshots refresh after actions and every two seconds while no input is being
edited. Choose **Refresh screenshot** after an external approval or redirect.
Refreshing clears an unfinished input to avoid sending it to a different field.
The app refuses input when the document or website origin has changed.

Choose **Return control to agent** to continue automation. Closing the window or
choosing **Keep paused** leaves the task kept. If the app crashes, cancel the
handoff with `browser-task assist-cancel TASK`, then inspect and explicitly resume
the task. Cancelling does not close pages. An interrupted input may require the
existing browser-task recovery procedure.

The browser-task registry owns the handoff and serializes all browser actions.
The Rune app uses its private assistance protocol over subprocess pipes. The
public agent tool cannot call the screenshot-coordinate or private-input actions.
Older browser-task versions reject the assistance task state, so they cannot
accidentally run actions while this window has control.

Input values stay out of task records, command arguments, and agent transcripts.
Assistance screenshots stay in memory. The website receives your input, and the
agent can inspect the page again after you return control. These processes run
as your user and are not isolated from other processes with the same user ID.

The app operates on the selected registered page. It does not adopt unrelated
popups or expose browser and operating-system dialogs. Google may reject an
automated browser; passkeys and security keys may need a different supported
sign-in method.

## Verify

```sh
nix develop .#browser-assist --command cargo test \
  --manifest-path home/desktop/browser-assist/Cargo.toml
nix build .#browser-assist
python3 pkgs/browser-task/tests/assistance.py /path/to/browser-task \
  --app /path/to/browser-assist
```

The live check uses disposable tasks on the managed development profile and a
local fixture. It verifies control isolation, document and origin binding,
private input, screenshots, field and button discovery, and recovery. With `--app`, it also enters a fixture value through the packaged
Rune controls and checks that closing the window keeps the task paused. Rune
unit tests verify native controls and screenshot coordinate mapping.

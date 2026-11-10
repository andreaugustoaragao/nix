# Pi browser-task companion

A small user-facing `/browser` command and persistent widget for the existing
managed `browser-task` service. No new browser runtime or model-callable tool.

## Try without rebuilding

From this repository, launch a preview session:

```sh
pi -e ./home/cli/pi-extensions/browser-companion/index.ts
```

Enter `/browser` for the picker, or `/browser start` to create a task. Escape
cancels a dialog. After selecting a task, the widget remains above the editor.
Commands execute directly without calling a model.

`home/cli/pi.nix` installs this directory globally through Home Manager on the
next rebuild. After installation, use plain `pi` (do not also pass `-e`, which
would load the extension twice). An existing Pi session needs `/reload` after
the Nix activation. Edit these source files, not the deployed symlink.

## Commands

| Command | Effect |
| --- | --- |
| `/browser` | Pick a task if none is selected, then choose one action |
| `/browser pick` | List registry tasks; selection is explicit |
| `/browser start` | Choose development/accounts, a label, and an initial URL |
| `/browser use UUID` | Select a task by its full lowercase UUID; does not resume |
| `/browser info` | Refresh registry state and list registered page names |
| `/browser page` | Select a registered page without navigating |
| `/browser open` | Create a new named page on the selected active task |
| `/browser screenshot` | Capture the selected active page to a private PNG |
| `/browser keep` | Confirm, capture the selected page, then keep the task |
| `/browser resume` | Confirm resumption; existing snapshot refs become invalid |
| `/browser finish` | Confirm completion of an active task; enter CLI retention |
| `/browser forget` | Clear the widget/selection; do not change the browser task |
| `/browser help` | Show command help |

Blank initial/page URLs open `about:blank`. Only HTTP(S) URLs without embedded
credentials are accepted. Both managed profiles are headless. Screenshots
remain private artifacts; the companion reports their paths, not inline images.
`keep` captures the selected page, not every registered page.

## Safety and persistence

- Selecting a task is not an exclusive ownership lock. Other workflows can use
  it; inspect the label and full UUID before choosing lifecycle actions.
- Registry info is not a live page-health check. A browser restart, closed page,
  unavailable service, or screenshot timeout is reported by the actual action.
- Lifecycle commands refuse to run while Pi's agent is busy. Within the
  companion, commands are serialized. This does not lock other processes.
- State-changing lifecycle actions require confirmations. Kept or finished
  tasks must be explicitly resumed before automation; kept tasks cannot finish.
- A failed screenshot never invokes `keep`. Errors refresh registry state
  because the service may have protected an interrupted task as `kept`.
- Session shutdown/reload never finishes, keeps, or closes browser tasks.
- Selection and last screenshot path persist as branch-relative custom Pi
  entries, which do not enter model context. Restore only refreshes registry
  state; it never resumes or recreates a task.
- Native `dev_browser` screenshot results update the widget only when their
  explicit task UUID matches the selected task.
- No polling, raw CDP, everyday-browser attachment, Orca browser control, profile
  changes, automatic navigation, or credential entry. Use `dev_browser` for
  snapshots/navigation/input; obtain a fresh snapshot after resuming.
- CLI subprocesses use argument arrays and bounded output/deadlines, never a
  shell. No automatic retries after uncertain operations.

RPC clients with extension UI support can use the same dialogs and widget.
Print/JSON mode cannot run the command because no user confirmation UI exists.

## Tests

Requires Node 22.19+ (matching Pi). Tests use mock registry/UI state and never
connect to browser profiles:

```sh
node --experimental-strip-types --test \
  home/cli/pi-extensions/browser-companion/companion.test.ts
```

# Noctalia NixOS rebuild button

The `aragao/nix-rebuild:rebuild` widget sits beside the control-center button on
primary and secondary bars. It is visible only when
`~/projects/personal/nix` has staged, unstaged, or untracked Git changes. Ignored
files do not count. It polls without taking Git's optional index lock.

## Use

- **Left-click:** start one rebuild job. The label changes from Rebuild to
  Starting, Building, then Applying. Repeated clicks and clicks on another
  monitor cannot start a second job.
- **GUI authentication:** after the unprivileged build succeeds, the existing
  compositor Polkit agent asks for administrator authentication. Cancel to
  leave the built closure unapplied. No terminal or password collection by the
  plugin is involved, and no passwordless rule is added.
- **Right-click:** open the captured log in a graphical text dialog. Reopen the
  dialog to refresh its snapshot while a job is still running.
- A desktop notification reports success, cancellation, or failure. An
  activation error may be partial; inspect the log and current system rather
  than assuming everything rolled back.

The button remains visible after success while Git remains dirty. Rebuilding
never commits, stages, stashes, or resets the checkout. Nix flakes exclude
untracked files until they are staged; review and stage intended new files
before clicking. The operation applies all tracked changes in the checkout,
not only the changes from a particular agent or task. Committing changes hides
the button even if they have not been applied: visibility is Git dirtiness,
not an indicator that the active system matches the repository.

## Execution and authentication boundary

`noctalia-nix-rebuild start` starts a singleton transient user systemd unit,
independent of Noctalia's service. It uses the installed immutable helper and
configuration. The job can survive a Noctalia restart during activation.

The helper builds as the logged-in user:

```text
nix build --json --no-write-lock-file --print-build-logs --out-link <state>/result \
  <checkout>#nixosConfigurations.<host>.config.system.build.toplevel
```

Only after a successful build returning one system closure for that host does
it request normal Polkit authorization:

```text
pkexec --disable-internal-agent <installed nixos-rebuild> switch \
  --store-path <built closure> --no-reexec
```

`--store-path` is supported by the pinned nixos-rebuild-ng. The privileged
phase activates the exact closure already built, rather than reevaluating a
mutable checkout. The internal terminal authentication fallback is disabled;
if no GUI agent is available or authorization fails, the job reports a failure
and retains its log. The existing NixOS Polkit administrator policy is used
without adding grants or changing sudo settings.

Private status, log, and last-build GC root are retained under
`${XDG_STATE_HOME:-$HOME/.local/state}/noctalia-nix-rebuild/`. Status reconciles
recorded progress with the actual unit; an interrupted job is not reported as
successful. An unavailable user systemd manager disables starting, rather than
risking a duplicate job.

## Installation and verification

One initial declarative activation installs the helper and new widget. Existing
Noctalia runtime/recovery overrides are not removed or changed by this feature.
The configuration must be loaded by the active shell before the new button can
appear.

Tests use disposable Git repositories and fake subprocess results to exercise
build/authentication boundaries, cancellation, activation failure, duplicate
launches, status recovery, and the graphical log command. They execute the real
Luau widget against a mock Noctalia host. They do not authenticate or activate
the real system. The existing toolbar suite verifies placement and preservation
of the other controls and typography.

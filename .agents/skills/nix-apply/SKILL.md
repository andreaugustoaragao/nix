---
name: nix-apply
description: Apply this Nix repository's configuration to the current NixOS or macOS (nix-darwin) desktop host, using a native GUI authentication dialog for privileged activation. Use when the user asks to apply, rebuild, or switch the system with graphical authentication.
---

# Apply Nix with GUI authentication

Select the installed helper for the current OS:

- **NixOS (`Linux`):** `noctalia-nix-rebuild` — builds as the normal user, then
  uses Polkit (`pkexec --disable-internal-agent`) to activate the exact built
  closure via a transient `systemd --user` unit.
- **macOS / nix-darwin (`Darwin`):** `darwin-nix-rebuild` — builds as the normal
  user, then invokes macOS's native SecurityAgent GUI dialog (`osascript`
  `with administrator privileges`, supporting Touch ID / password) to activate
  the exact built closure via an immutable Nix-store activator.

Both helpers run independently of the agent and desktop shell so activation can
restart services without losing the rebuild job.

An explicit request to apply the current changes authorizes this workflow;
do not ask for the same approval again. Creating or reading this skill alone
does not authorize a rebuild. This workflow targets the local desktop host
(NixOS or macOS), not remote hosts.

## Start or join the job

1. Reuse passing checks from the current task; run any missing project-required
   checks before starting. Preserve unrelated user changes. Stage intended new
   files as the project requires; do not commit, stash, or reset anything.
2. Run `<helper> status` (`noctalia-nix-rebuild status` on Linux,
   `darwin-nix-rebuild status` on macOS). Check that `repository` identifies
   this checkout. A rebuild includes all tracked working-tree changes, not only
   this task's diff. If `busy` is true, monitor that job rather than starting
   another. A previous `done` status does not mean newer edits are applied.
3. Check that the graphical session is available:
   - **Linux:** confirm the graphical session and Polkit agent are running:

     ```sh
     systemctl --user is-active graphical-session.target
     ps -eo comm,args | rg '[h]yprpolkitagent|[p]olkit.*agent'
     ```

   - **macOS:** confirm the current session is the interactive Aqua GUI session:

     ```sh
     launchctl managername  # must print Aqua
     ```

4. Run `<helper> start` once. Read the returned `started` and `busy` fields,
   then check status. The helper does not start a new rebuild when Git is clean;
   report that result without making dummy changes.

Use the helper's installed configuration and entry point. If it is missing
(e.g. before the first activation that installs it), points at another
checkout, or lacks a working GUI authentication session, identify that specific
problem instead of substituting terminal sudo or changing authentication policy.

## Monitor and authenticate

Poll `<helper> status` at sensible intervals and keep the user informed.
`building` means an unprivileged build; `applying` means the helper has reached
GUI authorization or activation. Read the returned `log` path with focused reads
or `<helper> log`.

Tell the user when authentication is ready. Let them enter the password (or use
Touch ID on macOS) in the system's GUI dialog. Never collect credentials in chat
or tools, use `sudo -S`, or enable passwordless access.

- On **Linux**, `pkexec --disable-internal-agent` cannot fall back to a terminal
  prompt; Polkit controls whether cached authorization requires a new prompt.
- On **macOS**, `osascript ... with administrator privileges` opens the native
  SecurityAgent dialog (no terminal fallback). Cancelling returns `-128`, which
  the helper records as `phase = "cancelled"`.

Continue independent work while authentication is pending. Do not launch
duplicate jobs or bypass a cancelled or rejected authorization. If the job
reports `cancelled`, stop this application attempt. For `failed` or
`interrupted`, inspect the log and actual system state before considering a
retry; activation failures can be partial.

## Verify the applied result

After `phase` becomes `done` and `busy` is false:

- Compare `readlink -f /run/current-system` with the status JSON's `system`.
- Check the changed installed files, relevant services, and live behavior
  where practical. A successful build alone does not prove activation or
  that a running application loaded new configuration.
- Report what is active, any remaining restart or login requirement, and
  any failure or cancellation. Git dirtiness is not activation status.

Linux implementation: `home/desktop/noctalia-nix-rebuild.{nix,py}` (`docs/noctalia-nix-rebuild.md`).
macOS implementation: `home/cli/darwin-nix-rebuild.{nix,py}`.

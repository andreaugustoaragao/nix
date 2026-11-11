---
name: nix-apply
description: Apply this Nix repository's configuration to the current NixOS desktop host, using a GUI password dialog for privileged activation. Use when the user asks to apply, rebuild, or switch the system with graphical authentication.
---

# Apply Nix with GUI authentication

Use the installed `noctalia-nix-rebuild` helper. It builds as the normal user,
then uses Polkit to activate the exact built closure. It runs independently
of the agent and Noctalia, so activation can restart desktop services without
losing the rebuild job.

An explicit request to apply the current changes authorizes this workflow;
do not ask for the same approval again. Creating or reading this skill alone
does not authorize a rebuild. This workflow targets the configured local
NixOS desktop, not remote hosts or nix-darwin.

## Start or join the job

1. Reuse passing checks from the current task; run any missing project-required
   checks before starting. Preserve unrelated user changes. Stage intended new
   files as the project requires; do not commit, stash, or reset anything.
2. Run `noctalia-nix-rebuild status`. Check that `repository` identifies this
   checkout. A rebuild includes all tracked working-tree changes, not only
   this task's diff. If `busy` is true, monitor that job rather than starting
   another. A previous `done` status does not mean newer edits are applied.
3. Check that the graphical session and its configured Polkit agent are
   running. Use focused service/process queries, for example:

   ```sh
   systemctl --user is-active graphical-session.target
   ps -eo comm,args | rg '[h]yprpolkitagent|[p]olkit.*agent'
   ```

4. Run `noctalia-nix-rebuild start` once. Read the returned `started` and
   `busy` fields, then check status. The helper does not start a new rebuild
   when Git is clean; report that result without making dummy changes.

Use the helper's installed configuration and entry point. If it is missing,
points at another checkout, or lacks a working GUI authentication agent,
identify that specific problem instead of substituting terminal sudo or
changing authentication policy.

## Monitor and authenticate

Poll `noctalia-nix-rebuild status` at sensible intervals and keep the user
informed. `building` means an unprivileged build; `applying` means the helper
has reached GUI authorization or activation. Read the returned `log` path
with focused `pi-rs read --grep` queries or `pi-rs log`. For service failures:

```sh
systemctl --user show noctalia-nix-rebuild.service \
  -p ActiveState -p SubState -p ExecMainStatus --no-pager
```

Tell the user when authentication is ready. Let them enter the password in
the system's GUI dialog. Never collect credentials in chat or tools, use
`sudo -S`, or enable passwordless access. The helper invokes
`pkexec --disable-internal-agent`, so it cannot fall back to a terminal
password prompt. Polkit controls whether cached authorization requires a
new prompt; do not claim to have observed a dialog from status alone.

Continue independent work while authentication is pending. Do not launch
duplicate jobs or bypass a cancelled or rejected authorization. If the job
reports `cancelled`, stop this application attempt. For `failed` or
`interrupted`, inspect the log and actual system state before considering
a retry; activation failures can be partial.

## Verify the applied result

After `phase` becomes `done` and `busy` is false:

- Compare `readlink -f /run/current-system` with the status JSON's `system`.
- Check the changed installed files, relevant services, and live behavior
  where practical. A successful build alone does not prove activation or
  that a running application loaded new configuration.
- Report what is active, any remaining restart or login requirement, and
  any failure or cancellation. Git dirtiness is not activation status.

The helper is implemented in `home/desktop/noctalia-nix-rebuild.py` and
packaged by `home/desktop/noctalia-nix-rebuild.nix`.
See [the rebuild documentation](../../../docs/noctalia-nix-rebuild.md) when
diagnosing its build, authentication, log viewer, or status behavior.

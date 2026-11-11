---
name: nix-update
description: Update this repository's flake inputs and lockfile, resolve update-related compatibility failures, and validate the NixOS and nix-darwin configurations. Use for flake updates or refreshing locked inputs; system activation is a separate nix-apply workflow.
---

# Update flake inputs

Update the requested inputs in this checkout and leave a validated, reviewable
diff. A request to update flakes authorizes updating their locks and fixing
compatibility issues caused by that update. Creating this skill alone does
not request another update. Do not activate the system unless the user also
asks to apply it.

## Update within the configured pins

- Inspect Git status, `flake.nix` inputs and their comments, and `flake.lock`.
  Save the working lockfile to a unique scratch path under `/tmp` before
  changing it. Existing uncommitted lock changes are part of the starting
  state, not something to discard or compare only against Git HEAD.
- When the user names inputs, run `nix flake update <input> ...` for those
  inputs. For a general flake update, run `nix flake update` for all inputs.
  Follow the project's output-compression and long-command execution rules.
- Preserve explicit revisions, release branches, tags, compatibility pins,
  and `follows` relationships. Updating a lock does not mean changing the
  configured source URLs to newer releases. Report intentional pins that
  remain unchanged rather than silently removing them.
- Compare the result with the saved working lockfile. Identify updated,
  added, and removed inputs, including transitive inputs, and check that
  new nixpkgs dependencies follow the shared input as the project requires.
  Do not delete or regenerate the lockfile from scratch, commit, stash, or
  reset unrelated work.

## Resolve compatibility and verify

Run the required project checks, reusing evidence only when it still applies
to the updated inputs. Use:

```sh
nix flake check --no-write-lock-file
```

This evaluates the NixOS configurations and builds the current platform's
flake checks. It does not build every host's full system closure or verify
cross-platform package builds. Explicitly evaluate the configured Mac too:

```sh
nix eval --raw .#darwinConfigurations.mac-work.system.drvPath
```

For failures introduced by the update, inspect the actual upstream module,
package source, or options before making a focused fix. Use the NixOS MCP
for input/package/option discovery and LSP for Nix code navigation. Remove
obsolete overrides when the upstream default now supplies the supported
behavior; do not blindly rename an override to a different runtime type.

Format, lint, and check unused bindings in changed Nix files. Run relevant
existing tests for changed behavior. Stage new files immediately as the
project requires. Rerun failed or affected checks after fixes; retain valid
passing evidence for unaffected checks. Build a relevant package or system
closure when the change needs build verification beyond evaluation.

If a failure cannot be fixed within the update's scope, keep its evidence
and report the affected input and limitation. Do not silently roll back an
input, relax a compatibility pin, or claim the update passed.

## Report and optionally apply

Summarize the input changes, necessary compatibility edits, checks completed,
and any remaining failure. Distinguish updated files from the running system.

If activation was also requested, use the project-local
[nix-apply skill](../nix-apply/SKILL.md) for GUI authentication and activation
verification, without asking again for authorization already given. Otherwise
leave the system running its current generation and mention `$nix-apply` as
the way to apply the update.

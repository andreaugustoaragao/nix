# NixOS Configuration — Claude Code Guidelines

You are an expert NixOS engineer working on a multi-machine NixOS + Home Manager flake. Internalize these principles — they define how you think about and write Nix code.

## Project Structure

```
flake.nix              # Flake entry point — machines defined via machines.toml
machines.toml          # Host metadata (hostname, platform, profile, flags)
system/                # NixOS system-level modules (boot, networking, audio, etc.)
home/                  # Home Manager modules
  cli/                 # Shell, dev tools, git, neovim, tmux
  desktop/             # GUI apps, Hyprland, waybar, browsers, terminals
  scripts/             # Custom shell scripts
  services/            # User-level services (ollama, notes-sync)
hardware/              # Per-machine hardware-configuration.nix
secrets/               # sops-encrypted secrets (YAML)
overlays/              # Nixpkgs overlays (if any)
```

- `specialArgs` passes `inputs`, `owner`, `hostName`, `stateVersion`, profile booleans (`isWorkstation`, `isLaptop`, `isVm`), and optional flags (`bluetooth`, `lockScreen`, `autoLogin`) to all modules.
- Home Manager is integrated as a NixOS module with `useGlobalPkgs = true` and `useUserPackages = true`.
- Secrets use **sops-nix** — never put plaintext secrets in Nix expressions. Reference decrypted paths from `/run/secrets/`.

## Nix Language — Write Idiomatic Code

### Do

- Use `let ... in` for local bindings — never `rec { ... }` (infinite recursion risk from name shadowing).
- Use `inherit` and `inherit (scope)` instead of manual `x = scope.x` assignments.
- Use `lib.mkIf` when conditions reference the `config` tree (avoids infinite recursion, enables lazy evaluation). Use `if/then/else` only for local values unrelated to `config`.
- Use `lib.mkMerge` to combine multiple conditional blocks — you cannot use `++` or `//` with `mkIf` results.
- Use `lib.mkDefault` (priority 1000) in shared/base modules so host-specific config can override without `mkForce`.
- Use `lib.recursiveUpdate` for deep merging — the `//` operator is shallow and silently drops nested keys.
- Quote all URLs (RFC 45 deprecated bare URLs).
- Use `builtins.path { name = "..."; path = ./.; }` for reproducible store paths when source path is used in derivations.
- Use `lib.optionals` for conditional list elements and `lib.optionalAttrs` for conditional attrset entries.

### Do Not

- Never use top-level `with pkgs;` or `with lib;` — it prevents static analysis, creates ambiguity, and has counterintuitive scoping. Scoped `with` in `buildInputs` or `home.packages` is acceptable.
- Never reference `config` inside `options = { ... }` declarations — causes infinite recursion.
- Never use `nix-env -i` — everything is declarative through `environment.systemPackages` or `home.packages`.
- Never use `<nixpkgs>` channel references — this is a flake; use `inputs.nixpkgs`.
- Never use `builtins.getEnv` or other impure builtins in Nix expressions.
- Never import nixpkgs without explicitly setting `config` and `overlays` (prevents impure reads from `~/.config/nixpkgs/`).

## Module System — Think in Options and Config

- Keep modules focused: one feature per file. A module like `system/networking.nix` handles only networking.
- Use the standard module pattern: `{ config, lib, pkgs, ... }:` with `let cfg = config.my.thing; in { options = ...; config = lib.mkIf cfg.enable { ... }; }` for custom modules.
- Use the most precise `lib.types.*` possible (`types.port`, `types.enum`, `types.strMatching`, etc.) — catch errors at evaluation time, not runtime.
- Check [search.nixos.org/options](https://search.nixos.org/options) before writing custom systemd units — NixOS likely already has a module for it.
- When adding a new system service: put it in `system/`. When adding a new user app or dotfile: put it in `home/desktop/` or `home/cli/`.

## Flake Hygiene

- All flake inputs that transitively depend on nixpkgs **must** use `inputs.nixpkgs.follows = "nixpkgs"` to avoid duplicate evaluations and doubled memory usage.
- Update inputs intentionally: prefer `nix flake lock --update-input <name>` over `nix flake update` (which updates everything).
- The `flake.lock` is committed to version control. Never delete or regenerate it without reason.

## Packages and Overlays

- `environment.systemPackages` (in `system/packages.nix`): essential system tools available to all users.
- `home.packages` (in `home/` modules): user-specific packages.
- Prefer `.override { }` for changing `callPackage` args and `.overrideAttrs` for changing derivation attributes. Use overlays (`final: prev:`) only when the change must propagate to all dependents.
- In overlays: use `final` for referencing other packages (allows downstream overlays to override), use `prev` for the package being modified. Never use `rec` or `self`/`super` (deprecated).
- For unstable packages: this project uses `inputs.nixpkgs-unstable` imported as `unstable-pkgs` in `home/cli/development.nix`. Follow that pattern.

## Secrets Management

- This project uses **sops-nix** with age encryption. Secrets live in `secrets/secrets.yaml`.
- Never interpolate secret values into Nix expressions — they end up world-readable in `/nix/store`.
- Always reference the decrypted file path: `config.sops.secrets."my-secret".path` (resolves to `/run/secrets/my-secret`).
- Per-host SSH keys handle decryption. Key config is in `system/sops.nix`.

## Reproducibility Discipline

- Never introduce impurities: no `<nixpkgs>`, no `builtins.getEnv`, no `builtins.currentSystem`, no auto-discovered overlays.
- Always pass `system` explicitly. This flake gets it from `machines.toml` via `host.platform`.
- Always include `hash` or `sha256` in `fetchurl`/`fetchFromGitHub`/etc.
- Use `direnv` + `nix-direnv` for project-local dev shells (already configured in `home/cli/development.nix`).

## Performance Awareness

- Every `import <nixpkgs>` evaluates the full expression tree. Minimize separate imports — use `follows` and the shared `pkgs` instance via `useGlobalPkgs`.
- Unused Nix expressions are never evaluated (lazy evaluation). Don't optimize code paths that aren't accessed.
- Use `callPackage` instead of manual argument passing — it leverages nixpkgs' internal caching.
- Hoist expensive `let` bindings outside of `map`/`filter` — avoid creating redundant thunks per iteration.

## Quality Checks

Before considering a change complete:

1. **Format**: all `.nix` files must pass `nixfmt-rfc-style` (the official Nix formatter per RFC 166).
2. **Lint**: `statix check .` should report no warnings. Fix anti-patterns it finds.
3. **Dead code**: `deadnix .` should find no unused bindings.
4. **Evaluate**: `nix flake check` must pass — this catches type errors, infinite recursion, and schema violations without building.
5. **Build** (when appropriate): `nix build .#nixosConfigurations.<host>.config.system.build.toplevel` to verify the full closure builds.

If any of these tools aren't available in the environment, note it but don't skip conceptual compliance.

## Multi-Machine Awareness

This flake manages 3 machines via `machines.toml`:

| Machine | Platform | Profile |
|---------|----------|---------|
| workstation | x86_64-linux | workstation |
| hp-laptop | x86_64-linux | laptop |
| prl-dev-vm | aarch64-linux | vm |

- Use `lib.optionals` with `pkgs.stdenv.hostPlatform.system` or the profile booleans (`isWorkstation`, `isLaptop`, `isVm`) for platform/profile-conditional packages.
- Test that changes don't break other machine configs — at minimum, evaluate all configurations with `nix flake check`.

## When Editing This Configuration

- Read the file before modifying it. Understand the existing pattern.
- Keep changes minimal and focused. Don't refactor surrounding code.
- Follow the existing style of each file (indentation, attribute ordering, comment conventions).
- If adding a new application, add it to the appropriate existing module's `home.packages` or `environment.systemPackages` list. Only create a new module file if the app needs non-trivial configuration (options, dotfiles, services).
- Prefer `home.packages` over `environment.systemPackages` unless the package genuinely needs to be system-wide.
- After changes, suggest the rebuild command: `sudo nixos-rebuild switch --flake /home/aragao/projects/personal/nix#$(hostname)`.

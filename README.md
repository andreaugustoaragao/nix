# NixOS Configuration (multi-machine, reproducible)

Declarative NixOS + Home Manager setup for multiple machines (x86_64 and aarch64), with Wayland desktops (Hyprland, Niri), modern CLI tools, and a full developer environment.

### Highlights
- **Wayland**: Hyprland and Niri (scrollable-tiling) via UWSM
- **Status bar**: Waybar with Kanagawa theme and rich modules
- **Apps**: Firefox, Brave, Qutebrowser, Ghostty, Foot, Alacritty, VS Code, Neovim (LazyVim)
- **Services**: Mako, Wofi, Wlogout, SwayOSD, Hyprpaper, Fcitx5
- **Dev tooling**: Node.js 22, Python, Go, Java 21, Nix; LSPs; Docker/Podman, k8s, cloud CLIs
- **Secrets**: sops-nix + age recipients
- **Flakes**: Single repo drives all machines

## Machines
Defined in `machines.toml` and wired via `flake.nix`:
- `workstation` (x86_64-linux)
- `hp-laptop` (x86_64-linux)
- `prl-dev-vm` (aarch64-linux)

## Layout
```text
nix/
  flake.nix
  machines.toml
  hardware/
    hp-laptop/
    prl-dev-vm/
    workstation/
  system/           # System-wide modules
  home/             # Home Manager modules
  secrets/          # Encrypted with sops-nix
  keys/             # age public keys (recipients)
  README.md
```

## Usage
Prereqs: NixOS with flakes enabled.

- Switch the current host to a specific machine profile:
```bash
sudo nixos-rebuild switch --flake .#workstation
sudo nixos-rebuild switch --flake .#hp-laptop
sudo nixos-rebuild switch --flake .#prl-dev-vm
```

- Update inputs and rebuild:
```bash
nix flake update
sudo nixos-rebuild switch --flake .#workstation
```

Notes
- Home Manager is integrated as a NixOS module; a single `nixos-rebuild switch` applies both system and user configs.
- For remote deploys, you can use `--target-host`/`--use-remote-sudo` with `nixos-rebuild`.

## Secrets (sops-nix)
- Encrypted secrets live under `secrets/` and are managed by sops-nix.
- age recipients are in `keys/*.age.pub` per machine.
- See `SOPS-SETUP-GUIDE.md` for bootstrap steps (adding host keys, editing `secrets/secrets.yaml`).

## Desktop Notes
- Hyprland and Niri can be selected via sessions (UWSM).
- Waybar uses a Kanagawa-inspired theme.
- Niri keybind highlights:
  - Mod+Home / Mod+End jump to first/last column
  - Up/Down focus and move wrap across workspaces at top/bottom

## Troubleshooting
- Check `hardware/<machine>/hardware-configuration.nix` when hardware changes.
- Verify `machines.toml` entries (platform/profile/stateVersion).
- Regenerate secrets recipients if adding a new machine.

---
Personal, reproducible configs for daily development and Wayland workflows.
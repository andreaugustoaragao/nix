# NixOS installer scripts

## `install-nixos.sh`

One-shot installer that runs from a NixOS minimal ISO. Picks a target machine from `machines.toml`, partitions the disk, copies the flake into place, and runs `nixos-install --flake .#<host>`.

For the end-to-end Parallels / VMware Fusion VM walkthrough (boot the ISO, SSH in, run this script, bootstrap sops), see [`../VM-SETUP.md`](../VM-SETUP.md).

### What it does

1. **Discover candidates.** Clones the flake to `/tmp/nix-installer-flake` and lists every host whose `hardware/<host>/hardware-configuration.nix`:
   - references `/dev/disk/by-label/nixos` (this script's btrfs layout), **and**
   - contains no LUKS configuration, **and**
   - has a matching `[machines.<host>]` entry in `machines.toml`.
2. **Prompt** for the target host (or honor `$TARGET_HOSTNAME`) and confirm the disk wipe.
3. **Partition.** GPT label, 512 MiB FAT32 ESP labelled `nixos-boot`, remainder labelled `nixos`. NVMe / mmcblk / loop devices get the kernel's `p` separator (`/dev/nvme0n1p1`) automatically.
4. **Format + subvolume layout.** btrfs root with subvolumes `@root`, `@home-aragao`, `@nix`, `@tmp`, `@snapshots`, `@swap` — mounted with `compress=zstd:1,noatime,space_cache=v2`.
5. **Stage the flake.** Copies `/tmp/nix-installer-flake` into `/mnt/home/aragao/projects/personal/nix` and symlinks `/etc/nixos → /home/aragao/projects/personal/nix` for convenience.
6. **Install.** `nixos-install --root /mnt --flake .../#<host>`.

The script does **not** set up LUKS, encrypt secrets, or apply any post-install Home Manager changes — Home Manager runs as part of `nixos-rebuild switch` on first activation.

### Usage

Boot the NixOS minimal ISO, SSH in (see `../VM-SETUP.md` Phase 2), then:

```bash
curl -L https://raw.githubusercontent.com/andreaugustoaragao/nix/main/scripts/install-nixos.sh -o /tmp/install.sh
chmod +x /tmp/install.sh
/tmp/install.sh
```

Do **not** pipe to `bash` — the script's interactive menu and destroy-confirmation prompt need a real stdin.

### Environment knobs

| Variable | Default | Purpose |
|---|---|---|
| `DISK` | `/dev/sda` | Target block device. Set to `/dev/nvme0n1` for VMware Fusion on Apple Silicon. |
| `TARGET_HOSTNAME` | (unset) | Skip the interactive menu and use this host. Must already be in `machines.toml` + `hardware/`. |
| `FLAKE_REPO` | `https://github.com/andreaugustoaragao/nix.git` | Where to clone the flake from. |

Examples:

```bash
# VMware Fusion VM, pick host from menu
DISK=/dev/nvme0n1 /tmp/install.sh

# Fully scripted (still confirms destroy)
TARGET_HOSTNAME=vmw-dev-vm DISK=/dev/nvme0n1 /tmp/install.sh
```

### Post-install

```bash
sudo reboot
# from mac-work:
ssh <host>           # mDNS alias, see home/cli/ssh-config.nix
```

Then bootstrap sops — see `../VM-SETUP.md` Phase 5.

### Snapshots

The btrfs subvolume layout supports manual snapshots:

```bash
sudo btrfs subvolume snapshot /home/aragao /.snapshots/home-$(date +%Y%m%d-%H%M%S)
sudo btrfs subvolume list /.snapshots
```

There is no automatic snapshot service wired up in the flake yet.

## `add-age-host-recipient.sh`

Adds a new host's age public key as a sops recipient. Run from a trusted machine that can already decrypt `secrets/secrets.yaml`. See the script header for usage.

## `watch-rebuild.sh`

Tails the journal and re-runs `nixos-rebuild switch` on file changes — convenient when iterating on a flake module locally. See the script header for usage.

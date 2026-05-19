# Creating a NixOS VM (Parallels or VMware Fusion)

End-to-end guide for setting up a NixOS dev VM on Apple Silicon mac-work, under either Parallels Desktop or VMware Fusion. Both hypervisors land at the same flake configuration — only Phase 1 (hypervisor setup) and the install-time `DISK=` value differ.

The flake already ships a one-shot installer at [`scripts/install-nixos.sh`](scripts/install-nixos.sh). It partitions, formats, copies the flake onto the target, and runs `nixos-install --flake .#<host>`. You only do the bits before and after.

## Prerequisites

- mac-work (or any Apple Silicon Mac) with Parallels Desktop **or** VMware Fusion 13+
- NixOS minimal **aarch64** ISO — [nixos.org/download](https://nixos.org/download/#nixos-iso) → *Minimal ISO image*, aarch64 tab
- The host name you want to install must already exist in the flake:
  - `machines.toml` has a `[machines.<host>]` entry
  - `hardware/<host>/hardware-configuration.nix` exists and points its filesystems at `/dev/disk/by-label/nixos` (plus `nixos-boot` for EFI)
  - The flake has been pushed to GitHub so the installer can `git clone` it

  Currently satisfied hosts: **`prl-dev-vm`** (Parallels), **`vmw-dev-vm`** (VMware Fusion). If you want a different name, see [Adding a brand-new host](#adding-a-brand-new-host) at the bottom.

## Phase 1: Create the VM

### Parallels Desktop

1. **File > New** → *Install Windows or another OS from a DVD or image file*
2. Browse to the NixOS `.iso`. Parallels won't auto-detect — select **Other Linux** manually.
3. Name the VM (e.g. `prl-dev-vm`)
4. Configure before starting:
   - CPU: 4+ cores
   - RAM: 8 GB minimum (16 GB for development)
   - Disk: 80+ GB
   - Network: Shared Network (NAT) — default
5. Start the VM.

Disk shows up inside the guest as **`/dev/sda`** (SCSI emulation).

### VMware Fusion

1. **File > New** → *Install from disc or image* → drag in the NixOS ISO
2. Pick **Other Linux 5.x or later kernel ARM 64-bit** when prompted
3. *Customize Settings* before starting:
   - Processors & Memory: 4+ cores, 8 GB+
   - Hard Disk: 80 GB+, default controller (NVMe on Apple Silicon)
   - Network Adapter: NAT (default)
   - Boot firmware: UEFI (required for `systemd-boot`)
4. Start the VM.

Disk shows up inside the guest as **`/dev/nvme0n1`**. The installer needs `DISK=/dev/nvme0n1` (see Phase 3).

## Phase 2: SSH into the installer

Driving the install over SSH from a terminal on mac-work beats typing into the cramped hypervisor console. The minimal aarch64 ISO auto-logs you in as `nixos` (passwordless `sudo`); `openssh` is available but not running.

**In the hypervisor console (one time):**

```bash
# Set a password for the nixos user so we can SSH in
sudo passwd nixos

# Start sshd
sudo systemctl start sshd

# Find the VM's IP
ip -4 -br addr show
```

- Parallels NAT typically hands out `10.211.55.x`
- VMware Fusion NAT typically hands out `192.168.x.y` (the subnet is configurable)

**From mac-work:**

```bash
ssh nixos@<ip>
```

If you recreate the VM later and SSH complains about a changed host key:

```bash
ssh-keygen -R <ip>
```

Everything below this point runs in that SSH session.

## Phase 3: Run the installer

```bash
# Download (don't pipe to bash — the script needs an interactive stdin
# for its menu and the destroy-confirmation prompt)
curl -L https://raw.githubusercontent.com/andreaugustoaragao/nix/main/scripts/install-nixos.sh -o /tmp/install.sh
chmod +x /tmp/install.sh

# Parallels (defaults to /dev/sda)
/tmp/install.sh

# VMware Fusion
DISK=/dev/nvme0n1 /tmp/install.sh
```

The script:

1. Clones the flake to `/tmp/nix-installer-flake`
2. Lists installable hosts (anything with a matching `machines.toml` entry and a `hardware/<host>/hardware-configuration.nix` that points at `/dev/disk/by-label/nixos`)
3. Asks you to pick one and confirm the disk wipe
4. Partitions GPT + EFI + btrfs, creates the six subvolumes (`@root`, `@home-aragao`, `@nix`, `@tmp`, `@snapshots`, `@swap`), mounts everything under `/mnt`
5. Copies the flake into `/mnt/home/aragao/projects/personal/nix`
6. Runs `nixos-install --flake .../#<host>`

When it finishes, `sudo reboot`.

### Skipping the menu

```bash
TARGET_HOSTNAME=vmw-dev-vm DISK=/dev/nvme0n1 /tmp/install.sh
```

You still get the destroy-confirmation prompt.

## Phase 4: First boot

After reboot the system advertises itself over mDNS (avahi, configured in `system/mdns.nix`). From mac-work:

```bash
ssh prl-dev-vm           # alias in home/cli/ssh-config.nix → prl-dev-vm.local
ssh vmw-dev-vm           # alias → vmw-dev-vm.local
```

The login password is whatever's in your sops `user_password` field — but **secrets aren't decryptable yet** because the new VM's host key isn't an age recipient. That's Phase 5.

In the meantime you can still get in: the flake's `system/ssh.nix` pre-authorizes the `penguin` and `andrearag@gmail.com` SSH keys, so key-based login works immediately if you have either key on mac-work.

## Phase 5: Bootstrap sops-nix

You have another machine (mac-work or workstation) that can already decrypt `secrets/secrets.yaml`, so the "Path A" flow applies. Bootstrap-from-scratch isn't covered here — see `SOPS-SETUP-GUIDE.md`.

**1. On the new VM — get its age public key:**

sops-nix auto-generates a host key at `/var/lib/sops-nix/key.txt` on first activation.

```bash
sudo cat /var/lib/sops-nix/key.txt | nix-shell -p age --run "age-keygen -y"
```

Copy the `age1…` output.

**2. On a trusted machine (mac-work) — register the key:**

```bash
cd ~/projects/personal/nix

# Save the new VM's public key
echo "age1..." > keys/<host>.age.pub
```

Add it to `.sops.yaml` under `creation_rules`:

```yaml
creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - *admin_key
          # ... existing keys ...
          - age1...  # <host>
```

**3. Re-encrypt secrets:**

```bash
sops updatekeys secrets/secrets.yaml
```

Commit `.sops.yaml`, `keys/<host>.age.pub`, and `secrets/secrets.yaml`; push.

**4. On the new VM — pull and rebuild:**

```bash
cd ~/projects/personal/nix
git pull
sudo nixos-rebuild switch --flake .#<host>
```

`/run/secrets/` should now be populated and password / SSH-key / GPG-key login should work end-to-end.

## Phase 6: Verification

```bash
# Guest agent
systemctl status prl-tools.service   # Parallels
# (VMware: open-vm-tools runs under vmtoolsd)
systemctl status vmtoolsd.service    # VMware

# Desktop session
# Log out / back in — niri auto-login should land you in the WM
# (autoLogin = true for both VM profiles)

# Secrets
ls -la /run/secrets/

# GitHub SSH (uses sops-managed keys)
ssh -T github-personal

# Idempotent rebuild
sudo nixos-rebuild switch --flake ~/projects/personal/nix#<host>
```

## Networking notes

- All VMs use DHCP on ethernet by default. `prl-dev-vm` is the lone exception: it pins a static IP (`10.211.55.4/24`) in `system/networking.nix:24-34` because k3s wants stable cluster networking on that one host. `vmw-dev-vm` is DHCP — k3s falls back to its auto-detected node IP.
- Hypervisor NAT DNS is unreliable. `system/networking.nix:64-67` overrides VM resolvers to `1.1.1.1` / `8.8.8.8` for every VM except `prl-dev-vm` (which has its own static-IP DNS list).
- mDNS publishing is on across the flake (`system/mdns.nix`), so `ssh <host>.local` works from peers on the same LAN segment without chasing DHCP leases.

## Quick reference

| Step | Command |
|---|---|
| Rebuild | `sudo nixos-rebuild switch --flake ~/projects/personal/nix#<host>` |
| Check eval | `nix flake check` |
| Get host age key | `sudo cat /var/lib/sops-nix/key.txt \| nix-shell -p age --run "age-keygen -y"` |
| Re-encrypt secrets | `sops updatekeys secrets/secrets.yaml` |
| Format Nix files | `nixfmt <file>` |

## Adding a brand-new host

If the host you want doesn't exist in `machines.toml`, the installer's menu won't show it. To add one (e.g. an x86 Fusion install or a second VMware VM):

1. Add a `[machines.<host>]` block to `machines.toml`. Use `prl-dev-vm` (Parallels) or `vmw-dev-vm` (VMware Fusion) as the template.
2. Create `hardware/<host>/hardware-configuration.nix`. Copy whichever existing VM file matches your hypervisor — the layouts are fully label-addressed and generic.
3. If the new VM should host the same dev services (fulcrum, caddy reverse proxy, /etc/hosts entries), extend the conditions in `system/networking.nix:230` and `system/caddy.nix:22`.
4. Add an SSH alias in `home/cli/ssh-config.nix`.
5. Commit and push, then proceed from Phase 1 above.

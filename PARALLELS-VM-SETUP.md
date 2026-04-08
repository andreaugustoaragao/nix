# Creating a NixOS Parallels VM from Scratch

Step-by-step guide for setting up a new NixOS virtual machine on Parallels Desktop (Apple Silicon Mac) and bootstrapping it with this flake configuration.

## Prerequisites

- Parallels Desktop installed on macOS (Apple Silicon)
- NixOS minimal ISO for aarch64 — download from [nixos.org/download](https://nixos.org/download/#nixos-iso)
  - Choose **Minimal ISO image** under the **aarch64** tab

## Phase 1: Create the VM in Parallels

1. Open Parallels Desktop and choose **File > New**
2. Select **Install Windows or another OS from a DVD or image file**
3. Browse to the NixOS `.iso` you downloaded
4. Parallels won't auto-detect NixOS — select **Other Linux** manually
5. Name the VM (e.g. `prl-dev-vm`) and choose where to store it
6. Configure hardware before starting:
   - **CPU**: 4+ cores recommended
   - **RAM**: 8 GB minimum (16 GB recommended for development)
   - **Disk**: 80+ GB (NixOS store grows with packages)
   - **Network**: Shared Network (NAT) — default
7. Start the VM — it boots into the NixOS installer shell

## Phase 2: Partition and Install NixOS

This uses LUKS encryption with btrfs subvolumes, matching the `prl-dev-vm` setup.

```bash
# Identify the disk
lsblk

# Partition: EFI + LUKS container
parted /dev/sda -- mklabel gpt
parted /dev/sda -- mkpart ESP fat32 1MiB 512MiB
parted /dev/sda -- set 1 esp on
parted /dev/sda -- mkpart primary 512MiB 100%

# Label the EFI partition
mkfs.fat -F 32 -n nixos-boot /dev/sda1

# Set up LUKS encryption — you will be prompted to create a passphrase.
# This passphrase is required on every boot to unlock the disk.
cryptsetup luksFormat --label nixos-crypt /dev/sda2
# Unlock the encrypted partition (enter the passphrase you just set)
cryptsetup open /dev/sda2 cryptroot

# Create btrfs and subvolumes
mkfs.btrfs -L nixos /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@home-aragao
btrfs subvolume create /mnt/@nix
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap

umount /mnt

# Mount subvolumes with compression
mount -o subvol=@root,compress=zstd:1,noatime,space_cache=v2,discard=async /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home/aragao,nix,tmp,.snapshots,swap}

mount /dev/sda1 /mnt/boot
mount -o subvol=@home-aragao,compress=zstd:1,noatime,space_cache=v2,discard=async /dev/mapper/cryptroot /mnt/home/aragao
mount -o subvol=@nix,compress=zstd:1,noatime,space_cache=v2,discard=async /dev/mapper/cryptroot /mnt/nix
mount -o subvol=@tmp,compress=zstd:1,noatime,space_cache=v2,discard=async /dev/mapper/cryptroot /mnt/tmp
mount -o subvol=@snapshots,compress=zstd:1,noatime,space_cache=v2,discard=async /dev/mapper/cryptroot /mnt/.snapshots
mount -o subvol=@swap,compress=zstd:1,noatime,space_cache=v2,discard=async /dev/mapper/cryptroot /mnt/swap

# Create swap file (16 GB)
btrfs filesystem mkswapfile --size 16g /mnt/swap/swapfile
swapon /mnt/swap/swapfile
```

### Generate and Install the Base System

```bash
# Generate hardware config
nixos-generate-config --root /mnt

# Edit the generated config for a minimal bootable system
nano /mnt/etc/nixos/configuration.nix
```

Replace the contents of `/mnt/etc/nixos/configuration.nix` with a minimal config to get the system bootable:

```nix
{ config, pkgs, lib, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "your-vm-name";
  networking.useDHCP = true;

  # Enable SSH so you can connect from the host
  services.openssh.enable = true;

  # Temporary user for bootstrapping
  users.users.aragao = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "changeme";
  };

  # Enable flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Basic packages for bootstrapping
  environment.systemPackages = with pkgs; [ git vim ];

  system.stateVersion = "25.05";
}
```

```bash
# Install
nixos-install

# Set root password when prompted
# Reboot
reboot
```

## Phase 3: Bootstrap the Flake Configuration

After the VM boots into the minimal NixOS install:

```bash
# Log in as aragao (password: changeme)

# Clone the configuration repo
git clone git@github-personal:andreaugustoaragao/nix.git ~/projects/personal/nix
cd ~/projects/personal/nix
```

### Add the New Machine to the Flake

If this is a **new** machine not yet in `machines.toml`, you need to register it:

**1. Add the machine entry to `machines.toml`:**

```toml
[machines.your-vm-name]
hostName = "your-vm-name"
platform = "aarch64-linux"
profile = "vm"
stateVersion = "25.05"
bluetooth = false
lockScreen = false
autoLogin = true
```

**2. Create the hardware configuration directory:**

```bash
mkdir -p hardware/your-vm-name

# Copy the hardware config generated during install
cp /etc/nixos/hardware-configuration.nix hardware/your-vm-name/
```

**3. Edit `hardware/your-vm-name/hardware-configuration.nix`:**

Add Parallels guest support and the QEMU guest profile. Use `hardware/prl-dev-vm/hardware-configuration.nix` as a reference. The key additions are:

```nix
{ config, lib, pkgs, modulesPath, inputs, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # ... keep the auto-generated kernel modules and filesystem entries ...

  # Add Parallels Tools
  hardware.parallels = {
    enable = true;
    package = pkgs.prl-tools;
  };

  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "prl-tools" ];
}
```

**4. Build and switch:**

```bash
sudo nixos-rebuild switch --flake ~/projects/personal/nix#your-vm-name
```

The first rebuild will take a while as it downloads and builds the full desktop environment.

## Phase 4: Set Up Secrets (sops-nix)

The configuration uses sops-nix for secret management. Without secrets bootstrapped, the system will work but SSH keys, GPG keys, and passwords won't be managed.

Choose the path that matches your situation:

- **Path A** — You have another machine that can already decrypt the secrets (the common case when adding a VM to an existing setup)
- **Path B** — This is your first machine or you have no access to a machine with decryption keys (full bootstrap from scratch)

### Path A: Add to Existing Secrets

This requires a trusted machine — one whose age key is already in `.sops.yaml` and can decrypt `secrets/secrets.yaml`. The new VM cannot add itself; you need to register its key from the trusted machine.

**1. Get the new VM's host key (on the new VM):**

sops-nix auto-generates a host key at `/var/lib/sops-nix/key.txt` on first activation. Extract its public key:

```bash
# Get this machine's age public key
sudo cat /var/lib/sops-nix/key.txt | nix-shell -p age --run "age-keygen -y"
```

Copy the `age1...` output — you'll need it on the trusted machine.

**2. Register the key (on the trusted machine):**

```bash
cd ~/projects/personal/nix

# Save the new VM's public key
echo "age1..." > keys/your-vm-name.age.pub
```

Add the key to `.sops.yaml` under `creation_rules`:

```yaml
creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - *admin_key
          # ... existing keys ...
          - age1...  # your-vm-name
```

**3. Re-encrypt secrets (on the trusted machine):**

```bash
sops updatekeys secrets/secrets.yaml
```

Commit and push the changes to `.sops.yaml`, `keys/`, and `secrets/secrets.yaml`.

**4. Pull and rebuild (on the new VM):**

```bash
cd ~/projects/personal/nix
git pull
sudo nixos-rebuild switch --flake ~/projects/personal/nix#your-vm-name
```

### Path B: Bootstrap from Scratch

Use this when no existing machine can decrypt the secrets — you need to create a new admin age key and new secrets from the ground up.

**1. Generate an admin age key (on the new VM):**

```bash
# Generate the admin age key used for sops encryption/decryption
age-keygen -o ~/.ssh/id_ed25519_nixos-agenix
chmod 600 ~/.ssh/id_ed25519_nixos-agenix

# Display the public key — this becomes the admin_key in .sops.yaml
grep "^age1" ~/.ssh/id_ed25519_nixos-agenix
```

**2. Get the host key:**

```bash
sudo cat /var/lib/sops-nix/key.txt | nix-shell -p age --run "age-keygen -y"
```

Save it:

```bash
echo "age1..." > keys/your-vm-name.age.pub
```

**3. Create `.sops.yaml`:**

```yaml
keys:
  - &admin_key age1...YOUR_ADMIN_PUBLIC_KEY...

creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - *admin_key
          - age1...  # your-vm-name host key
```

**4. Create and populate the secrets file:**

```bash
sops secrets/secrets.yaml
```

This opens an editor. All keys below are required — the NixOS configuration expects every one of them in `system/sops.nix`. Missing keys will cause the rebuild to fail.

```yaml
# ── Login ────────────────────────────────────────────────────────────
# Generate with: mkpasswd -m SHA-512
user_password: "$6$..."       # hashed password for your user account
root_password: "$6$..."       # hashed password for root

# ── SSH keys (GitHub) ────────────────────────────────────────────────
# Generate with: ssh-keygen -t ed25519
# Paste the full private key (including BEGIN/END lines)
ssh_key_github_personal: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
ssh_key_github_work: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----

# Matching public keys (single line each)
ssh_pubkey_github_personal: "ssh-ed25519 AAAA... email@example.com"
ssh_pubkey_github_work: "ssh-ed25519 AAAA... email@work.com"

# Passphrases for automatic SSH key loading (empty string if none)
ssh_passphrase_personal: ""
ssh_passphrase_work: ""

# ── GPG keys (commit signing) ───────────────────────────────────────
# Generate with: gpg --full-generate-key
# Export with: gpg --export-secret-keys KEY_ID
gpg_key_personal: |
  -----BEGIN PGP PRIVATE KEY BLOCK-----
  ...
  -----END PGP PRIVATE KEY BLOCK-----
gpg_key_work: |
  -----BEGIN PGP PRIVATE KEY BLOCK-----
  ...
  -----END PGP PRIVATE KEY BLOCK-----

# Passphrases for automatic GPG key unlocking (empty string if none)
gpg_passphrase_personal: ""
gpg_passphrase_work: ""

# ── WiFi ─────────────────────────────────────────────────────────────
# wpa_supplicant env file with PSK values (used by hp-laptop)
# For VMs this is still required but won't be used
wifi_env: |
  wifi_password_home=...
  wifi_password_work=...

# ── Bitwarden ────────────────────────────────────────────────────────
bitwarden:
  master_password: "..."
  server_url: "https://..."
  email: "you@example.com"

# ── Google OAuth (for Google Workspace MCP) ──────────────────────────
google_oauth_client_id: "...apps.googleusercontent.com"
google_oauth_client_secret: "GOCSPX-..."
```

See `SOPS-SETUP-GUIDE.md` for detailed steps on generating each value (password hashes, SSH keys, GPG keys, etc.).

**5. Rebuild:**

```bash
sudo nixos-rebuild switch --flake ~/projects/personal/nix#your-vm-name
```

## Phase 5: Post-Install Verification

```bash
# Verify Parallels Tools are running
systemctl status prl-tools.service

# Verify the desktop session works
# Log out and back in — greetd should present a login screen
# (or auto-login to Niri if autoLogin = true)

# Verify secrets are decrypted (after sops setup)
ls -la /run/secrets/

# Verify SSH keys work
ssh -T github-personal

# Test a rebuild
sudo nixos-rebuild switch --flake ~/projects/personal/nix#your-vm-name
```

## Networking Notes

- VMs default to DHCP on ethernet interfaces via systemd-networkd
- `prl-dev-vm` is special-cased with a static IP (`10.211.55.4/24`) in `system/networking.nix` — if your new VM needs a static IP, add a similar conditional there
- Parallels NAT DNS can drop some records, so VMs override DNS to `1.1.1.1` and `8.8.8.8`

## Quick Reference

| Step | Command |
|------|---------|
| Rebuild | `sudo nixos-rebuild switch --flake ~/projects/personal/nix#your-vm-name` |
| Check eval | `nix flake check` |
| Get host age key | `sudo cat /var/lib/sops-nix/key.txt \| age-keygen -y` |
| Re-encrypt secrets | `sops updatekeys secrets/secrets.yaml` |
| Format nix files | `nixfmt *.nix` |

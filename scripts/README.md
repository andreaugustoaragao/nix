# NixOS Automated Installation

This directory contains scripts for fully automated NixOS installation with LUKS encryption and btrfs.

## Usage

### Basic Installation

Boot from NixOS ISO and run:

```bash
# Download and run the installer
curl -L https://raw.githubusercontent.com/your-username/nix-config/main/scripts/install-nixos.sh | bash
```

### Custom Installation

```bash
# Download the script
wget https://raw.githubusercontent.com/your-username/nix-config/main/scripts/install-nixos.sh
chmod +x install-nixos.sh

# Customize variables
export DISK="/dev/nvme0n1"           # Target disk
export HOSTNAME="my-laptop"          # Machine hostname  
export USERNAME="myuser"             # Username
export USER_FULLNAME="My Name"       # Full name
export FLAKE_REPO="https://github.com/my-user/my-nix-config.git"

# Run installation
./install-nixos.sh
```

## What the Script Does

1. **Disk Setup**:
   - Creates GPT partition table
   - 512MB EFI boot partition  
   - Remaining space for LUKS encrypted root

2. **Encryption**:
   - Sets up LUKS encryption on root partition
   - Prompts for encryption passphrase

3. **Btrfs Layout**:
   - Creates optimized subvolume structure:
     - `@root` → `/`
     - `@home` → `/home`
     - `@home-username` → `/home/username`
     - `@nix` → `/nix`
     - `@tmp` → `/tmp`
     - `@snapshots` → `/.snapshots`

4. **Configuration**:
   - Downloads your flake configuration from GitHub
   - Checks that the specified hostname exists in machines.toml

5. **Installation**:
   - Installs NixOS using your existing flake configuration
   - Uses pre-configured hardware settings for the machine

## Features

- **Fully Declarative**: Everything managed through Nix configuration
- **Full Disk Encryption**: LUKS encryption with secure boot
- **Btrfs**: Modern filesystem with compression and snapshots
- **Automated**: Zero manual configuration needed
- **Reproducible**: Same result every time
- **Flexible**: Easy to customize via environment variables

## Requirements

- NixOS ISO environment
- Internet connection for downloading configuration
- Git repository with your flake configuration
- Machine hostname must exist in machines.toml
- Corresponding hardware configuration file must exist

## Security Features

- LUKS encryption for data at rest
- Secure boot compatible
- Separate encrypted subvolumes for different system areas
- Snapshot capability for easy backups and rollbacks

## Post-Installation

After reboot:
1. Enter disk encryption password
2. Login with your username
3. Set user password: `passwd`
4. System is ready to use!

## Creating Snapshots

```bash
# Snapshot your home directory
sudo btrfs subvolume snapshot /home/username /.snapshots/home-$(date +%Y%m%d-%H%M%S)

# List snapshots
sudo btrfs subvolume list /.snapshots
```

## Troubleshooting

- **Script fails**: Check disk path and permissions
- **Boot fails**: Verify UEFI settings and secure boot
- **Flake errors**: Ensure your GitHub repository is accessible
- **Encryption issues**: Check passphrase and LUKS setup
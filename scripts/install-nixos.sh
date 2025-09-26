#!/usr/bin/env bash

set -euo pipefail

# NixOS Automated Installation Script
# This script fully automates NixOS installation with LUKS encryption and btrfs

# Configuration
DISK="${DISK:-/dev/sda}"  # Override with DISK=/dev/nvme0n1 ./install-nixos.sh
HOSTNAME="${HOSTNAME:-parallels-vm}"  # Override with HOSTNAME=laptop ./install-nixos.sh
FLAKE_REPO="${FLAKE_REPO:-https://github.com/andreaugustoaragao/nix.git}"
USERNAME="${USERNAME:-aragao}"
USER_FULLNAME="${USER_FULLNAME:-Andre Aragao}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "This script should not be run as root. It will use sudo when needed."
fi

# Check if we're in a NixOS installer environment
if ! command -v nixos-install &> /dev/null; then
    error "This script must be run from a NixOS installer environment"
fi

log "Starting automated NixOS installation"
log "Target disk: $DISK"
log "Hostname: $HOSTNAME"
log "Username: $USERNAME"

# Confirm before proceeding
read -p "This will DESTROY ALL DATA on $DISK. Continue? (yes/no): " -r
if [[ ! $REPLY =~ ^yes$ ]]; then
    error "Installation cancelled"
fi

# Step 1: Partition the disk
log "Partitioning disk $DISK"

# Unmount any existing mounts
sudo umount -R /mnt 2>/dev/null || true

# Create partition table
sudo parted $DISK --script -- mklabel gpt

# Create EFI partition (512MB)
sudo parted $DISK --script -- mkpart ESP fat32 1MiB 513MiB
sudo parted $DISK --script -- set 1 esp on

# Create root partition (rest of disk) with label
sudo parted $DISK --script -- mkpart primary 513MiB 100%
sudo parted $DISK --script -- name 2 nixos-crypt

# Format EFI partition
log "Formatting EFI partition"
sudo mkfs.fat -F 32 -n nixos-boot ${DISK}1

# Setup LUKS encryption
log "Setting up LUKS encryption on ${DISK}2"
echo "Enter passphrase for disk encryption (you'll need this to unlock the system):"
sudo cryptsetup luksFormat ${DISK}2

echo "Enter the passphrase again to unlock the encrypted partition:"
sudo cryptsetup luksOpen ${DISK}2 cryptroot

# Format root partition with btrfs
log "Creating btrfs filesystem"
sudo mkfs.btrfs -L nixos /dev/mapper/cryptroot

# Step 2: Create btrfs subvolumes
log "Creating btrfs subvolumes"

# Mount the root btrfs filesystem
sudo mount /dev/mapper/cryptroot /mnt

# Create subvolumes
log "Creating btrfs subvolumes"
sudo btrfs subvolume create /mnt/@root
sudo btrfs subvolume create /mnt/@nix
sudo btrfs subvolume create /mnt/@tmp
sudo btrfs subvolume create /mnt/@swap
sudo btrfs subvolume create /mnt/@snapshots

# Create user-specific home subvolume
sudo btrfs subvolume create /mnt/@home-$USERNAME

# Unmount root filesystem
sudo umount /mnt

# Step 3: Mount subvolumes
log "Mounting btrfs subvolumes"

# Mount options for btrfs
BTRFS_OPTS="compress=zstd:1,noatime,space_cache=v2"

# Mount root subvolume
sudo mount -o subvol=@root,$BTRFS_OPTS /dev/mapper/cryptroot /mnt

# Create mount points
sudo mkdir -p /mnt/{home,nix,tmp,swap,boot,.snapshots}
sudo mkdir -p /mnt/home/$USERNAME

# Mount user-specific home subvolume directly
sudo mount -o subvol=@home-$USERNAME,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/home/$USERNAME
sudo mount -o subvol=@nix,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/nix
sudo mount -o subvol=@tmp,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/tmp
sudo mount -o subvol=@snapshots,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/.snapshots

# Mount EFI partition
sudo mount ${DISK}1 /mnt/boot

# Set permissions
sudo chown 1000:100 /mnt/home/$USERNAME  # Assuming UID 1000 for first user

# Step 4: Generate hardware configuration
log "Generating hardware configuration"
sudo nixos-generate-config --root /mnt

# Step 5: Download and setup flake configuration
log "Downloading flake configuration from $FLAKE_REPO"

# Clone the configuration repository
cd /mnt/etc/nixos
sudo rm -rf ./*  # Remove default generated files
sudo git clone $FLAKE_REPO .
sudo chown -R root:root .

# Using partition labels instead of UUIDs for cleaner configuration
log "Using partition labels: nixos-crypt (encrypted) and nixos-boot (EFI)"

# Step 6: Check if machine exists in machines.toml
log "Checking if machine $HOSTNAME exists in configuration"

if ! grep -q "\\[machines\\.$HOSTNAME\\]" /mnt/etc/nixos/machines.toml; then
    error "Machine '$HOSTNAME' not found in machines.toml. Please add it to the configuration first."
fi

log "Machine $HOSTNAME found in configuration, proceeding with installation"

# Step 7: Install NixOS
log "Installing NixOS with flake configuration"
sudo nixos-install --root /mnt --flake "/mnt/etc/nixos#$HOSTNAME"

log "Installation completed successfully!"

# Step 8: Final setup instructions
cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                            INSTALLATION COMPLETE!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Your NixOS system has been installed with:
  • Full disk encryption (LUKS)
  • Btrfs with optimized subvolumes
  • Your flake configuration from: $FLAKE_REPO
  • Hostname: $HOSTNAME
  • Username: $USERNAME

Next steps:
1. Reboot: sudo reboot
2. Enter your disk encryption password at boot
3. Login with your configured credentials
4. Your Home Manager configuration will be applied automatically

Note: User accounts and passwords are managed by your flake configuration.

BTRFS Subvolumes created:
  • @root      -> /
  • @home-$USERNAME -> /home/$USERNAME
  • @nix       -> /nix
  • @tmp       -> /tmp
  • @snapshots -> /.snapshots

To create snapshots:
  sudo btrfs subvolume snapshot /home/$USERNAME /.snapshots/home-\$(date +%Y%m%d-%H%M%S)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

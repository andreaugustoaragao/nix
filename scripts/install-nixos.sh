#!/usr/bin/env bash

set -euo pipefail

# NixOS installer
#
# Picks a target machine from machines.toml at runtime, filtering to
# hosts whose hardware/<host>/hardware-configuration.nix matches the
# disk layout this script produces: GPT + EFI + btrfs root at
# /dev/disk/by-label/nixos, no LUKS.
#
# For hosts with a different layout (LUKS, UUID-pinned configs, etc.)
# the partitioning code below would need to grow new branches first.
#
# Override knobs:
#   DISK=/dev/vda  ./install-nixos.sh   # default is /dev/sda
#   TARGET_HOSTNAME=foo ./install-nixos.sh   # skip the menu

DISK="${DISK:-/dev/sda}"
FLAKE_REPO="${FLAKE_REPO:-https://github.com/andreaugustoaragao/nix.git}"
USERNAME="aragao"
USER_FULLNAME="Andre Aragao"
TMP_FLAKE="/tmp/nix-installer-flake"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Pre-flight
if [[ $EUID -eq 0 ]]; then
    error "This script should not be run as root. It will use sudo when needed."
fi
if ! command -v nixos-install >/dev/null; then
    error "This script must be run from a NixOS installer environment"
fi
if ! command -v git >/dev/null; then
    error "git is required (the NixOS installer ships it)"
fi

# Step 0: clone the flake to a temp location so we can read machines.toml
# and hardware/ before deciding what to install.
log "Fetching flake metadata from $FLAKE_REPO"
rm -rf "$TMP_FLAKE"
git clone --depth=1 "$FLAKE_REPO" "$TMP_FLAKE" >/dev/null

# Step 1: discover candidate hosts. A candidate is a directory under
# hardware/ whose hardware-configuration.nix references
# /dev/disk/by-label/nixos (this installer's btrfs layout) and lacks
# any LUKS configuration, AND has a matching entry in machines.toml.
discover_candidates() {
    local hwc host
    for hwc in "$TMP_FLAKE"/hardware/*/hardware-configuration.nix; do
        [[ -f $hwc ]] || continue
        host="$(basename "$(dirname "$hwc")")"
        grep -q '/dev/disk/by-label/nixos' "$hwc" || continue
        ! grep -qE 'luks\.|cryptroot' "$hwc" || continue
        grep -q "^\[machines\.${host}\]" "$TMP_FLAKE/machines.toml" || continue
        echo "$host"
    done
}

mapfile -t candidates < <(discover_candidates)
if [[ ${#candidates[@]} -eq 0 ]]; then
    error "no compatible hosts in $FLAKE_REPO (need hardware-configuration.nix using /dev/disk/by-label/nixos and no LUKS)"
fi

# Step 2: pick a host. Honor TARGET_HOSTNAME if it's a candidate;
# otherwise prompt.
if [[ -n "${TARGET_HOSTNAME:-}" ]]; then
    found=0
    for h in "${candidates[@]}"; do
        [[ $h == "$TARGET_HOSTNAME" ]] && { found=1; break; }
    done
    [[ $found -eq 1 ]] || error "TARGET_HOSTNAME='$TARGET_HOSTNAME' is not a candidate. Available: ${candidates[*]}"
    log "TARGET_HOSTNAME=$TARGET_HOSTNAME (from env)"
else
    echo
    echo "Available machines for this installer (btrfs root, no LUKS):"
    for i in "${!candidates[@]}"; do
        printf "  %d) %s\n" "$((i + 1))" "${candidates[$i]}"
    done
    echo
    read -p "Pick a machine [1-${#candidates[@]}]: " -r choice
    [[ $choice =~ ^[0-9]+$ ]] || error "expected a number"
    (( choice >= 1 && choice <= ${#candidates[@]} )) || error "out of range"
    TARGET_HOSTNAME="${candidates[$((choice - 1))]}"
    log "selected: $TARGET_HOSTNAME"
fi

# Final summary + confirmation
echo
log "Target disk:     $DISK"
log "Target host:     $TARGET_HOSTNAME"
log "Username:        $USERNAME"
log "Flake source:    $FLAKE_REPO"
echo
read -p "This will DESTROY ALL DATA on $DISK. Continue? (yes/no): " -r
[[ $REPLY =~ ^yes$ ]] || error "Installation cancelled"

# Step 3: Partition
log "Partitioning $DISK"
sudo umount -R /mnt 2>/dev/null || true

# Kernel naming: devices whose name already ends in a digit (nvme0n1,
# mmcblk0, loopN) use a `p` separator for partitions; everything else
# (sda, vda) just appends the partition number directly.
case "$DISK" in
    *[0-9]) PART="${DISK}p" ;;
    *)      PART="${DISK}"  ;;
esac

sudo parted "$DISK" --script -- mklabel gpt
sudo parted "$DISK" --script -- mkpart ESP fat32 1MiB 513MiB
sudo parted "$DISK" --script -- set 1 esp on
sudo parted "$DISK" --script -- mkpart primary 513MiB 100%
sudo parted "$DISK" --script -- name 2 nixos

log "Formatting EFI partition (${PART}1)"
sudo mkfs.fat -F 32 -n nixos-boot "${PART}1"

log "Creating btrfs filesystem on ${PART}2"
sudo mkfs.btrfs -f -L nixos "${PART}2"

# Step 4: btrfs subvolumes
log "Creating btrfs subvolumes"
sudo mount /dev/disk/by-label/nixos /mnt
sudo btrfs subvolume create /mnt/@root
sudo btrfs subvolume create /mnt/@nix
sudo btrfs subvolume create /mnt/@tmp
sudo btrfs subvolume create /mnt/@swap
sudo btrfs subvolume create /mnt/@snapshots
sudo btrfs subvolume create "/mnt/@home-$USERNAME"
sudo umount /mnt

# Step 5: mount everything for install
log "Mounting btrfs subvolumes"
BTRFS_OPTS="compress=zstd:1,noatime,space_cache=v2"
sudo mount -o "subvol=@root,$BTRFS_OPTS" /dev/disk/by-label/nixos /mnt
sudo mkdir -p /mnt/{home,nix,tmp,swap,boot,.snapshots}
sudo mkdir -p "/mnt/home/$USERNAME"
sudo mount -o "subvol=@home-$USERNAME,$BTRFS_OPTS" /dev/disk/by-label/nixos "/mnt/home/$USERNAME"
sudo mount -o "subvol=@nix,$BTRFS_OPTS"       /dev/disk/by-label/nixos /mnt/nix
sudo mount -o "subvol=@tmp,$BTRFS_OPTS"       /dev/disk/by-label/nixos /mnt/tmp
sudo mount -o "subvol=@snapshots,$BTRFS_OPTS" /dev/disk/by-label/nixos /mnt/.snapshots
sudo mount "${PART}1" /mnt/boot
sudo chown 1000:100 "/mnt/home/$USERNAME"

# Step 6: generate hardware config (mostly for fallback / inspection;
# the install uses the flake's per-host hardware-configuration.nix)
log "Generating hardware configuration"
sudo nixos-generate-config --root /mnt

# Step 7: place the flake on the target. Move the pre-cloned tree
# rather than re-fetching from the network.
log "Installing flake into /mnt/home/$USERNAME/projects/personal/nix"
sudo mkdir -p "/mnt/home/$USERNAME/projects/personal"
sudo cp -a "$TMP_FLAKE" "/mnt/home/$USERNAME/projects/personal/nix"
sudo chown -R 1000:100 "/mnt/home/$USERNAME/projects"

# /etc/nixos symlink for convenience inside the chroot.
sudo ln -sf "/home/$USERNAME/projects/personal/nix" /mnt/etc/nixos

log "Using filesystem labels: nixos (btrfs root) and nixos-boot (EFI)"

# Step 8: install
log "Installing NixOS for host $TARGET_HOSTNAME"
sudo nixos-install --root /mnt --flake "/mnt/home/$USERNAME/projects/personal/nix#$TARGET_HOSTNAME"

log "Installation completed successfully!"

cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                            INSTALLATION COMPLETE!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Host:           $TARGET_HOSTNAME
Disk:           $DISK
Flake location: /home/$USERNAME/projects/personal/nix
Username:       $USERNAME

Next steps:
1. Reboot: sudo reboot
2. Log in with your configured credentials
3. Home Manager runs automatically on first login

BTRFS subvolumes created:
  • @root             -> /
  • @home-$USERNAME   -> /home/$USERNAME
  • @nix              -> /nix
  • @tmp              -> /tmp
  • @snapshots        -> /.snapshots

To create snapshots:
  sudo btrfs subvolume snapshot /home/$USERNAME /.snapshots/home-\$(date +%Y%m%d-%H%M%S)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

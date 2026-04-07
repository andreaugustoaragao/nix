#!/usr/bin/env bash
set -euo pipefail

# add-age-host-key.sh
# Generates (or uses existing) per-host age key for sops-nix, writes the public
# key to the repo for inclusion as a recipient, and prints migration steps.
#
# Non-destructive: does NOT edit your repo files automatically.
#
# Usage:
#   ./memory/add-age-host-key.sh [--key-file /var/lib/sops-nix/key.txt] [--repo /path/to/repo] [--hostname myhost]
#
# Defaults:
#   key-file: /var/lib/sops-nix/key.txt
#   repo:     git rev-parse --show-toplevel || pwd
#   hostname: hostnamectl --static || hostname -s || hostname

KEYFILE="/var/lib/sops-nix/key.txt"
REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-file)
      KEYFILE="${2:-}"; shift 2;;
    --repo)
      REPO="${2:-}"; shift 2;;
    --hostname)
      HOSTNAME="${2:-}"; shift 2;;
    -h|--help)
      sed -n '1,40p' "$0"; exit 0;;
    *)
      echo "Unknown argument: $1" >&2; exit 2;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    echo "Install it (on NixOS: nix-shell -p $1) and retry." >&2
    exit 1
  }
}

need_cmd age-keygen
need_cmd sops
need_cmd install
need_cmd chmod
need_cmd chown

SUDO=""
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
fi

# Ensure parent dir exists with proper perms when using default path
KEYDIR="$(dirname "$KEYFILE")"
if [[ ! -d "$KEYDIR" ]]; then
  $SUDO mkdir -p "$KEYDIR"
  $SUDO chmod 700 "$KEYDIR" || true
fi

if [[ -f "$KEYFILE" ]]; then
  echo "Found existing age key at: $KEYFILE" >&2
else
  echo "Generating new age key at: $KEYFILE" >&2
  # age-keygen writes private key; ensure root:root 600
  TMPKEY="$(mktemp)"
  age-keygen -o "$TMPKEY" >/dev/null
  $SUDO install -m 600 -o root -g root "$TMPKEY" "$KEYFILE"
  rm -f "$TMPKEY"
  echo "Created $KEYFILE (owner root:root, mode 600)." >&2
fi

# Derive public key
PUBKEY="$($SUDO age-keygen -y -f "$KEYFILE")"
if [[ -z "$PUBKEY" ]]; then
  echo "Failed to derive public key from $KEYFILE" >&2
  exit 1
fi

KEYS_DIR="$REPO/keys"
mkdir -p "$KEYS_DIR"
PUBFILE="$KEYS_DIR/${HOSTNAME}.age.pub"
echo "$PUBKEY" > "$PUBFILE"
chmod 644 "$PUBFILE"

echo
echo "Saved this host's age public key to: $PUBFILE"
echo "$PUBKEY"
echo

cat <<EOF
Next steps (non-destructive):

1) Add this public key as a recipient so this host can decrypt secrets.

   Option A: In a top-level .sops.yaml (recommended)

   .sops.yaml (example):

   creation_rules:
     - path_regex: secrets/.*\\.ya?ml$
       age:
         - $PUBKEY  # $HOSTNAME
       unencrypted_suffix: _unencrypted

   After saving, rewrap keys:

     sops updatekeys secrets/secrets.yaml

   Option B: Add recipient directly to secrets/secrets.yaml

   Under the sops.age: recipients list, add a new recipient line with the key above,
   then run:

     sops updatekeys secrets/secrets.yaml

2) Commit and push the updated recipients and rewrapped file.

3) Verify decryption on this host (should succeed without using the old shared key):

   sops -d secrets/secrets.yaml > /dev/null && echo "Decryption OK on $HOSTNAME"

4) (Later) Switch NixOS config to use this per-host key and allow auto-generation if desired:

   In system/sops.nix (for example):

     sops.age = {
       keyFile = "/var/lib/sops-nix/key.txt";
       generateKey = true;
     };

   Do not apply until step 1-3 are complete for this host.

Notes:
- You can repeat this on other machines, add their public keys as recipients, and rewrap once.
- During migration, keep the old shared recipient present until all hosts are updated; then remove it and run 'sops updatekeys' again.
EOF 
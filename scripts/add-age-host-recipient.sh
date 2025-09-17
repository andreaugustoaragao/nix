#!/usr/bin/env bash
set -euo pipefail

# add-age-host-recipient.sh
# Generates (or uses) a per-host age key for sops-nix, ensures the host's
# public key is present in .sops.yaml creation rules, writes keys/<host>.age.pub,
# and rewraps secrets via `sops updatekeys`.
#
# This script updates your repo files: .sops.yaml and keys/<host>.age.pub.
# It does NOT modify secrets values; only recipients (data key wrapping).
#
# Usage:
#   ./scripts/add-age-host-recipient.sh \
#     [--key-file /var/lib/sops-nix/key.txt] \
#     [--repo /path/to/repo] \
#     [--hostname myhost] \
#     [--sops-yaml .sops.yaml] \
#     [--secrets-file secrets/secrets.yaml] \
#     [--no-updatekeys]
#
# Defaults:
#   key-file:      /var/lib/sops-nix/key.txt
#   repo:          git rev-parse --show-toplevel || pwd
#   hostname:      hostnamectl --static || hostname -s || hostname
#   sops-yaml:     $REPO/.sops.yaml
#   secrets-file:  $REPO/secrets/secrets.yaml

KEYFILE="/var/lib/sops-nix/key.txt"
REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null)"
SOPS_YAML=""
SECRETS_FILE=""
DO_UPDATEKEYS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-file)
      KEYFILE="${2:-}"; shift 2;;
    --repo)
      REPO="${2:-}"; shift 2;;
    --hostname)
      HOSTNAME="${2:-}"; shift 2;;
    --sops-yaml)
      SOPS_YAML="${2:-}"; shift 2;;
    --secrets-file)
      SECRETS_FILE="${2:-}"; shift 2;;
    --no-updatekeys)
      DO_UPDATEKEYS=0; shift;;
    -h|--help)
      sed -n '1,80p' "$0"; exit 0;;
    *)
      echo "Unknown argument: $1" >&2; exit 2;;
  esac
done

if [[ -z "$SOPS_YAML" ]]; then
  SOPS_YAML="$REPO/.sops.yaml"
fi
if [[ -z "$SECRETS_FILE" ]]; then
  SECRETS_FILE="$REPO/secrets/secrets.yaml"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd age-keygen
need_cmd sops

SUDO=""
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
fi

# Ensure parent dir exists for the key and has sane perms
KEYDIR="$(dirname "$KEYFILE")"
if [[ ! -d "$KEYDIR" ]]; then
  $SUDO mkdir -p "$KEYDIR"
  $SUDO chmod 700 "$KEYDIR" || true
fi

# Generate key if missing, keep root-only perms
if [[ -f "$KEYFILE" ]]; then
  echo "Found existing age key at: $KEYFILE" >&2
else
  echo "Generating new age key at: $KEYFILE" >&2
  TMPKEY="$(mktemp)"
  age-keygen -o "$TMPKEY" >/dev/null
  $SUDO install -m 600 -o root -g root "$TMPKEY" "$KEYFILE"
  rm -f "$TMPKEY"
  echo "Created $KEYFILE (owner root:root, mode 600)." >&2
fi

# Derive public key string
PUBKEY="$($SUDO age-keygen -y "$KEYFILE")"
if [[ -z "$PUBKEY" ]]; then
  echo "Failed to derive public key from $KEYFILE" >&2
  exit 1
fi

# Save public key for mapping
KEYS_DIR="$REPO/keys"
mkdir -p "$KEYS_DIR"
PUBFILE="$KEYS_DIR/${HOSTNAME}.age.pub"
echo "$PUBKEY" > "$PUBFILE"
chmod 644 "$PUBFILE"

echo "Saved public key to: $PUBFILE" >&2

# Update or create .sops.yaml using ruamel.yaml to avoid yq incompatibilities
update_sops_yaml() {
  local py_script
  py_script="$(mktemp)"
  cat >"$py_script" <<'PY'
import sys, os
from ruamel.yaml import YAML

path = sys.argv[1]
pubkey = sys.argv[2]
regex = r"secrets/.*\\.ya?ml$"

yaml = YAML()
yaml.preserve_quotes = True
try:
    with open(path, 'r') as f:
        data = yaml.load(f) or {}
except FileNotFoundError:
    data = {}

if not isinstance(data, dict):
    data = {}

cr = data.get('creation_rules')
if not isinstance(cr, list):
    cr = []
    data['creation_rules'] = cr

rule = None
for r in cr:
    if isinstance(r, dict) and r.get('path_regex') == regex:
        rule = r
        break

if rule is None:
    rule = {'path_regex': regex, 'age': [], 'unencrypted_suffix': '_unencrypted'}
    cr.append(rule)

age_list = rule.get('age')
if not isinstance(age_list, list):
    age_list = []
    rule['age'] = age_list

if pubkey not in age_list:
    age_list.append(pubkey)

with open(path, 'w') as f:
    yaml.dump(data, f)
PY

  if command -v nix >/dev/null 2>&1; then
    nix shell nixpkgs#python3Packages.ruamel-yaml -c python3 "$py_script" "$SOPS_YAML" "$PUBKEY"
  else
    python3 "$py_script" "$SOPS_YAML" "$PUBKEY"
  fi
  rm -f "$py_script"
}

update_sops_yaml

echo "Updated $SOPS_YAML to include this host recipient." >&2

# Rewrap secrets to include the new recipient set
if [[ "$DO_UPDATEKEYS" -eq 1 ]]; then
  if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Warning: $SECRETS_FILE not found; skipping updatekeys." >&2
  else
    sops updatekeys "$SECRETS_FILE"
    echo "Rewrapped keys in: $SECRETS_FILE" >&2
  fi
fi

echo
echo "Done. Verify decryption on this host:"
echo "  sops -d $SECRETS_FILE > /dev/null && echo 'Decryption OK on $HOSTNAME'" 
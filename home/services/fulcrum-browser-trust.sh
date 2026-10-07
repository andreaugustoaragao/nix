#!/usr/bin/env bash
set -euo pipefail

certificate=${1:?Expected public certificate path}
database=${2:?Expected NSS database directory}
nickname=${3:?Expected managed certificate nickname}
expected_fingerprint=${4:?Expected SHA-256 certificate fingerprint}

if [[ "$certificate" != /* || "$database" != /* || "$database" == / \
  || ! "$nickname" =~ ^fulcrum-local-https-[a-zA-Z0-9-]+$ \
  || ! "$expected_fingerprint" =~ ^[A-F0-9]{64}$ ]]; then
  echo 'Invalid Fulcrum trust configuration' >&2
  exit 1
fi

fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':'
}

# Freeze the public input: rotation during import must not install unpinned trust.
umask 077
certificate_snapshot=$(mktemp "${TMPDIR:-/tmp}/fulcrum-trust-certificate.XXXXXX")
trap 'rm -f -- "$certificate_snapshot"' EXIT
cp -- "$certificate" "$certificate_snapshot"

# Check the full validity period and localhost identity before any NSS writes.
openssl verify -trusted "$certificate_snapshot" -partial_chain -purpose sslserver \
  -verify_hostname localhost "$certificate_snapshot" >/dev/null
if [[ "$(fingerprint "$certificate_snapshot")" != "$expected_fingerprint" ]]; then
  echo 'Fulcrum certificate changed; review certificate rotation before updating trust' >&2
  exit 1
fi

if [[ ! -d "$database" ]]; then
  install -d -m 700 "$database"
fi
if [[ ! -f "$database/cert9.db" ]]; then
  if [[ -e "$database/key4.db" || -e "$database/cert8.db" || -e "$database/key3.db" ]]; then
    echo 'Existing NSS database needs explicit migration; leaving it unchanged' >&2
    exit 1
  fi
  certutil -N --empty-password -d "sql:$database"
fi

current_trust=$(certutil -L -d "sql:$database" | awk -v name="$nickname" '$1 == name {print $2}')
if [[ -n "$current_trust" ]]; then
  current_fingerprint=$(certutil -L -d "sql:$database" -n "$nickname" -a | \
    openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
  if [[ "$current_fingerprint" != "$expected_fingerprint" ]]; then
    echo 'Managed NSS nickname contains another certificate; review rotation before replacing it' >&2
    exit 1
  fi
  if [[ "$current_trust" == 'P,,' ]]; then
    echo 'Fulcrum exact-server HTTPS trust is already configured'
    exit 0
  fi
  certutil -M -d "sql:$database" -n "$nickname" -t 'P,,'
else
  certutil -A -d "sql:$database" -n "$nickname" -t 'P,,' -i "$certificate_snapshot"
fi

actual_fingerprint=$(certutil -L -d "sql:$database" -n "$nickname" -a | \
  openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
actual_trust=$(certutil -L -d "sql:$database" | awk -v name="$nickname" '$1 == name {print $2}')
if [[ "$actual_fingerprint" != "$expected_fingerprint" || "$actual_trust" != 'P,,' ]]; then
  echo 'Fulcrum peer trust verification failed' >&2
  exit 1
fi
echo 'Configured Fulcrum exact-server HTTPS trust (not certificate-authority trust)'

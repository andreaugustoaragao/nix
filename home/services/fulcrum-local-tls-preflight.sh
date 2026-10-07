#!/usr/bin/env bash
set -euo pipefail

mode=${1:?Expected ca or server mode}
ca_source=${2:?Expected public CA certificate}
ca_pin=${3:?Expected CA SHA-256 fingerprint}
if [[ ! "$mode" =~ ^(ca|server)$ || "$ca_source" != /* || ! "$ca_pin" =~ ^[A-F0-9]{64}$ ]]; then
  echo 'Invalid Fulcrum local TLS configuration' >&2
  exit 1
fi
if [[ "$mode" == ca && $# != 3 || "$mode" == server && $# != 7 ]]; then
  echo 'Invalid Fulcrum local TLS argument count' >&2
  exit 1
fi

fail() { echo "Fulcrum local TLS preflight: $1" >&2; exit 1; }
fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':'
}
snapshot_certificate() {
  local source=$1 destination=$2
  [[ -f "$source" && $(stat -Lc %s -- "$source") -le 16384 ]] || fail 'expected one small regular public certificate'
  cp -- "$source" "$destination"
  [[ $(stat -c %s -- "$destination") -le 16384 ]] || fail 'public certificate exceeds 16 KiB'
  [[ $(grep -c '^-----BEGIN CERTIFICATE-----$' "$destination") == 1 ]] || fail 'expected exactly one public certificate'
  [[ $(grep -c '^-----END CERTIFICATE-----$' "$destination") == 1 ]] || fail 'public certificate is incomplete'
  if grep -q 'PRIVATE KEY' "$destination"; then fail 'certificate input contains private-key material'; fi
}

umask 077
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fulcrum-local-tls.XXXXXX")
trap 'rm -f -- "$scratch/ca.pem" "$scratch/leaf.pem"; rmdir -- "$scratch"' EXIT
snapshot_certificate "$ca_source" "$scratch/ca.pem"
[[ $(fingerprint "$scratch/ca.pem") == "$ca_pin" ]] || fail 'CA fingerprint differs from the reviewed pin'
openssl x509 -in "$scratch/ca.pem" -noout -ext basicConstraints | grep -Eq '^[[:space:]]*CA:TRUE, pathlen:0[[:space:]]*$' ||
  fail 'dedicated CA must have CA:TRUE and pathlen:0'
openssl x509 -in "$scratch/ca.pem" -noout -ext keyUsage | grep -Fq 'Certificate Sign' ||
  fail 'dedicated CA cannot sign certificates'
openssl verify -CAfile "$scratch/ca.pem" -no-CApath -no-CAstore -x509_strict -check_ss_sig "$scratch/ca.pem" >/dev/null ||
  fail 'CA signature or full validity period is invalid'
if [[ "$mode" == ca ]]; then exit 0; fi

leaf_source=$4 leaf_pin=$5 server_key=$6 host=$7
[[ "$leaf_source" == /* && "$server_key" == /* && "$leaf_pin" =~ ^[A-F0-9]{64}$ && "$host" =~ ^[a-zA-Z0-9-]+$ ]] ||
  fail 'invalid server certificate configuration'
snapshot_certificate "$leaf_source" "$scratch/leaf.pem"
[[ $(fingerprint "$scratch/leaf.pem") == "$leaf_pin" ]] || fail 'server certificate differs from the reviewed exact-leaf pin'
openssl x509 -in "$scratch/leaf.pem" -noout -ext basicConstraints | grep -Eq '^[[:space:]]*CA:FALSE[[:space:]]*$' ||
  fail 'server certificate must explicitly have CA:FALSE'
openssl x509 -in "$scratch/leaf.pem" -noout -ext extendedKeyUsage | grep -Fq 'TLS Web Server Authentication' ||
  fail 'server certificate must explicitly permit serverAuth'
san=$(openssl x509 -in "$scratch/leaf.pem" -noout -ext subjectAltName)
for name in localhost fulcrum.local "$host.local"; do
  [[ "$san" == *"DNS:$name,"* || "$san" == *"DNS:$name" ]] || fail "missing exact DNS SAN: $name"
  openssl verify -CAfile "$scratch/ca.pem" -no-CApath -no-CAstore -x509_strict -purpose sslserver \
    -verify_hostname "$name" "$scratch/leaf.pem" >/dev/null || fail "server chain or validity failed for $name"
done
for address in 127.0.0.1 ::1; do
  openssl verify -CAfile "$scratch/ca.pem" -no-CApath -no-CAstore -x509_strict -purpose sslserver \
    -verify_ip "$address" "$scratch/leaf.pem" >/dev/null || fail "missing valid loopback IP SAN: $address"
done
[[ -f "$server_key" ]] || fail 'server key must be a regular runtime file'
key_mode=$(stat -Lc %a -- "$server_key")
(( (8#$key_mode & 077) == 0 )) || fail 'server key must not be accessible by group or others'
leaf_public=$(openssl x509 -in "$scratch/leaf.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
key_public=$(openssl pkey -in "$server_key" -passin pass: -pubout -outform DER | sha256sum | cut -d' ' -f1)
[[ "$leaf_public" == "$key_public" ]] || fail 'server certificate and private key do not match'
echo 'Fulcrum local TLS preflight passed'

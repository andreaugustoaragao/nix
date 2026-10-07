#!/usr/bin/env bash
set -euo pipefail

preflight=${1:?Expected preflight script or executable}
browser_trust=${2:?Expected existing exact-leaf browser trust script}
umask 077
fixture=$(mktemp -d /tmp/fulcrum-local-ca-test.XXXXXX)
trap 'printf "Local CA fixture evidence: %s\n" "$fixture"' EXIT
mkdir "$fixture/tmp"
export TMPDIR="$fixture/tmp"

fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':'
}
make_ca() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc -days 2 \
    -subj '/CN=Fulcrum isolated test CA' -keyout "$fixture/$1.key" -out "$fixture/$1.pem" \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' >>"$fixture/openssl.log" 2>&1
}
issue_leaf() {
  local name=$1 constraints=$2 usage=$3 sans=$4 signer=${5:-ca}
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc -subj /CN=localhost \
    -keyout "$fixture/$name.key" -out "$fixture/$name.csr" >>"$fixture/openssl.log" 2>&1
  openssl x509 -req -in "$fixture/$name.csr" -CA "$fixture/$signer.pem" -CAkey "$fixture/$signer.key" \
    -set_serial "$((++serial))" -days 1 -out "$fixture/$name.pem" \
    -extfile <(printf '%s\n' "basicConstraints=critical,$constraints" 'keyUsage=critical,digitalSignature' \
      "extendedKeyUsage=$usage" "subjectAltName=$sans" 'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid,issuer') \
    >>"$fixture/openssl.log" 2>&1
}
check_server() {
  bash "$preflight" server "$fixture/ca.pem" "$ca_pin" "$fixture/$1.pem" \
    "$(fingerprint "$fixture/$1.pem")" "$fixture/${2:-$1}.key" prl-dev-vm
}
reject() {
  local name=$1 message=$2
  shift 2
  if "$@" >"$fixture/$name.log" 2>&1; then
    echo "FAIL: accepted $name" >&2; exit 1
  fi
  grep -Fq -- "$message" "$fixture/$name.log"
}

serial=10
make_ca ca
make_ca foreign
ca_pin=$(fingerprint "$fixture/ca.pem")
sans='DNS:localhost,DNS:fulcrum.local,DNS:prl-dev-vm.local,IP:127.0.0.1,IP:::1'
issue_leaf valid CA:FALSE serverAuth "$sans"
bash "$preflight" ca "$fixture/ca.pem" "$ca_pin"
check_server valid
before=$(sha256sum "$fixture/ca.pem" "$fixture/valid.pem" "$fixture/valid.key")
check_server valid
test "$before" = "$(sha256sum "$fixture/ca.pem" "$fixture/valid.pem" "$fixture/valid.key")"

reject wrong-ca-pin 'CA fingerprint differs' bash "$preflight" ca "$fixture/ca.pem" "$(printf '%064d' 0)"
reject wrong-leaf-pin 'server certificate differs' bash "$preflight" server "$fixture/ca.pem" "$ca_pin" \
  "$fixture/valid.pem" "$(printf '%064d' 0)" "$fixture/valid.key" prl-dev-vm
reject mismatched-key 'do not match' check_server valid ca
cp "$fixture/valid.key" "$fixture/readable.key"
chmod 0644 "$fixture/readable.key"
reject readable-key 'must not be accessible' check_server valid readable
mkfifo "$fixture/pipe.key"
reject pipe-key 'regular runtime file' check_server valid pipe

issue_leaf capable CA:TRUE serverAuth "$sans"
reject ca-capable-leaf 'must explicitly have CA:FALSE' check_server capable
issue_leaf client CA:FALSE clientAuth "$sans"
reject client-only 'must explicitly permit serverAuth' check_server client
issue_leaf missing-san CA:FALSE serverAuth 'DNS:other.invalid'
reject common-name-fallback 'missing exact DNS SAN: localhost' check_server missing-san
issue_leaf no-ipv6 CA:FALSE serverAuth 'DNS:localhost,DNS:fulcrum.local,DNS:prl-dev-vm.local,IP:127.0.0.1'
reject no-ipv6 'missing valid loopback IP SAN: ::1' check_server no-ipv6
issue_leaf foreign-leaf CA:FALSE serverAuth "$sans" foreign
reject untrusted-signer 'server chain or validity failed' check_server foreign-leaf

for validity in expired future; do
  if [[ "$validity" == expired ]]; then
    start=20200101000000Z end=20200102000000Z
  else
    start=20990101000000Z end=20990102000000Z
  fi
  openssl x509 -in "$fixture/valid.pem" -CA "$fixture/ca.pem" -CAkey "$fixture/ca.key" \
    -not_before "$start" -not_after "$end" -set_serial "$((++serial))" -out "$fixture/$validity.pem"
  reject "$validity-leaf" 'server chain or validity failed' check_server "$validity" valid
  openssl x509 -in "$fixture/ca.pem" -signkey "$fixture/ca.key" \
    -not_before "$start" -not_after "$end" -set_serial "$((++serial))" -out "$fixture/$validity-ca.pem"
  reject "$validity-ca" 'CA signature or full validity period is invalid' bash "$preflight" ca \
    "$fixture/$validity-ca.pem" "$(fingerprint "$fixture/$validity-ca.pem")"
done
cp "$fixture/ca.pem" "$fixture/combined.pem"
cat "$fixture/foreign.pem" >>"$fixture/combined.pem"
reject multiple-ca 'exactly one public certificate' bash "$preflight" ca "$fixture/combined.pem" "$ca_pin"

# Chromium continues to trust only the selected CA:false server leaf. Its
# issuer is never imported as a browser CA, even though desktop trusts that CA.
mkdir "$fixture/nss"
certutil -N --empty-password -d "sql:$fixture/nss"
nickname=fulcrum-local-https-isolated-ca-v1
bash "$browser_trust" "$fixture/valid.pem" "$fixture/nss" "$nickname" "$(fingerprint "$fixture/valid.pem")"
certutil -V -d "sql:$fixture/nss" -n "$nickname" -u V
test "$(certutil -L -d "sql:$fixture/nss" | awk -v name="$nickname" '$1 == name {print $2}')" = 'P,,'
issue_leaf rotated CA:FALSE serverAuth "$sans"
check_server rotated
certutil -A -d "sql:$fixture/nss" -n unpinned-rotation -t ',,' -i "$fixture/rotated.pem"
if certutil -V -d "sql:$fixture/nss" -n unpinned-rotation -u V >"$fixture/unpinned-rotation.log" 2>&1; then
  echo 'FAIL: browser exact-leaf trust delegated to the issuer' >&2; exit 1
fi
echo 'PASS: scoped CA/leaf preflight, validity, identity, key pairing, key permissions and exact-leaf browser separation'

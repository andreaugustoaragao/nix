#!/usr/bin/env bash
set -euo pipefail

trust_script=${1:?Usage: test.sh trust-script}
fixture=$(mktemp -d /tmp/fulcrum-nss-test.XXXXXX)
trap 'printf "Trust test evidence: %s\n" "$fixture"' EXIT
mkdir "$fixture/db"
certutil -N --empty-password -d "sql:$fixture/db"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext 'subjectAltName=DNS:localhost' -addext 'basicConstraints=critical,CA:TRUE' \
  -keyout "$fixture/root.key" -out "$fixture/root.pem" >"$fixture/openssl.log" 2>&1
fingerprint=$(openssl x509 -in "$fixture/root.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
nickname=fulcrum-local-https-test

if certutil -L -d "sql:$fixture/db" -n "$nickname" >/dev/null 2>&1; then
  echo 'Unexpected existing test certificate' >&2
  exit 1
fi
bash "$trust_script" "$fixture/root.pem" "$fixture/db" "$nickname" "$fingerprint"
certutil -V -d "sql:$fixture/db" -n "$nickname" -u V
test "$(certutil -L -d "sql:$fixture/db" | awk -v name="$nickname" '$1 == name {print $2}')" = 'P,,'
before=$(sha256sum "$fixture/db/cert9.db")
bash "$trust_script" "$fixture/root.pem" "$fixture/db" "$nickname" "$fingerprint"
test "$before" = "$(sha256sum "$fixture/db/cert9.db")"

# A CA-capable peer must not become a signing authority for other certificates.
openssl req -new -newkey rsa:2048 -nodes -subj /CN=unrelated.example \
  -keyout "$fixture/child.key" -out "$fixture/child.csr" >>"$fixture/openssl.log" 2>&1
openssl x509 -req -in "$fixture/child.csr" -CA "$fixture/root.pem" -CAkey "$fixture/root.key" \
  -set_serial 2 -days 1 -out "$fixture/child.pem" >>"$fixture/openssl.log" 2>&1
certutil -A -d "sql:$fixture/db" -n unrelated-child -t ',,' -i "$fixture/child.pem"
if certutil -V -d "sql:$fixture/db" -n unrelated-child -u V >"$fixture/child-validation.log" 2>&1; then
  echo 'Peer trust incorrectly grants certificate-authority trust' >&2
  exit 1
fi

# Positive control: the child is a valid chain when the parent is really a CA.
certutil -M -d "sql:$fixture/db" -n "$nickname" -t 'C,,'
certutil -V -d "sql:$fixture/db" -n unrelated-child -u V
bash "$trust_script" "$fixture/root.pem" "$fixture/db" "$nickname" "$fingerprint"
test "$(certutil -L -d "sql:$fixture/db" | awk -v name="$nickname" '$1 == name {print $2}')" = 'P,,'
if certutil -V -d "sql:$fixture/db" -n unrelated-child -u V >"$fixture/child-validation-after-downgrade.log" 2>&1; then
  echo 'CA trust was not downgraded to peer-only trust' >&2
  exit 1
fi

# A pin mismatch must not write anything to the trust store.
openssl x509 -in "$fixture/root.pem" -signkey "$fixture/root.key" \
  -set_serial 4 -days 1 -out "$fixture/other-localhost.pem"
before=$(sha256sum "$fixture/db/cert9.db")
if bash "$trust_script" "$fixture/other-localhost.pem" "$fixture/db" "$nickname" "$fingerprint" >"$fixture/pin-mismatch.log" 2>&1; then
  echo 'Mismatched certificate was accepted' >&2
  exit 1
fi
grep -F 'Fulcrum certificate changed' "$fixture/pin-mismatch.log" >/dev/null
test "$before" = "$(sha256sum "$fixture/db/cert9.db")"
certutil -L -d "sql:$fixture/db" -n unrelated-child >/dev/null
test "$(certutil -L -d "sql:$fixture/db" | awk '$1 == "unrelated-child" {print $2}')" = ',,'

# An occupied managed name with a different certificate is not silently replaced.
mkdir "$fixture/occupied-db"
certutil -N --empty-password -d "sql:$fixture/occupied-db"
certutil -A -d "sql:$fixture/occupied-db" -n fulcrum-local-https-occupied -t ',,' -i "$fixture/child.pem"
before=$(sha256sum "$fixture/occupied-db/cert9.db")
if bash "$trust_script" "$fixture/root.pem" "$fixture/occupied-db" fulcrum-local-https-occupied "$fingerprint" >"$fixture/occupied.log" 2>&1; then
  echo 'Occupied nickname was overwritten' >&2
  exit 1
fi
test "$before" = "$(sha256sum "$fixture/occupied-db/cert9.db")"

for validity in future expired; do
  if [[ "$validity" == future ]]; then
    start=20990101000000Z
    end=20990102000000Z
  else
    start=20200101000000Z
    end=20200102000000Z
  fi
  openssl x509 -in "$fixture/root.pem" -signkey "$fixture/root.key" \
    -not_before "$start" -not_after "$end" -set_serial 3 -out "$fixture/$validity.pem"
  invalid_fingerprint=$(openssl x509 -in "$fixture/$validity.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
  if bash "$trust_script" "$fixture/$validity.pem" "$fixture/$validity-db" "$nickname" "$invalid_fingerprint" >"$fixture/$validity.log" 2>&1; then
    echo 'Certificate outside its validity period was accepted' >&2
    exit 1
  fi
  test ! -e "$fixture/$validity-db"
done

# Rotate the original source at the import boundary. Only the frozen input may
# be imported; a successful run must not depend on the mutable runtime path.
cp "$fixture/root.pem" "$fixture/race-source.pem"
(
  export FULCRUM_TRUST_TEST_SOURCE="$fixture/race-source.pem"
  export FULCRUM_TRUST_TEST_REPLACEMENT="$fixture/child.pem"
  certutil() {
    if [[ "$1" == -A ]]; then
      cp "$FULCRUM_TRUST_TEST_REPLACEMENT" "$FULCRUM_TRUST_TEST_SOURCE"
    fi
    command certutil "$@"
  }
  export -f certutil
  bash "$trust_script" "$fixture/race-source.pem" "$fixture/fresh-db" "$nickname" "$fingerprint"
)
cmp "$fixture/race-source.pem" "$fixture/child.pem"
actual=$(certutil -L -d "sql:$fixture/fresh-db" -n "$nickname" -a | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
test "$actual" = "$fingerprint"
echo 'PASS: exact SSL peer trust, no delegated CA trust, idempotence, pin rejection, occupied-name preservation, CA downgrade and source-rotation safety'

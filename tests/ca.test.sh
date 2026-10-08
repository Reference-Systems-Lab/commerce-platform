#!/bin/sh
# Tests scripts/ca.sh in a temporary directory: the root's constraints, the leaf, that names outside
# rsl-commerce.test are refused, idempotence, the reissue rules and file modes.
# Runs anywhere scripts/ca.sh does, including macOS with LibreSSL (set OPENSSL to choose the binary).
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

OPENSSL=${OPENSSL:-openssl}
export OPENSSL
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export RSL_CERTS_DIR="$T/certs"
CA=$RSL_CERTS_DIR/ca
LEAF=$RSL_CERTS_DIR/leaf

failures=0
pass() { printf 'ok    %s\n' "$1"; }
flunk() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
check() { # check <description> <command...>
  d=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else flunk "$d"; fi
}
refuse() { # refuse <description> <command...>: passes when the command fails
  d=$1
  shift
  if "$@" >/dev/null 2>&1; then flunk "$d"; else pass "$d"; fi
}
text() { "$OPENSSL" x509 -noout -text -in "$1"; }
hash_of() { cat "$@" | cksum; }
mode_of() { ls -ld "$1" | cut -c1-10; }

# sign_bad <name> <subjectAltName>: a leaf for a name the root must not vouch for, signed with its key.
sign_bad() {
  "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$T/$1.key"
  printf '[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = %s\n[x]\nbasicConstraints = critical, CA:FALSE\nextendedKeyUsage = serverAuth\nsubjectAltName = %s\n' "$1" "$2" >"$T/$1.cnf"
  "$OPENSSL" req -new -sha256 -key "$T/$1.key" -config "$T/$1.cnf" -out "$T/$1.csr"
  "$OPENSSL" x509 -req -sha256 -in "$T/$1.csr" -CA "$CA/rootCA.pem" -CAkey "$CA/rootCA-key.pem" \
    -set_serial 0x1234 -days 1 -extfile "$T/$1.cnf" -extensions x -out "$T/$1.pem" 2>/dev/null
}

echo "# create"
out=$(sh scripts/ca.sh)
check "creates the root" test -f "$CA/rootCA.pem"
check "creates the leaf" test -f "$LEAF/cert.pem"
case $out in *"created root CA"*) pass "reports the new root" ;; *) flunk "reports the new root" ;; esac

echo "# root"
rt=$(text "$CA/rootCA.pem")
check "root is a CA limited to one level" sh -c 'printf "%s" "$1" | grep -q "CA:TRUE, pathlen:0"' _ "$rt"
check "root signs only certificates and CRLs" sh -c 'printf "%s" "$1" | grep -q "Certificate Sign, CRL Sign"' _ "$rt"
check "name constraints are critical" sh -c 'printf "%s" "$1" | grep -q "Name Constraints: critical"' _ "$rt"
check "permits only rsl-commerce.test" sh -c 'printf "%s" "$1" | grep -q "DNS:rsl-commerce.test"' _ "$rt"
check "excludes every IPv4 address" sh -c 'printf "%s" "$1" | grep -q "IP:0.0.0.0/0.0.0.0"' _ "$rt"
check "excludes every IPv6 address" sh -c 'printf "%s" "$1" | grep -Eq "IP:(0:){7}0/(0:){7}0|IP:::/::"' _ "$rt"
check "root lasts at least 824 days" "$OPENSSL" x509 -checkend $((824 * 86400)) -noout -in "$CA/rootCA.pem"
refuse "root lasts at most 825 days" "$OPENSSL" x509 -checkend $((826 * 86400)) -noout -in "$CA/rootCA.pem"

echo "# leaf"
lt=$(text "$LEAF/cert.pem")
sans=$(printf '%s' "$lt" | sed -n '/Subject Alternative Name/{n;p;}' | tr ',' '\n' | sed 's/^ *DNS://' | sed '/^ *$/d' | sort | tr '\n' ' ')
# shellcheck disable=SC2086 # split the host list on purpose
want=$(printf '%s\n' $RSL_HOSTS | sort | tr '\n' ' ')
check "leaf names exactly the 8 hosts" test "$sans" = "$want"
check "leaf is for TLS servers" sh -c 'printf "%s" "$1" | grep -q "TLS Web Server Authentication"' _ "$lt"
check "leaf is not a CA" sh -c 'printf "%s" "$1" | grep -q "CA:FALSE"' _ "$lt"
check "leaf verifies against the root" "$OPENSSL" verify -CAfile "$CA/rootCA.pem" "$LEAF/cert.pem"
check "leaf lasts at most 397 days" sh -c '! "$1" x509 -checkend $((398 * 86400)) -noout -in "$2"' _ "$OPENSSL" "$LEAF/cert.pem"

echo "# the root refuses other names"
sign_bad other "DNS:www.example.com"
sign_bad localhost "DNS:localhost"
sign_bad ipv4 "IP:127.0.0.1"
sign_bad ipv6 "IP:::1"
sign_bad mixed "DNS:rsl-commerce.test, IP:127.0.0.1"
refuse "rejects www.example.com" "$OPENSSL" verify -CAfile "$CA/rootCA.pem" "$T/other.pem"
refuse "rejects localhost" "$OPENSSL" verify -CAfile "$CA/rootCA.pem" "$T/localhost.pem"
refuse "rejects an IPv4 address" "$OPENSSL" verify -CAfile "$CA/rootCA.pem" "$T/ipv4.pem"
refuse "rejects an IPv6 address" "$OPENSSL" verify -CAfile "$CA/rootCA.pem" "$T/ipv6.pem"
refuse "rejects a permitted name smuggling an IP" "$OPENSSL" verify -CAfile "$CA/rootCA.pem" "$T/mixed.pem"

echo "# modes"
check "ca directory is 700" test "$(mode_of "$CA")" = drwx------
check "root key is 600" test "$(mode_of "$CA/rootCA-key.pem")" = -rw-------
check "leaf directory is 755" test "$(mode_of "$LEAF")" = drwxr-xr-x
check "leaf key is 644 (readable by the proxy's uid)" test "$(mode_of "$LEAF/key.pem")" = -rw-r--r--

echo "# idempotent"
before=$(hash_of "$CA/rootCA.pem" "$CA/rootCA-key.pem" "$LEAF/cert.pem" "$LEAF/key.pem")
out=$(sh scripts/ca.sh)
after=$(hash_of "$CA/rootCA.pem" "$CA/rootCA-key.pem" "$LEAF/cert.pem" "$LEAF/key.pem")
check "a second run changes nothing" test "$before" = "$after"
case $out in *"kept root CA"*"kept certificate"*) pass "reports both kept" ;; *) flunk "reports both kept" ;; esac

echo "# reissue rules"
root_hash=$(hash_of "$CA/rootCA.pem")
reissued() { # reissued <description>: ca.sh issued a new leaf and kept the root
  out=$(sh scripts/ca.sh)
  case $out in *"issued certificate"*) pass "$1" ;; *) flunk "$1" ;; esac
  check "$1: keeps the root" test "$(hash_of "$CA/rootCA.pem")" = "$root_hash"
  check "$1: new leaf verifies" "$OPENSSL" verify -CAfile "$CA/rootCA.pem" "$LEAF/cert.pem"
}
rm "$LEAF/key.pem"
reissued "missing key"
"$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$LEAF/key.pem"
reissued "key that doesn't match"
cp "$T/other.pem" "$LEAF/cert.pem"
reissued "certificate for other hosts"
rm "$LEAF/cert.pem"
RSL_LEAF_DAYS=10 sh scripts/ca.sh >/dev/null
refuse "test setup: the leaf now expires within 30 days" "$OPENSSL" x509 -checkend $((30 * 86400)) -noout -in "$LEAF/cert.pem"
reissued "certificate expiring within 30 days"

echo "# root rotation"
rm -rf "$RSL_CERTS_DIR"
RSL_ROOT_DAYS=400 sh scripts/ca.sh >/dev/null
old_root=$(hash_of "$CA/rootCA.pem")
out=$(sh scripts/ca.sh)
case $out in *"replaced root CA"*) pass "replaces a root with under 427 days left" ;; *) flunk "replaces a root with under 427 days left" ;; esac
check "the new root differs" test "$(hash_of "$CA/rootCA.pem")" != "$old_root"
case $out in *"make trust"*) pass "asks to trust the new root" ;; *) flunk "asks to trust the new root" ;; esac
check "the leaf moved to the new root" "$OPENSSL" verify -CAfile "$CA/rootCA.pem" "$LEAF/cert.pem"

echo
if [ "$failures" -eq 0 ]; then
  echo "ca.test.sh: all checks passed"
else
  echo "ca.test.sh: $failures check(s) failed"
  exit 1
fi

#!/bin/sh
# Tests scripts/ca.sh in a temporary directory: the root's constraints, the leaf, that names outside
# rsl-commerce.test are refused, idempotence, the reissue rules and file modes.
# Runs anywhere scripts/ca.sh does, including macOS with LibreSSL (set OPENSSL to choose the binary).
# shellcheck disable=SC2016 # sh -c programs below read their arguments as $1, $2
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
# shellcheck disable=SC2012 # ls is the portable way to read a mode; stat differs between GNU and BSD
mode_of() { ls -ld "$1" | cut -c1-10; }

# sign_bad <name> <subjectAltName> [extendedKeyUsage] [ca-dir]: a leaf the root must not vouch for,
# signed with the key in ca-dir (the platform's root by default).
sign_bad() {
  ca=${4:-$CA}
  "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$T/$1.key"
  printf '[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = %s\n[x]\nbasicConstraints = critical, CA:FALSE\nextendedKeyUsage = %s\nsubjectAltName = %s\n' "$1" "${3:-serverAuth}" "$2" >"$T/$1.cnf"
  "$OPENSSL" req -new -sha256 -key "$T/$1.key" -config "$T/$1.cnf" -out "$T/$1.csr"
  "$OPENSSL" x509 -req -sha256 -in "$T/$1.csr" -CA "$ca/rootCA.pem" -CAkey "$ca/rootCA-key.pem" \
    -set_serial 0x1234 -days 1 -extfile "$T/$1.cnf" -extensions x -out "$T/$1.pem" 2>/dev/null
}

# constraints <certificate text>: the name constraints, one "permitted <name>" or "excluded <name>" a line.
constraints() {
  printf '%s\n' "$1" | awk '
    /Name Constraints/ { on = 1; next }
    on && /Permitted:/ { part = "permitted"; next }
    on && /Excluded:/ { part = "excluded"; next }
    on && /X509v3|Signature|Authority/ { on = 0 }
    on && part { gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "") print part " " $0 }'
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
nc=$(constraints "$rt")
check "permits exactly one name, rsl-commerce.test" test "$(printf '%s\n' "$nc" | grep '^permitted ')" = "permitted DNS:$RSL_DOMAIN"
check "excludes every IPv4 address" sh -c 'printf "%s\n" "$1" | grep -qx "excluded IP:0.0.0.0/0.0.0.0"' _ "$nc"
check "excludes every IPv6 address" sh -c 'printf "%s\n" "$1" | grep -Eqx "excluded IP:((0:){7}0/(0:){7}0|::/::)"' _ "$nc"
check "excludes nothing else" test "$(printf '%s\n' "$nc" | grep -c '^excluded ')" = 2
check "root may issue TLS server certificates only" sh -c 'printf "%s" "$1" | grep -A1 "Extended Key Usage" | grep -qx " *TLS Web Server Authentication"' _ "$rt"
check "root's name is unique to this machine and day" sh -c '"$1" x509 -noout -subject -in "$2" | grep -Eq "CN *= *rsl-commerce dev CA [^ ]+ [0-9]{8}"' _ "$OPENSSL" "$CA/rootCA.pem"
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
check "leaf lasts at least 396 days" "$OPENSSL" x509 -checkend $((396 * 86400)) -noout -in "$LEAF/cert.pem"
check "leaf key is ECDSA P-256" sh -c 'printf "%s" "$1" | grep -Eq "prime256v1|P-256"' _ "$lt"
days=$(cert_days_left "$LEAF/cert.pem")
check "cert_days_left counts 396 or 397 days" test "$days" -ge 396 -a "$days" -le 397

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
sign_bad email "DNS:$RSL_DOMAIN, email:dev@$RSL_DOMAIN" "emailProtection, codeSigning, clientAuth"
refuse "rejects a leaf for signing email" "$OPENSSL" verify -purpose smimesign -CAfile "$CA/rootCA.pem" "$T/email.pem"
check "accepts the real leaf for TLS servers" "$OPENSSL" verify -purpose sslserver -CAfile "$CA/rootCA.pem" "$LEAF/cert.pem"

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
# The right hosts and a matching key, but signed by some other root.
mkdir -p "$T/stranger"
"$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$T/stranger/rootCA-key.pem"
printf '[req]\ndistinguished_name = dn\nprompt = no\nx509_extensions = v\n[dn]\nCN = stranger\n[v]\nbasicConstraints = critical, CA:TRUE\nkeyUsage = critical, keyCertSign\n' >"$T/stranger/root.cnf"
"$OPENSSL" req -x509 -new -sha256 -key "$T/stranger/rootCA-key.pem" -days 1 -set_serial 0x99 -config "$T/stranger/root.cnf" -out "$T/stranger/rootCA.pem"
# shellcheck disable=SC2086 # split the host list on purpose
sign_bad stranger-leaf "$(printf 'DNS:%s\n' $RSL_HOSTS | paste -sd, -)" serverAuth "$T/stranger"
cp "$T/stranger-leaf.pem" "$LEAF/cert.pem"
cp "$T/stranger-leaf.key" "$LEAF/key.pem"
reissued "certificate from another root"
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

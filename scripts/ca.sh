#!/bin/sh
# Creates the local certificate authority and the TLS certificate the proxy serves.
#
# The root is name-constrained: it can only vouch for rsl-commerce.test and its subdomains, and never for
# an IP address. Even if its key leaked, it couldn't be used against any other site (for clients that
# enforce name constraints; see docs/adr/0001-platform-stack.md).
#
# certs/ca/rootCA.pem       root certificate: the only file a trust store receives (scripts/trust.sh)
# certs/ca/rootCA-key.pem   root key: mode 600, never mounted into a container
# certs/leaf/cert.pem       certificate for the 8 local hosts, mounted read-only into the proxy
# certs/leaf/key.pem        its key: mode 644, so the proxy's uid 101 can read the bind mount
#
# Idempotent. The leaf is reissued when it's missing, has under 30 days left, lists different hosts,
# doesn't verify against the root, or doesn't match its key. The root is replaced (and must be trusted
# again) when it has fewer days left than a leaf lives, so a leaf never outlives its root.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

OPENSSL=${OPENSSL:-openssl}
CERTS=${RSL_CERTS_DIR:-certs}
CA_DIR=$CERTS/ca
LEAF_DIR=$CERTS/leaf
ROOT_DAYS=${RSL_ROOT_DAYS:-825} # test hook: tests shorten it to exercise rotation
LEAF_DAYS=${RSL_LEAF_DAYS:-397} # test hook: tests shorten it to exercise renewal
LEAF_RENEW_DAYS=30
ROOT_MIN_DAYS=427 # 397-day leaf + 30-day renewal window

need_cmd "$OPENSSL" "Install OpenSSL (macOS ships LibreSSL as openssl, which works too)."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

serial() { printf '0x%s' "$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"; }

# run <command...>: run an openssl step quietly, showing its output only when it fails.
run() {
  "$@" >"$tmp/out" 2>&1 || {
    cat "$tmp/out" >&2
    die "openssl failed: $*"
  }
}
days() { echo $(($1 * 86400)); }

# The SANs of a certificate, one per line, sorted. Read from -text: LibreSSL has no `x509 -ext`.
sans_of() {
  "$OPENSSL" x509 -noout -text -in "$1" |
    sed -n '/Subject Alternative Name/{n;p;}' | tr ',' '\n' | sed 's/^ *DNS://' | sed '/^ *$/d' | sort
}
# shellcheck disable=SC2086 # split the host list on purpose
wanted_sans() { printf '%s\n' $RSL_HOSTS | sort; }

pubkey_of_cert() { "$OPENSSL" x509 -noout -pubkey -in "$1"; }
pubkey_of_key() { "$OPENSSL" pkey -pubout -in "$1" 2>/dev/null; }

create_root() {
  umask 077
  mkdir -p "$CA_DIR"
  chmod 700 "$CA_DIR"
  run "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$tmp/root-key.pem"
  # The machine's short name, cut to fit: a common name may hold only 64 characters. The root may issue
  # TLS server certificates only (extendedKeyUsage), so its key could never sign code or email that
  # Windows, NSS or OpenSSL would accept.
  cat >"$tmp/root.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca

[dn]
O = $RSL_ROOT_O
CN = $RSL_ROOT_CN $(uname -n | cut -d. -f1 | cut -c1-24) $(date +%Y%m%d)

[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
nameConstraints = critical, permitted;DNS:$RSL_DOMAIN, excluded;IP:0.0.0.0/0.0.0.0, excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
EOF
  run "$OPENSSL" req -x509 -new -sha256 -key "$tmp/root-key.pem" -days "$ROOT_DAYS" -set_serial "$(serial)" \
    -config "$tmp/root.cnf" -out "$tmp/root.pem"
  chmod 600 "$tmp/root-key.pem"
  chmod 644 "$tmp/root.pem"
  mv "$tmp/root-key.pem" "$CA_DIR/rootCA-key.pem"
  mv "$tmp/root.pem" "$CA_DIR/rootCA.pem"
  umask 022
}

create_leaf() {
  mkdir -p "$LEAF_DIR"
  chmod 755 "$CERTS" "$LEAF_DIR"
  run "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$tmp/key.pem"
  # shellcheck disable=SC2086 # split the host list on purpose
  sans=$(printf 'DNS:%s,' $RSL_HOSTS)
  cat >"$tmp/leaf.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no

[dn]
CN = $RSL_DOMAIN

[v3_leaf]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
subjectAltName = ${sans%,}
EOF
  run "$OPENSSL" req -new -sha256 -key "$tmp/key.pem" -config "$tmp/leaf.cnf" -out "$tmp/leaf.csr"
  run "$OPENSSL" x509 -req -sha256 -in "$tmp/leaf.csr" -CA "$CA_DIR/rootCA.pem" -CAkey "$CA_DIR/rootCA-key.pem" \
    -set_serial "$(serial)" -days "$LEAF_DAYS" -extfile "$tmp/leaf.cnf" -extensions v3_leaf -out "$tmp/cert.pem"
  chmod 644 "$tmp/key.pem" "$tmp/cert.pem"
  # Rename into place, so a running proxy never sees a half-written pair.
  mv "$tmp/key.pem" "$LEAF_DIR/key.pem"
  mv "$tmp/cert.pem" "$LEAF_DIR/cert.pem"
}

# Why the leaf needs reissuing, or nothing when it's fine.
leaf_problem() {
  [ -f "$LEAF_DIR/cert.pem" ] && [ -f "$LEAF_DIR/key.pem" ] || {
    echo "missing"
    return
  }
  "$OPENSSL" x509 -checkend "$(days "$LEAF_RENEW_DAYS")" -noout -in "$LEAF_DIR/cert.pem" >/dev/null || {
    echo "expires within $LEAF_RENEW_DAYS days"
    return
  }
  [ "$(sans_of "$LEAF_DIR/cert.pem")" = "$(wanted_sans)" ] || {
    echo "host list changed"
    return
  }
  "$OPENSSL" verify -CAfile "$CA_DIR/rootCA.pem" "$LEAF_DIR/cert.pem" >/dev/null 2>&1 || {
    echo "doesn't verify against the root"
    return
  }
  [ "$(pubkey_of_cert "$LEAF_DIR/cert.pem")" = "$(pubkey_of_key "$LEAF_DIR/key.pem")" ] || {
    echo "key doesn't match certificate"
    return
  }
}

root_rotated=no
if [ ! -f "$CA_DIR/rootCA.pem" ] || [ ! -f "$CA_DIR/rootCA-key.pem" ]; then
  create_root
  root_rotated=yes
  info "created root CA: $("$OPENSSL" x509 -noout -subject -in "$CA_DIR/rootCA.pem" | sed 's/^subject= *//')"
elif ! "$OPENSSL" x509 -checkend "$(days "$ROOT_MIN_DAYS")" -noout -in "$CA_DIR/rootCA.pem" >/dev/null; then
  create_root
  root_rotated=yes
  info "replaced root CA: under $ROOT_MIN_DAYS days were left"
else
  info "kept root CA ($("$OPENSSL" x509 -noout -enddate -in "$CA_DIR/rootCA.pem" | sed 's/^notAfter=/expires /'))"
fi

problem=$(leaf_problem)
if [ -n "$problem" ]; then
  create_leaf
  info "issued certificate for the local hosts ($problem)"
  # A running proxy keeps the old certificate in memory until it reloads.
  if [ -z "${RSL_CERTS_DIR:-}" ] && docker compose ps --status running -q proxy 2>/dev/null | grep -q .; then
    docker compose exec -T proxy nginx -s reload >/dev/null 2>&1 && info "reloaded the proxy"
  fi
else
  info "kept certificate for the local hosts ($("$OPENSSL" x509 -noout -enddate -in "$LEAF_DIR/cert.pem" | sed 's/^notAfter=/expires /'))"
fi

if [ "$root_rotated" = yes ]; then
  info "The root CA is new: run 'make trust' so your browser trusts it."
fi

#!/bin/sh
# Writes .env with random development values, plus the Postgres password as a Compose secret file.
#
# Idempotent: keeps every value already set, fills only missing or empty keys, and never prints a value.
# Values look like rsldev_<hex> so git-secrets can recognise them anywhere (.githooks/setup).
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

umask 077
[ -f .env ] || : >.env
chmod 600 .env

# rand <bytes>: hex from /dev/urandom. POSIX tools only, so it needs no openssl.
rand() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

# put <key> <value>: replace key's line in .env (or append it), keeping every other line.
put() {
  grep -v "^$1=" .env >.env.tmp || true
  printf '%s=%s\n' "$1" "$2" >>.env.tmp
  mv .env.tmp .env
}

# generate <key> <bytes> [volume]: fill key when empty. A credential that a service stores in its volume
# on first start (Postgres, RabbitMQ) can't change while that volume exists, so refuse instead.
generate() {
  if [ -n "$(env_get "$1")" ]; then
    echo "kept $1"
    return 0
  fi
  if [ -n "${3:-}" ] && volume_exists "$3"; then
    die "$1 is empty but the $3 volume still holds the old one. Run 'make reset' to start fresh."
  fi
  put "$1" "rsldev_$(rand "$2")"
  echo "generated $1"
}

generate POSTGRES_PASSWORD 24 "${RSL_PROJECT}_postgres"
generate RABBITMQ_PASSWORD 24 "${RSL_PROJECT}_rabbitmq"
generate MEILI_MASTER_KEY 32

# Every other key in .env.example is optional and never generated: add it empty so .env lists it.
sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.example | while read -r key; do
  grep -q "^$key=" .env || printf '%s=\n' "$key" >>.env
done

# Postgres reads its password from a file-sourced Compose secret. Compose ignores uid, gid and mode for
# file secrets (they are bind mounts), so the file is world-readable for the container's uid 999. It
# stays inside the gitignored secrets/ directory on this machine.
mkdir -p secrets
chmod 755 secrets
pw=$(env_get POSTGRES_PASSWORD)
if [ "$(cat secrets/postgres_password 2>/dev/null || true)" != "$pw" ]; then
  printf '%s' "$pw" >secrets/postgres_password.tmp
  chmod 644 secrets/postgres_password.tmp
  mv secrets/postgres_password.tmp secrets/postgres_password
  echo "wrote secrets/postgres_password"
fi

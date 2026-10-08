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
generate VALKEY_PASSWORD 24 # Valkey keeps no password in its volume, so no guard

# Every other key in .env.example is optional and never generated: add it empty so .env lists it. A
# hand-edited .env may lack its final newline; add one first, so an added key starts its own line.
if [ -s .env ] && [ -n "$(tail -c 1 .env)" ]; then echo >>.env; fi
sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.example | while read -r key; do
  grep -q "^$key=" .env || printf '%s=\n' "$key" >>.env
done

# Postgres and Valkey read their passwords from file-sourced Compose secrets, so no password appears in
# an environment variable or on a command line. Compose ignores uid, gid and mode for file secrets (they
# are bind mounts), so the files are world-readable for the containers' uid 999. They stay inside the
# gitignored secrets/ directory on this machine.
mkdir -p secrets
chmod 755 secrets

# write_secret <file> <content>: replace secrets/<file> when its content differs.
write_secret() {
  if [ "$(cat "secrets/$1" 2>/dev/null || true)" != "$2" ]; then
    printf '%s' "$2" >"secrets/$1.tmp"
    chmod 644 "secrets/$1.tmp"
    mv "secrets/$1.tmp" "secrets/$1"
    echo "wrote secrets/$1"
  fi
}
write_secret postgres_password "$(env_get POSTGRES_PASSWORD)"
write_secret valkey.conf "requirepass $(env_get VALKEY_PASSWORD)"

#!/bin/sh
# Starts the platform and waits until every service is healthy (make up). LOCAL=<app>[,<app>...] builds
# those applications from local checkouts (compose/local/<app>.yaml) instead of pulling their pinned
# images; <APP>_SRC, in the environment or .env, says where a checkout is (default ../<app>).
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

for f in .env secrets/postgres_password secrets/valkey.conf certs/leaf/cert.pem certs/leaf/key.pem; do
  [ -f "$f" ] || die "$f is missing. Run 'make bootstrap' first."
done

set -f # the file list is expanded unquoted
files=$(compose_files)
# shellcheck disable=SC2086 # one word per argument; no spaces or globs (compose_files)
docker compose $files up --detach --wait

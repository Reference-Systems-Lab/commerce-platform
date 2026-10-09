#!/bin/sh
# Adds the development data (make seed): runs the backend's idempotent seed once. Pass the same LOCAL as
# to make up, so a locally built backend seeds with its own code.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

set -f # the file list is expanded unquoted
files=$(compose_files)
# shellcheck disable=SC2086 # one word per argument; no spaces or globs (compose_files)
docker compose $files run --rm --no-deps backend-api seed

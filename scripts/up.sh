#!/bin/sh
# Starts the platform and waits until every service is healthy (make up). LOCAL=<app>[,<app>...] builds
# those applications from local checkouts (compose/local/<app>.yaml) instead of pulling their pinned
# images; <APP>_SRC overrides where a checkout is (default ../<app>).
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

for f in .env secrets/postgres_password secrets/valkey.conf certs/leaf/cert.pem certs/leaf/key.pem; do
  [ -f "$f" ] || die "$f is missing. Run 'make bootstrap' first."
done

set -- -f compose.yaml
for app in $(printf '%s' "${LOCAL:-}" | tr ',' ' '); do
  file=compose/local/$app.yaml
  [ -f "$file" ] || die "LOCAL=$app: there is no $file, so $app can't be built locally."
  var=$(printf '%s_SRC' "$app" | tr '[:lower:]-' '[:upper:]_')
  src=$(eval "printf '%s' \"\${$var:-../$app}\"")
  [ -d "$src" ] || die "LOCAL=$app: $src isn't a directory. Clone $app there, or set $var."
  info "Building $app from $src"
  set -- "$@" -f "$file"
done

docker compose "$@" up --detach --wait

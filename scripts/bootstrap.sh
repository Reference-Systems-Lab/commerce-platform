#!/bin/sh
# Prepares this checkout and machine for `make up`. Safe to run again at any time: it keeps every value
# and certificate that is still good, and asks for nothing that's already done.
#
#   1. checks the prerequisites (scripts/doctor.sh --preflight)
#   2. writes .env and the Postgres secret (scripts/gen-env.sh)
#   3. creates or renews the certificates (scripts/ca.sh)
#   4. trusts the root (scripts/trust.sh): one confirmation the first time
#   5. lists any address missing from the hosts file (scripts/hosts.sh --check); `make hosts` adds them
#
#   sh scripts/bootstrap.sh        everything (make bootstrap)
#   sh scripts/bootstrap.sh --ci   steps 1-3 only: CI has no browser, and make smoke trusts the root directly
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

case ${1:-} in
  "" | --ci) ;;
  *) die "usage: sh scripts/bootstrap.sh [--ci]" ;;
esac

sh scripts/doctor.sh --preflight >/dev/null || {
  sh scripts/doctor.sh --preflight
  die "fix the failures above, then run 'make bootstrap' again."
}
info "Secrets"
sh scripts/gen-env.sh
info "Certificates"
sh scripts/ca.sh

if [ "${1:-}" = --ci ]; then
  info "CI: skipping trust and the hosts file."
  exit 0
fi

info "Trust"
sh scripts/trust.sh
hosts_ok=yes
sh scripts/hosts.sh --check || hosts_ok=no

echo
if [ "$hosts_ok" = yes ]; then
  info "Ready. Run 'make up'."
else
  info "Next: 'make hosts' (one elevation prompt), then 'make up'."
fi

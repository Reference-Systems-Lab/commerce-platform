#!/bin/sh
# Scans every image the platform pins with Grype and lists what it finds (make scan; weekly in CI).
# Only our own images fail the scan, at high or above. The local stand-ins (PostgreSQL, Valkey, nginx
# and the rest) are reported, not gated: their findings are mostly ones Debian won't fix, which we can
# only change by moving to a newer upstream image, and Dependabot proposes those. Nothing is ignored.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
GRYPE_CACHE=$tmp/db
HOST_UID=$(id -u)
HOST_GID=$(id -g)
export GRYPE_CACHE HOST_UID HOST_GID
mkdir "$GRYPE_CACHE"

tools() { docker compose -f compose.tools.yaml run --rm --quiet-pull -T "$@"; }

{
  grep -hE '^[[:space:]]*image:.*@sha256:[0-9a-f]{64}' compose.yaml compose/*.yaml | awk '{print $2}'
  grep -hE '^FROM .*@sha256:[0-9a-f]{64}' images/*/Dockerfile | awk '{print $2}'
} | sort -u >"$tmp/images"

failed=0
{
  echo '| Image | Critical | High | High or critical with a fix | Gate |'
  echo '| ----- | -------- | ---- | --------------------------- | ---- |'
} >"$tmp/report"

while read -r image; do
  # Compose would otherwise read the rest of the list from this loop's stdin.
  tools grype "registry:$image" -o json -q </dev/null >"$tmp/result.json"
  # shellcheck disable=SC2016 # a jq program: its $ names are jq's, not the shell's
  counts=$(tools jq -r '
    [.matches[] | {id: .vulnerability.id, pkg: .artifact.name, sev: .vulnerability.severity, fix: .vulnerability.fix.state}]
    | unique | . as $m
    | [
        ([$m[] | select(.sev == "Critical")] | length),
        ([$m[] | select(.sev == "High")] | length),
        ([$m[] | select(.sev == "Critical" or .sev == "High") | select(.fix == "fixed")] | length)
      ] | @tsv' <"$tmp/result.json")
  critical=$(printf '%s' "$counts" | cut -f1)
  high=$(printf '%s' "$counts" | cut -f2)
  fixable=$(printf '%s' "$counts" | cut -f3)
  gate=reported
  case $image in
    ghcr.io/reference-systems-lab/*)
      gate=pass
      if [ "$((critical + high))" -gt 0 ]; then
        gate=FAIL
        failed=1
      fi
      ;;
  esac
  echo "| \`${image%%@*}\` | $critical | $high | $fixable | $gate |" >>"$tmp/report"
done <"$tmp/images"
[ -s "$tmp/images" ] || die "no pinned images found"

cat "$tmp/report"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$tmp/report" >>"$GITHUB_STEP_SUMMARY"
fi
exit "$failed"

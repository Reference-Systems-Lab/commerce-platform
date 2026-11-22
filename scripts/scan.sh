#!/bin/sh
# Scans every image the platform pins with Grype and lists what it finds (make scan; weekly in CI).
# Only our own images fail the scan, at high or above. The local stand-ins (PostgreSQL, Valkey, nginx
# and the rest) are reported, not gated: their findings are mostly ones Debian won't fix, which we can
# only change by moving to a newer upstream image, and Dependabot proposes those. Nothing is ignored.
#
# Docker Hardened Images need a login, which only the host has, so they are pulled and scanned from an
# archive. They are listed twice: raw, and with the VEX statements Docker publishes about them, which
# are Docker's own claims, not ones we have checked: only their signature is verified, without the
# public log. Without `docker scout`, or if it can't verify them, the second count reads n/a.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
GRYPE_CACHE=$tmp/db
SCAN_DIR=$tmp/scan
HOST_UID=$(id -u)
HOST_GID=$(id -g)
export GRYPE_CACHE SCAN_DIR HOST_UID HOST_GID
mkdir "$GRYPE_CACHE" "$SCAN_DIR"

# Compose would otherwise read the rest of the image list from the loop's stdin.
tools() { docker compose -f compose.tools.yaml run --rm --quiet-pull -T "$@" </dev/null; }

# counts <result.json>: critical, high, and high or critical with a fix, tab-separated.
counts() {
  # shellcheck disable=SC2016 # a jq program: its $ names are jq's, not the shell's
  docker compose -f compose.tools.yaml run --rm --quiet-pull -T jq -r '
    [.matches[] | {id: .vulnerability.id, pkg: .artifact.name, sev: .vulnerability.severity, fix: .vulnerability.fix.state}]
    | unique | . as $m
    | [
        ([$m[] | select(.sev == "Critical")] | length),
        ([$m[] | select(.sev == "High")] | length),
        ([$m[] | select(.sev == "Critical" or .sev == "High") | select(.fix == "fixed")] | length)
      ] | @tsv' <"$1"
}

{
  grep -hE '^[[:space:]]*image:.*@sha256:[0-9a-f]{64}' compose.yaml compose/*.yaml | awk '{print $2}'
  grep -hE '^FROM .*@sha256:[0-9a-f]{64}' images/*/Dockerfile | awk '{print $2}'
  # CI runs this one directly, with the token and the Docker socket.
  docker compose -f compose.tools.yaml config --images scout-cli
} | sort -u >"$tmp/images"
[ -s "$tmp/images" ] || die "no pinned images found"

failed=0
{
  echo '| Image | Critical | High | High or critical with a fix | Critical with VEX | High with VEX | Gate |'
  echo '| ----- | -------- | ---- | --------------------------- | ----------------- | ------------- | ---- |'
} >"$tmp/report"

while read -r image; do
  vex_critical=-
  vex_high=-
  case $image in
    dhi.io/*)
      docker pull -q "$image" >/dev/null
      docker save "$image" -o "$SCAN_DIR/image.tar"
      tools grype docker-archive:/scan/image.tar -o json -q >"$tmp/result.json"
      vex_critical=n/a
      vex_high=n/a
      if ! docker scout version >/dev/null 2>&1; then
        warn "docker scout isn't installed: no VEX counts for ${image%%@*}" >&2
      elif docker scout vex get --verify --skip-tlog "registry://$image" --output "$SCAN_DIR/vex.json" >/dev/null 2>"$tmp/scout.err" && [ -s "$SCAN_DIR/vex.json" ]; then
        tools grype docker-archive:/scan/image.tar --vex /scan/vex.json -o json -q >"$tmp/vex-result.json"
        vex=$(counts "$tmp/vex-result.json")
        vex_critical=$(printf '%s' "$vex" | cut -f1)
        vex_high=$(printf '%s' "$vex" | cut -f2)
      else
        # In CI this fails the job, so an expired token can't quietly remove the counts.
        warn "docker scout couldn't read the VEX statements for ${image%%@*}" >&2
        tail -n 5 "$tmp/scout.err" >&2 || true
        [ -z "${GITHUB_ACTIONS:-}" ] || failed=1
      fi
      rm -f "$SCAN_DIR/image.tar" "$SCAN_DIR/vex.json"
      ;;
    *)
      tools grype "registry:$image" -o json -q >"$tmp/result.json"
      ;;
  esac
  raw=$(counts "$tmp/result.json")
  critical=$(printf '%s' "$raw" | cut -f1)
  high=$(printf '%s' "$raw" | cut -f2)
  fixable=$(printf '%s' "$raw" | cut -f3)
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
  echo "| \`${image%%@*}\` | $critical | $high | $fixable | $vex_critical | $vex_high | $gate |" >>"$tmp/report"
done <"$tmp/images"

cat "$tmp/report"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$tmp/report" >>"$GITHUB_STEP_SUMMARY"
fi
exit "$failed"

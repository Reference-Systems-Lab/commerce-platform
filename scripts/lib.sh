# shellcheck shell=sh
# shellcheck disable=SC2034 # the RSL_ variables are read by the scripts that source this file
# Shared helpers, sourced by the other scripts after they cd to the repository root.
# POSIX sh only: no `local`, no `pipefail`, no GNU-only flags, so it runs under dash and on macOS.

# The local addresses, in one place. ca.sh, hosts.sh, status.sh and smoke.sh all read this list.
RSL_DOMAIN=rsl-commerce.test
RSL_HOSTS="rsl-commerce.test api.rsl-commerce.test admin.rsl-commerce.test checkout.rsl-commerce.test docs.rsl-commerce.test design.rsl-commerce.test mail.rsl-commerce.test observe.rsl-commerce.test"

# Compose project name, so volumes are named rsl-commerce_<service>.
RSL_PROJECT=rsl-commerce

# The root CA's subject (scripts/ca.sh). Every root this platform creates has this organization and a
# common name that starts with this prefix; scripts/trust.sh untrust removes only those.
RSL_ROOT_O="rsl-commerce local development"
RSL_ROOT_CN="rsl-commerce dev CA"

info() { printf '%s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# need_cmd <command> <hint>: stop with a hint when a prerequisite is missing.
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required. $2"
}

# platform_os: wsl, macos or linux. WSL counts as its own platform because the browser, the hosts file
# and the trust store a developer uses live on Windows, not in the Linux distribution.
platform_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)
      if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        echo wsl
      else
        echo linux
      fi
      ;;
    *) echo unsupported ;;
  esac
}

# volume_exists <name>: true when the Docker volume exists. False when it doesn't, or when Docker isn't
# reachable, so callers can run before Docker is up.
volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

# env_get <key>: the value of key in .env, or nothing.
env_get() {
  sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1
}

# powershell <script> [NAME=value...]: run a script in Windows PowerShell from WSL and print its output.
# The script goes in encoded, so no shell quoting reaches it. Values go in as environment variables listed
# in WSLENV, never spliced into the code.
powershell() {
  ps_script=$1
  shift
  ps_wslenv=${WSLENV:-}
  for ps_pair in "$@"; do ps_wslenv="${ps_wslenv:+$ps_wslenv:}${ps_pair%%=*}"; done
  ps_exe=$(wslpath -u 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')
  [ -x "$ps_exe" ] || die "Windows PowerShell isn't at $ps_exe. Is WSL interop turned off?"
  # shellcheck disable=SC2016 # PowerShell variables, not shell ones
  ps_script=$(printf '%s\n%s\n' '$ErrorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"' "$ps_script")
  env "$@" WSLENV="$ps_wslenv" "$ps_exe" -NoProfile -EncodedCommand \
    "$(printf '%s' "$ps_script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" | tr -d '\r'
}

# cert_days_left <file>: whole days until the certificate expires, 0 when it already has. A binary search
# over `openssl x509 -checkend`, because no portable `date` parses certificate dates (GNU-only `date -d`).
cert_days_left() {
  lo=0
  hi=4000
  "${OPENSSL:-openssl}" x509 -checkend 0 -noout -in "$1" >/dev/null 2>&1 || {
    echo 0
    return 0
  }
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(((lo + hi) / 2))
    if "${OPENSSL:-openssl}" x509 -checkend $((mid * 86400)) -noout -in "$1" >/dev/null 2>&1; then lo=$mid; else hi=$mid; fi
  done
  echo "$lo"
}

# container_state <container>: "healthy" for a running container whose health check passes, "completed"
# for a one-shot (its health check disabled, like backend-migrate) that exited 0, and otherwise its
# state, health and exit code, to show what's wrong.
container_state() {
  state=$(container_state_raw "$1")
  printf '%s\n' "${state:-unknown}"
}
container_state_raw() {
  docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.State.ExitCode}} {{if .Config.Healthcheck}}{{index .Config.Healthcheck.Test 0}}{{else}}-{{end}}' "$1" 2>/dev/null |
    while read -r status health code check; do
      if [ "$status" = running ] && [ "$health" = healthy ]; then
        echo healthy
      elif [ "$status" = exited ] && [ "$code" = 0 ] && [ "$check" = NONE ]; then
        echo completed
      else
        echo "$status, health $health, exit $code"
      fi
    done
}

# compose_files: the -f arguments for compose.yaml plus, for each application in $LOCAL
# (comma-separated), its local-build override compose/local/<app>.yaml. Stops with a message when an
# application has no override or its checkout (<APP>_SRC from the environment or .env, default
# ../<app>) isn't a directory. Callers expand the result unquoted, with globbing off (set -f).
compose_files() {
  set -f
  files="-f compose.yaml"
  for app in $(printf '%s' "${LOCAL:-}" | tr ',' ' '); do
    case $app in
      *[!a-z0-9-]* | -*) die "LOCAL=$app: application names are lowercase letters, digits and hyphens." ;;
    esac
    file=compose/local/$app.yaml
    [ -f "$file" ] || die "LOCAL=$app: there is no $file, so $app can't be built locally."
    var=$(printf '%s_SRC' "$app" | tr 'a-z-' 'A-Z_')
    # $var is now [A-Z0-9_]+, so the eval only reads that variable.
    eval "src=\${$var:-}"
    [ -n "$src" ] || src=$(env_get "$var")
    [ -n "$src" ] || src=../$app
    [ -d "$src" ] || die "LOCAL=$app: $src isn't a directory. Clone $app there, or set $var."
    info "Building $app from $src" >&2
    files="$files -f $file"
  done
  printf '%s\n' "$files"
}


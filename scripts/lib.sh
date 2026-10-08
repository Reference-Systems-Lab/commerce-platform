# shellcheck shell=sh
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

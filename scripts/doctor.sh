#!/bin/sh
# Checks this machine and this checkout for what the platform needs, changing nothing. Exits 1 only when
# a check fails; warnings explain what to do but don't stop anything.
#
#   sh scripts/doctor.sh               every check (make doctor)
#   sh scripts/doctor.sh --preflight   only the prerequisites bootstrap can't work without
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

case ${1:-} in
  "" | --preflight) ;;
  *) die "usage: sh scripts/doctor.sh [--preflight]" ;;
esac

failures=0
warnings=0
bad() {
  fail "$*"
  failures=$((failures + 1))
}
meh() {
  warn "$*"
  warnings=$((warnings + 1))
}

OS=$(platform_os)

info "Prerequisites"
if [ "$(id -u)" = 0 ]; then
  bad "running as root: the files the platform writes would be root-owned. Run it as your own user."
else
  ok "running as $(id -un)"
fi
[ "$OS" != unsupported ] || bad "unsupported system $(uname -s): the platform runs on WSL2, macOS and Linux."
if ! command -v docker >/dev/null 2>&1; then
  bad "docker isn't installed. Install Docker Desktop (WSL2, macOS) or Docker Engine (Linux)."
elif ! docker info >/dev/null 2>&1; then
  bad "Docker isn't running, or this user can't reach it. Start Docker Desktop (or the docker service)."
else
  ok "Docker is running"
  compose=$(docker compose version --short 2>/dev/null | sed 's/^v//' || true)
  case ${compose%%.*} in
    "" | *[!0-9]*) bad "Docker Compose isn't available as 'docker compose'. Update Docker." ;;
    *)
      if [ "${compose%%.*}" -ge 5 ]; then ok "Docker Compose $compose"; else bad "Docker Compose $compose is too old: 5 or newer is needed. Update Docker."; fi
      ;;
  esac
fi
if command -v openssl >/dev/null 2>&1; then ok "openssl"; else bad "openssl isn't installed: the certificates need it."; fi

if [ "${1:-}" = --preflight ]; then
  [ "$failures" -eq 0 ] || exit 1
  exit 0
fi
command -v curl >/dev/null 2>&1 || meh "curl isn't installed: make smoke needs it."

info "This machine"
# ports: 80 and 443 for the proxy, 15672 for RabbitMQ's management UI, all on 127.0.0.1.
ours=$(docker ps --filter "label=com.docker.compose.project=$RSL_PROJECT" --format '{{.Ports}}' 2>/dev/null || true)
for port in 80 443 15672; do
  case $ours in
    *"127.0.0.1:$port->"*)
      ok "port $port: the platform's own"
      continue
      ;;
  esac
  holder=
  case $OS in
    wsl)
      # Docker Desktop publishes ports on Windows, so Windows is where a conflict would be.
      # shellcheck disable=SC2016 # PowerShell variables
      holder=$(powershell '$c = Get-NetTCPConnection -State Listen -LocalPort ([int]$env:RSL_PORT) -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName + " (pid " + $c.OwningProcess + ")" }' RSL_PORT="$port" || true)
      ;;
    macos)
      holder=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 { print $1 " (pid " $2 ")" }' || true)
      ;;
    linux)
      if command -v ss >/dev/null 2>&1; then
        holder=$(ss -Hltn "sport = :$port" 2>/dev/null | awk 'NR == 1 { print "a listener on " $4 }' || true)
      fi
      ;;
  esac
  if [ -n "$holder" ]; then bad "port $port is taken by $holder. Stop it, or make up will fail."; else ok "port $port is free"; fi
done

# Free space where Docker keeps images and volumes: the first pull is about 1 GB.
free_kib=
where=
case $OS in
  wsl)
    # shellcheck disable=SC2016 # PowerShell variables
    disk=$(powershell '
$dir = Join-Path $env:LOCALAPPDATA "Docker\wsl"
$settings = Join-Path $env:APPDATA "Docker\settings-store.json"
if (Test-Path $settings) { $custom = (Get-Content $settings -Raw | ConvertFrom-Json).CustomWslDistroDir; if ($custom) { $dir = $custom } }
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($dir))
[string][math]::Floor($drive.AvailableFreeSpace / 1KB) + " " + $drive.Name' || true)
    free_kib=${disk%% *}
    where="${disk#* } (Docker Desktop's disk image)"
    ;;
  macos)
    where="$HOME/Library/Containers/com.docker.docker"
    [ -d "$where" ] || where=$HOME
    free_kib=$(df -Pk "$where" | awk 'NR == 2 { print $4 }')
    ;;
  linux)
    where=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
    if [ -z "$where" ] || [ ! -d "$where" ]; then where=$HOME; fi
    free_kib=$(df -Pk "$where" | awk 'NR == 2 { print $4 }')
    ;;
esac
case $free_kib in
  "" | *[!0-9]*) meh "couldn't measure the free space for Docker's data." ;;
  *)
    free_gib=$((free_kib / 1048576))
    if [ "$free_gib" -lt 5 ]; then
      bad "$free_gib GiB free on $where: Docker needs more than 5 GiB. Free some space, or move Docker's disk image."
    elif [ "$free_gib" -lt 30 ]; then
      meh "$free_gib GiB free on $where. Under 30 GiB, image pulls and builds can run out; consider freeing space or moving Docker's disk image."
    else
      ok "$free_gib GiB free on $where"
    fi
    ;;
esac

# docker compose watch takes a lock under XDG_RUNTIME_DIR and fails when it points at a missing directory.
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
  ok "XDG_RUNTIME_DIR is $XDG_RUNTIME_DIR"
elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ ! -e "$XDG_RUNTIME_DIR" ] && [ "$(ps -p 1 -o comm= 2>/dev/null || true)" = systemd ]; then
  meh "XDG_RUNTIME_DIR ($XDG_RUNTIME_DIR) doesn't exist, because no systemd user session is running: docker compose watch will fail to take its lock. 'sudo loginctl enable-linger $(id -un)' keeps one running."
else
  meh "XDG_RUNTIME_DIR ('${XDG_RUNTIME_DIR:-}') isn't a writable directory: docker compose watch will fail to take its lock. Point it at one you own."
fi
if [ "$OS" = wsl ]; then
  case $(pwd -P) in
    /mnt/*) meh "this checkout is on a Windows drive ($(pwd -P)): file access is slow and permissions don't stick. Clone it into the Linux filesystem, such as ~/code." ;;
    *) ok "the checkout is on the Linux filesystem" ;;
  esac
fi

info "This checkout"
# The containers read proxy/ and config/ as their own users. A checkout made under a strict umask
# (027, 077) leaves those files unreadable to them, and the proxy or RabbitMQ won't start.
unreadable=$(find proxy config \( -type f ! -perm -o=r \) -o \( -type d ! -perm -o=rx \) 2>/dev/null | head -n 3 | tr '\n' ' ')
if [ -n "$unreadable" ]; then
  bad "the containers can't read ${unreadable}(this checkout was made with a strict umask). Run 'chmod -R a+rX proxy config'."
else
  ok "the containers can read proxy/ and config/"
fi
if [ ! -f .env ]; then
  bad ".env is missing. Run 'make bootstrap'."
else
  missing_keys=$(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.example | while read -r key; do
    grep -q "^$key=" .env || printf ' %s' "$key"
  done)
  empty_keys=
  for key in POSTGRES_PASSWORD RABBITMQ_PASSWORD MEILI_MASTER_KEY VALKEY_PASSWORD; do
    [ -n "$(env_get "$key")" ] || empty_keys="$empty_keys $key"
  done
  if [ -n "$empty_keys" ]; then
    bad ".env has no value for$empty_keys. Run 'make bootstrap'."
  elif [ -n "$missing_keys" ]; then
    meh ".env lacks$missing_keys from .env.example. Run 'make bootstrap' to add them."
  else
    ok ".env is complete"
  fi
  if [ "$(cat secrets/postgres_password 2>/dev/null || true)" = "$(env_get POSTGRES_PASSWORD)" ] &&
    [ "$(cat secrets/valkey.conf 2>/dev/null || true)" = "requirepass $(env_get VALKEY_PASSWORD)" ]; then
    ok "the secret files match .env"
  else
    bad "secrets/postgres_password or secrets/valkey.conf is missing or differs from .env. Run 'make bootstrap'."
  fi
fi

if [ ! -f certs/ca/rootCA.pem ] || [ ! -f certs/leaf/cert.pem ] || [ ! -f certs/leaf/key.pem ]; then
  bad "the certificates are missing. Run 'make bootstrap'."
elif ! openssl verify -CAfile certs/ca/rootCA.pem certs/leaf/cert.pem >/dev/null 2>&1; then
  bad "certs/leaf/cert.pem doesn't verify against the root. Run 'make bootstrap' to reissue it."
else
  ok "the root CA has $(cert_days_left certs/ca/rootCA.pem) days left"
  leaf_days=$(cert_days_left certs/leaf/cert.pem)
  if [ "$leaf_days" -lt 30 ]; then
    meh "the certificate has $leaf_days days left. Run 'make bootstrap' to reissue it."
  else
    ok "the certificate has $leaf_days days left"
  fi
  if sh scripts/trust.sh check >/dev/null 2>&1; then
    ok "your browsers trust the root"
  else
    meh "your browsers don't trust the root yet. Run 'make trust'."
  fi
fi

if hosts=$(sh scripts/hosts.sh --check 2>&1); then
  ok "the hosts file lists every address"
else
  meh "the hosts file needs attention:"
  printf '%s\n' "$hosts" | sed -n 's/^  warn  /        /p; s/^error: /        /p'
fi

echo
if [ "$failures" -gt 0 ]; then
  info "$failures failed, $warnings warnings."
  exit 1
fi
info "No failures, $warnings warnings."

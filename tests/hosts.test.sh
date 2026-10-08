#!/bin/sh
# Tests the hosts-file transform in scripts/hosts.sh (--check and --print) on fixtures generated here:
# this machine's layout, LF, CRLF, no final newline, an existing block, conflicts, a damaged block, and
# that a second pass changes nothing. RSL_HOSTS_FILE points every run at a fixture, so no real hosts
# file is read or written. Runs under any POSIX sh and awk, including macOS's.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

failures=0
pass() { printf 'ok    %s\n' "$1"; }
flunk() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
check() { # check <description> <command...>
  d=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else flunk "$d"; fi
}
refuse() { # refuse <description> <command...>: passes when the command fails
  d=$1
  shift
  if "$@" >/dev/null 2>&1; then flunk "$d"; else pass "$d"; fi
}

render() { RSL_HOSTS_FILE="$1" sh scripts/hosts.sh --print; }
report() { RSL_HOSTS_FILE="$1" sh scripts/hosts.sh --check; }

# block <lf|crlf> <host...>: the block make hosts writes for these hosts.
block() {
  cr=
  if [ "$1" = crlf ]; then cr=$(printf '\r'); fi
  shift
  printf '# BEGIN rsl-commerce%s\n' "$cr"
  printf '# Local addresses of the rsl-commerce platform, written by its make hosts.%s\n' "$cr"
  for h in "$@"; do printf '127.0.0.1 %s%s\n' "$h" "$cr"; done
  printf '# END rsl-commerce%s\n' "$cr"
}

# without_block <file>: the file minus the block's lines.
without_block() {
  awk '{ l = $0; sub(/\r$/, "", l) } l == "# BEGIN rsl-commerce" { skip = 1 } !skip { print } l == "# END rsl-commerce" { skip = 0 }' "$1"
}

# expect <case>: render fixture $T/<case> and compare it byte for byte with $T/<case>.want, then check
# that rendering the result again changes nothing.
expect() {
  render "$T/$1" >"$T/$1.out"
  check "$1: writes exactly the expected bytes" cmp "$T/$1.out" "$T/$1.want"
  render "$T/$1.out" >"$T/$1.again"
  check "$1: a second pass changes nothing" cmp "$T/$1.again" "$T/$1.out"
}

# shellcheck disable=SC2086 # the list splits into one argument per host
all() { printf '%s\n' $RSL_HOSTS; }

echo "# this machine: CRLF, 7 of the 8 hosts listed, Docker Desktop's section last"
{
  printf '# Copyright (c) 1993-2009 Microsoft Corp.\r\n#\r\n'
  all | grep -v '^design\.' | sed 's/^/127.0.0.1 /; s/$/\r/'
  printf '\r\n# Added by Docker Desktop\r\n192.168.40.91 host.docker.internal\r\n# End of section\r\n'
} >"$T/machine"
{
  cat "$T/machine"
  block crlf "design.$RSL_DOMAIN"
} >"$T/machine.want"
expect machine
without_block "$T/machine.out" >"$T/machine.rest"
check "machine: every byte outside the block is unchanged" cmp "$T/machine.rest" "$T/machine"
out=$(report "$T/machine" || true)
case $out in *"missing: design.$RSL_DOMAIN"*) pass "machine: --check lists design. as missing" ;; *) flunk "machine: --check lists design. as missing" ;; esac
refuse "machine: --check exits non-zero while one is missing" report "$T/machine"
check "machine: --check passes on the result" report "$T/machine.out"

echo "# LF, none listed"
printf '127.0.0.1 localhost\n::1 localhost\n' >"$T/lf"
{
  cat "$T/lf"
  # shellcheck disable=SC2046 # one argument per host
  block lf $(all)
} >"$T/lf.want"
expect lf

echo "# CRLF, none listed"
printf '127.0.0.1 localhost\r\n' >"$T/crlf"
{
  cat "$T/crlf"
  # shellcheck disable=SC2046
  block crlf $(all)
} >"$T/crlf.want"
expect crlf

echo "# no final newline"
printf '127.0.0.1 localhost' >"$T/noeol"
{
  printf '127.0.0.1 localhost\n'
  # shellcheck disable=SC2046
  block lf $(all)
} >"$T/noeol.want"
expect noeol
printf '127.0.0.1 localhost\r\n::1 localhost' >"$T/noeol-crlf"
{
  printf '127.0.0.1 localhost\r\n::1 localhost\r\n'
  # shellcheck disable=SC2046
  block crlf $(all)
} >"$T/noeol-crlf.want"
expect noeol-crlf

echo "# an existing block is rewritten in place"
{
  printf '127.0.0.1 localhost\n'
  printf '# BEGIN rsl-commerce\n127.0.0.1 old.%s\n127.0.0.1 api.%s\n# END rsl-commerce\n' "$RSL_DOMAIN" "$RSL_DOMAIN"
  printf '127.0.0.1 %s\n' "$RSL_DOMAIN"
} >"$T/existing"
{
  printf '127.0.0.1 localhost\n'
  # shellcheck disable=SC2046
  block lf $(all | grep -vx "$RSL_DOMAIN")
  printf '127.0.0.1 %s\n' "$RSL_DOMAIN"
} >"$T/existing.want"
expect existing

echo "# conflicts, comments, case and tabs"
{
  printf '10.0.0.5 api.%s\n' "$RSL_DOMAIN"
  printf '# 127.0.0.1 design.%s\n' "$RSL_DOMAIN"
  printf '127.0.0.1 ADMIN.%s\n' "$(printf '%s' "$RSL_DOMAIN" | tr '[:lower:]' '[:upper:]')"
  printf '127.0.0.1\tmail.%s  # Mailpit\n' "$RSL_DOMAIN"
} >"$T/mixed"
{
  cat "$T/mixed"
  # shellcheck disable=SC2046
  block lf $(all | grep -v '^api\.' | grep -v '^admin\.' | grep -v '^mail\.')
} >"$T/mixed.want"
expect mixed
out=$(report "$T/mixed" || true)
case $out in *"api.$RSL_DOMAIN points at 10.0.0.5"*) pass "mixed: --check reports the conflict" ;; *) flunk "mixed: --check reports the conflict" ;; esac
refuse "mixed: --check fails on the result while the conflict remains" report "$T/mixed.out"
case $out in *"missing:"*"design.$RSL_DOMAIN"*) pass "mixed: a commented-out line doesn't count" ;; *) flunk "mixed: a commented-out line doesn't count" ;; esac
case $out in *"missing:"*"admin."*) flunk "mixed: names match case-insensitively" ;; *) pass "mixed: names match case-insensitively" ;; esac

echo "# a wrong address inside the block is rewritten, not reported as someone else's line"
{
  printf '127.0.0.1 localhost\n'
  printf '# BEGIN rsl-commerce\n10.0.0.9 api.%s\n# END rsl-commerce\n' "$RSL_DOMAIN"
} >"$T/inblock"
{
  printf '127.0.0.1 localhost\n'
  # shellcheck disable=SC2046
  block lf $(all)
} >"$T/inblock.want"
expect inblock
out=$(report "$T/inblock" || true)
case $out in *"missing:"*"api.$RSL_DOMAIN"*) pass "inblock: --check lists it as missing" ;; *) flunk "inblock: --check lists it as missing" ;; esac
case $out in *"points at"*) flunk "inblock: no conflict reported" ;; *) pass "inblock: no conflict reported" ;; esac

echo "# nothing missing"
all | sed 's/^/127.0.0.1 /' >"$T/complete"
cp "$T/complete" "$T/complete.want"
expect complete
check "complete: --check passes" report "$T/complete"

echo "# a damaged block"
printf '# BEGIN rsl-commerce\n127.0.0.1 api.%s\n' "$RSL_DOMAIN" >"$T/damaged"
refuse "damaged: --print refuses" render "$T/damaged"
out=$(report "$T/damaged" 2>&1 || true)
case $out in *damaged*) pass "damaged: --check says so" ;; *) flunk "damaged: --check says so" ;; esac
printf '# END rsl-commerce\n' >"$T/stray-end"
refuse "stray END: --print refuses" render "$T/stray-end"

echo "# apply refuses fixtures"
refuse "RSL_HOSTS_FILE can't be applied" env RSL_HOSTS_FILE="$T/lf" sh scripts/hosts.sh

echo
if [ "$failures" -eq 0 ]; then
  echo "hosts.test.sh: all checks passed"
else
  echo "hosts.test.sh: $failures check(s) failed"
  exit 1
fi

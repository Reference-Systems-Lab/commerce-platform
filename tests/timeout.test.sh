#!/bin/sh
# Tests with_timeout in scripts/lib.sh: a command that finishes keeps its status, one that runs too
# long is stopped with 124 soon after the limit, one that ignores TERM is killed, and a command
# substitution around it returns as soon as the command does, not when the limit runs out. Runs
# under any POSIX sh, including macOS's.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

failures=0
pass() { printf 'ok    %s\n' "$1"; }
flunk() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}

# status <command...>: the exit status of the command.
status() {
  s=0
  "$@" || s=$?
  echo "$s"
}

if [ "$(status with_timeout 5 true)" -eq 0 ]; then pass "a command that succeeds returns 0"; else
  flunk "a command that succeeds returns 0"
fi

if [ "$(status with_timeout 5 sh -c 'exit 3')" -eq 3 ]; then pass "a command that fails keeps its status"; else
  flunk "a command that fails keeps its status"
fi

started=$(date +%s)
got=$(status with_timeout 1 sleep 10)
took=$(($(date +%s) - started))
if [ "$got" -eq 124 ]; then pass "a command past the limit returns 124"; else
  flunk "a command past the limit returns 124 (got $got)"
fi
if [ "$took" -le 4 ]; then pass "it is stopped soon after the limit (${took}s)"; else
  flunk "it is stopped soon after the limit (took ${took}s)"
fi

started=$(date +%s)
# The child's output goes to /dev/null, as dhi_unreadable's does, so it can't hold this pipe open.
got=$(status with_timeout 1 sh -c 'trap "" TERM; sleep 10 >/dev/null 2>&1')
took=$(($(date +%s) - started))
if [ "$got" -eq 124 ] && [ "$took" -le 6 ]; then
  pass "a command that ignores TERM is killed (${took}s)"
else
  flunk "a command that ignores TERM is killed (got $got after ${took}s)"
fi

started=$(date +%s)
out=$(with_timeout 20 echo finished)
took=$(($(date +%s) - started))
if [ "$out" = finished ] && [ "$took" -le 3 ]; then
  pass "a command substitution returns when the command does (${took}s)"
else
  flunk "a command substitution returns when the command does (got '$out' after ${took}s)"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "timeout.test.sh: all checks passed"
else
  echo "timeout.test.sh: $failures check(s) failed"
  exit 1
fi

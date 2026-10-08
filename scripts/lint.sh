#!/bin/sh
# Static checks, the same locally (make lint) and in CI: both Compose files, the nginx config, every
# shell script (shellcheck), the Dockerfiles (hadolint), that every image and action is pinned, and the
# CA and hosts tests. The linters run from compose.tools.yaml. nginx -t loads the certificate, so run
# 'make bootstrap' (or 'sh scripts/bootstrap.sh --ci') first.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

if [ ! -f .env ] || [ ! -f certs/leaf/cert.pem ]; then
  die "the checks need .env and the certificates. Run 'make bootstrap' (or 'sh scripts/bootstrap.sh --ci') first."
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

# step <description> <command...>: run a check, showing its output only when it fails.
step() {
  d=$1
  shift
  if "$@" >"$tmp/out" 2>&1; then
    ok "$d"
  else
    fail "$d"
    sed 's/^/        /' "$tmp/out"
    failures=$((failures + 1))
  fi
}

# unpinned: every image, FROM and uses: line without a digest or commit SHA.
unpinned() {
  grep -nE '^[[:space:]]*image:' compose.yaml compose.tools.yaml | grep -vE '@sha256:[0-9a-f]{64}' || true
  grep -nE '^FROM ' images/*/Dockerfile | grep -vE '@sha256:[0-9a-f]{64}' || true
  grep -nE '^[[:space:]]*(- )?uses:' .github/workflows/*.yml | grep -vE '@[0-9a-f]{40} # v[0-9]' || true
}
pinned() {
  unpinned >"$tmp/unpinned"
  [ ! -s "$tmp/unpinned" ] || {
    cat "$tmp/unpinned"
    return 1
  }
  # Derived images are built here, never pulled by name.
  [ "$(grep -c '^[[:space:]]*build:' compose.yaml)" = "$(grep -c '^[[:space:]]*pull_policy: build' compose.yaml)" ] || {
    echo "a service with build: lacks pull_policy: build"
    return 1
  }
}

tools() { docker compose -f compose.tools.yaml run --rm --quiet-pull "$@"; }

step "compose.yaml is valid" docker compose config --quiet
step "compose.tools.yaml is valid" docker compose -f compose.tools.yaml config --quiet
step "nginx accepts the proxy config" docker compose run --rm --no-deps --quiet-pull --entrypoint nginx proxy -t
# shellcheck disable=SC2046 # one argument per file
step "shellcheck: every shell script" tools shellcheck -x $(git ls-files '*.sh' '.githooks/*')
# shellcheck disable=SC2046
step "hadolint: every Dockerfile" tools hadolint $(git ls-files 'images/*/Dockerfile')
step "every image, base image and action is pinned" pinned
step "tests/ca.test.sh" sh tests/ca.test.sh
step "tests/hosts.test.sh" sh tests/hosts.test.sh

echo
[ "$failures" -eq 0 ] || {
  info "$failures check(s) failed."
  exit 1
}
info "All checks passed."

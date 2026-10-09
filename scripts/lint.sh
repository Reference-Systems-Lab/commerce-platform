#!/bin/sh
# Static checks, the same locally (make lint) and in CI: both Compose files, the nginx config, every
# shell script (shellcheck), the Dockerfiles (hadolint), that every image, action and application fragment
# is pinned and each fragment matches its image's release, and the CA and hosts tests. The linters run from compose.tools.yaml. nginx -t loads the certificate, so run
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
  grep -nE '^[[:space:]]*image:' compose.yaml compose.tools.yaml compose/*.yaml | grep -vE '@sha256:[0-9a-f]{64}' || true
  # An application's fragment: fetched at a release's commit, with the release in a comment.
  grep -nE '\.git#' compose.yaml | grep -vE '\.git#[0-9a-f]{40}:[^ ]+ # v[0-9]+\.[0-9]+\.[0-9]+$' || true
  grep -nE '^FROM ' images/*/Dockerfile | grep -vE '@sha256:[0-9a-f]{64}' || true
  grep -nE '^[[:space:]]*(- )?uses:' .github/workflows/*.yml | grep -vE '@[0-9a-f]{40} # v[0-9]' || true
}
pinned() {
  unpinned >"$tmp/unpinned"
  [ ! -s "$tmp/unpinned" ] || {
    cat "$tmp/unpinned"
    return 1
  }
  # Derived images and local builds are built here, never pulled by name.
  for f in compose.yaml compose/local/*.yaml; do
    [ "$(grep -c '^[[:space:]]*build:' "$f")" = "$(grep -c '^[[:space:]]*pull_policy: build' "$f")" ] || {
      echo "$f: a service with build: lacks pull_policy: build"
      return 1
    }
  done
}

# releases_agree: for each application included in compose.yaml, the wiring's image tags are the
# release the include names, and the include's commit is what that release's tag points to (so a bump
# changes all three together; Dependabot bumps only the image).
releases_agree() {
  ok_all=0
  grep -E '\.git#[0-9a-f]{40}:' compose.yaml | sed 's/^[[:space:]]*-[[:space:]]*//' >"$tmp/includes"
  [ -s "$tmp/includes" ] || { echo "no application includes found in compose.yaml"; return 1; }
  while read -r url _ version; do
    repo=${url%%.git#*}
    commit=${url#*.git#}
    commit=${commit%%:*}
    app=${repo##*/commerce-}
    wiring=compose/compose.$app.yaml
    [ -f "$wiring" ] || { echo "$repo: no wiring file $wiring"; ok_all=1; continue; }
    tags=$(sed -n 's/^[[:space:]]*image:[^:]*:\([^@]*\)@.*/\1/p' "$wiring" | sort -u)
    [ "$tags" = "${version#v}" ] || { echo "$wiring: image tag(s) '$tags' but compose.yaml includes $app's $version"; ok_all=1; }
    tagged=$(git ls-remote "$repo.git" "refs/tags/$version^{}" "refs/tags/$version" | sort -r | head -n 1 | cut -f1)
    [ "$tagged" = "$commit" ] || { echo "compose.yaml includes $app at $commit, but its $version tag is '$tagged'"; ok_all=1; }
  done <"$tmp/includes"
  return "$ok_all"
}

tools() { docker compose -f compose.tools.yaml run --rm --quiet-pull "$@"; }

step "compose.yaml is valid" docker compose config --quiet
step "compose.tools.yaml is valid" docker compose -f compose.tools.yaml config --quiet
for f in compose/local/*.yaml; do
  step "$f is valid with compose.yaml" docker compose -f compose.yaml -f "$f" config --quiet
done
step "nginx accepts the proxy config" docker compose run --rm --no-deps --quiet-pull --entrypoint nginx proxy -t
# shellcheck disable=SC2046 # one argument per file
step "shellcheck: every shell script" tools shellcheck -x $(git ls-files '*.sh' '.githooks/*')
# shellcheck disable=SC2046
step "hadolint: every Dockerfile" tools hadolint $(git ls-files 'images/*/Dockerfile')
step "every image, base image, action and application fragment is pinned" pinned
step "each application's fragment and image are the same release" releases_agree
step "tests/ca.test.sh" sh tests/ca.test.sh
step "tests/hosts.test.sh" sh tests/hosts.test.sh

echo
[ "$failures" -eq 0 ] || {
  info "$failures check(s) failed."
  exit 1
}
info "All checks passed."

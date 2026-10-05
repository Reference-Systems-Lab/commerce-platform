# Sourced by each hook. Stops the commit rather than letting it through unscanned.
if ! command -v git-secrets >/dev/null 2>&1; then
  echo "git-secrets is not installed: https://github.com/awslabs/git-secrets#installing-git-secrets" >&2
  exit 1
fi
if ! git config --get-all secrets.patterns >/dev/null; then
  echo "git-secrets has no patterns in this clone. Run .githooks/setup." >&2
  exit 1
fi

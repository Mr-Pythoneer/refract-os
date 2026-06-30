#!/usr/bin/env bash
#
# Tiny assertion library for the Crucible OS test suite. Source from each
# test_*.sh. Works the same under macOS (homebrew bash) and the Ubuntu CI
# runner — which matters: some behaviour (GNU vs BSD coreutils) only shows up
# on the real target OS, so these tests exist to run in CI, not just locally.

set -uo pipefail

TESTS_RUN=0
TESTS_PASS=0
TESTS_FAIL=0

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export REPO_ROOT

_red=$'\033[31m'; _green=$'\033[32m'; _dim=$'\033[2m'; _reset=$'\033[0m'

pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASS=$((TESTS_PASS+1)); echo "  ${_green}ok${_reset}   $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)); echo "  ${_red}FAIL${_reset} $1"; [ -n "${2:-}" ] && echo "       ${_dim}$2${_reset}"; }
note() { echo "  ${_dim}- $1${_reset}"; }

assert_eq() {        # assert_eq "desc" "expected" "actual"
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
assert_contains() {  # assert_contains "desc" "haystack" "needle"
  case "$2" in *"$3"*) pass "$1";; *) fail "$1" "missing [$3] in: $2";; esac
}
assert_not_contains() {
  case "$2" in *"$3"*) fail "$1" "unexpectedly contains [$3]";; *) pass "$1";; esac
}

is_linux() { [ "$(uname)" = "Linux" ]; }

new_stubdir() { mktemp -d "${TMPDIR:-/tmp}/cos-test.XXXXXX"; }

# stub <dir> <name> <body>  — write an executable stub onto a PATH dir
stub() {
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$3"; } > "$1/$2"
  chmod +x "$1/$2"
}

finish() {
  echo "  ${TESTS_PASS}/${TESTS_RUN} assertions passed"
  [ "$TESTS_FAIL" -eq 0 ]
}

#!/usr/bin/env bash
#
# Runs every tests/test_*.sh and tallies results. Each test file is
# self-contained (sources lib.sh, sets up its own stubs) and exits non-zero
# if any assertion fails. Designed to run BOTH locally (homebrew bash on
# macOS) and on the Ubuntu CI runner — some assertions only matter on the
# real target OS (GNU coreutils) and are guarded with is_linux.
#
# Usage: ./tests/run.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_red=$'\033[31m'; _green=$'\033[32m'; _cyan=$'\033[36m'; _reset=$'\033[0m'

files=("$TESTS_DIR"/test_*.sh)
total=${#files[@]}
failed=0

for t in "${files[@]}"; do
    echo "${_cyan}== $(basename "$t") ==${_reset}"
    if bash "$t"; then :; else failed=$((failed+1)); fi
done

echo
if [ "$failed" -eq 0 ]; then
    echo "${_green}All $total test files passed.${_reset}"
    exit 0
else
    echo "${_red}$failed of $total test files FAILED.${_reset}"
    exit 1
fi

#!/usr/bin/env bash
# Tests for modes/modectl/distro-modectl (pure control-flow, no real services).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODECTL="$REPO_ROOT/modes/modectl/distro-modectl"

# status with no recorded mode -> "unknown", exit 0
out="$("$MODECTL" status 2>&1)"; rc=$?
assert_eq "status exits 0" "0" "$rc"
assert_contains "status reports unknown when no mode recorded" "$out" "unknown"

# usage (no args) -> pipe-separated mode list, exit 1
out="$("$MODECTL" 2>&1)"; rc=$?
assert_eq "no-args usage exits 1" "1" "$rc"
assert_contains "usage shows pipe-separated modes" "$out" "gaming|ai|server|creative|normal"

# --yes is forwarded across the sudo re-exec (regression test for the audit fix)
sd="$(new_stubdir)"
stub "$sd" id 'if [ "$1" = "-u" ]; then echo 1000; else exit 0; fi'
stub "$sd" sudo 'echo "REEXEC: $*"; exit 0'
out="$(PATH="$sd:$PATH" "$MODECTL" switch server --yes </dev/null 2>&1)"
assert_contains "switch --yes re-execs WITH --yes" "$out" "REEXEC: $MODECTL switch server --yes"

# non-interactive switch WITHOUT --yes refuses to silently prompt
stub "$sd" id 'if [ "$1" = "-u" ]; then echo 1000; else exit 0; fi'
out="$(PATH="$sd:$PATH" "$MODECTL" switch server </dev/null 2>&1)"; rc=$?
assert_contains "non-interactive switch w/o --yes refuses" "$out" "Refusing to prompt"
rm -rf "$sd"

finish

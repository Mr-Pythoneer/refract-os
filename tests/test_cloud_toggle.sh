#!/usr/bin/env bash
# Tests for modes/ai/bin/distro-ai-cloud-toggle (OpenCode cloud opt-in).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOGGLE="$REPO_ROOT/modes/ai/bin/distro-ai-cloud-toggle"
work="$(new_stubdir)"; cd "$work" || exit 1

# status with no opencode.json -> "not enabled"
out="$("$TOGGLE" status 2>&1)"
assert_contains "status reports not-enabled in a clean dir" "$out" "not enabled"

# enable WITHOUT a key -> refuses, exit 1, does not write opencode.json
unset ANTHROPIC_API_KEY
out="$("$TOGGLE" enable 2>&1)"; rc=$?
assert_eq "enable without key exits 1" "1" "$rc"
assert_contains "enable without key explains why" "$out" "ANTHROPIC_API_KEY is not set"
[ ! -f opencode.json ] && pass "enable without key writes no opencode.json" || fail "enable without key writes no opencode.json"

# enable WITH a key -> copies the cloud config, status then reports ENABLED
out="$(ANTHROPIC_API_KEY=sk-test "$TOGGLE" enable 2>&1)"; rc=$?
assert_eq "enable with key exits 0" "0" "$rc"
[ -f opencode.json ] && pass "enable with key writes opencode.json" || fail "enable with key writes opencode.json"
grep -q "claude-cloud" opencode.json 2>/dev/null && pass "written config references claude-cloud" || fail "written config references claude-cloud"
out="$("$TOGGLE" status 2>&1)"
assert_contains "status reports ENABLED after enable" "$out" "ENABLED"

cd /; rm -rf "$work"
finish

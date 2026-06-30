#!/usr/bin/env bash
# Tests for modes/gaming/bin/distro-gaming-compat (DB loader).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CC="$REPO_ROOT/modes/gaming/bin/distro-gaming-compat"

# list -> shows known entries
out="$("$CC" list 2>&1)"; rc=$?
assert_eq "list exits 0" "0" "$rc"
assert_contains "list shows ms-office-classic" "$out" "ms-office-classic"
assert_contains "list shows discord (native-alt)" "$out" "discord"

# show <id> -> valid JSON
out="$("$CC" show ms-office-classic 2>&1)"; rc=$?
assert_eq "show known id exits 0" "0" "$rc"
assert_contains "show emits the status" "$out" "workaround"
echo "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && pass "show emits valid JSON" || fail "show emits valid JSON"

# show unknown -> exit 1
"$CC" show no-such-id >/dev/null 2>&1; assert_eq "show unknown id exits 1" "1" "$?"

# apply broken (no reliable fix) -> exit 1 with explanation
out="$("$CC" apply itunes 2>&1)"; rc=$?
assert_eq "apply broken-status exits 1" "1" "$rc"
assert_contains "apply broken explains no fix" "$out" "no reliable Wine workaround"

# apply native-alternative -> exit 0, points at flatpak/apt
out="$("$CC" apply discord 2>&1)"; rc=$?
assert_eq "apply native-alt exits 0" "0" "$rc"
assert_contains "apply native-alt suggests install" "$out" "install"

# apply workaround with a stub winetricks -> invokes winetricks with the verbs
sd="$(new_stubdir)"
stub "$sd" winetricks 'echo "WT: $*"; exit 0'
out="$(PATH="$sd:$PATH" "$CC" apply ms-office-classic /tmp/wp-test 2>&1)"; rc=$?
assert_eq "apply workaround exits 0" "0" "$rc"
assert_contains "apply workaround runs winetricks with a verb" "$out" "WT: -q gdiplus"
rm -rf "$sd"

# KeyError-regression: a malformed 'workaround' entry missing winetricks_verbs
# must hit the friendly guard, NOT a Python traceback.
td="$(new_stubdir)"; mkdir -p "$td/bin" "$td/compat-db"
cp "$CC" "$td/bin/distro-gaming-compat"
printf '%s\n' '{"schema_version":1,"apps":[{"id":"x","name":"X","status":"workaround"}]}' > "$td/compat-db/apps.json"
out="$("$td/bin/distro-gaming-compat" apply x 2>&1)"; rc=$?
assert_eq "malformed entry exits 0 (friendly guard)" "0" "$rc"
assert_not_contains "malformed entry shows no traceback" "$out" "Traceback"
rm -rf "$td"

finish

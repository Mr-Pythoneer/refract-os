#!/usr/bin/env bash
#
# distro-powerctl drops Normal mode to power-saver on battery and back on mains,
# and must leave every other mode alone. The "leave alone" half is the part that
# would be invisible if it broke: a Gaming session quietly turned down on unplug
# looks like the machine getting slower for no reason, with nothing on screen to
# explain it.
#
# CI runners have no battery, so the power-supply tree is a fixture.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PWRCTL="$REPO_ROOT/modes/power/distro-powerctl"

sb="$(new_stubdir)"
trap 'rm -rf "$sb"' EXIT
export REFRACT_POWER_SUPPLY_DIR="$sb/power_supply"
export REFRACT_POWER_CONFIG="$sb/power-auto"
export STATE_FILE="$sb/current-mode"
mkdir -p "$REFRACT_POWER_SUPPLY_DIR/AC0" "$REFRACT_POWER_SUPPLY_DIR/BAT0"
echo Mains   > "$REFRACT_POWER_SUPPLY_DIR/AC0/type"
echo Battery > "$REFRACT_POWER_SUPPLY_DIR/BAT0/type"

# powerprofilesctl stub with real state: `get` prints it, `set` stores it.
PROFILE="$sb/profile"; echo balanced > "$PROFILE"
stub "$sb" powerprofilesctl "
if [ \"\$1\" = get ]; then cat '$PROFILE'; exit 0; fi
if [ \"\$1\" = set ]; then echo \"\$2\" > '$PROFILE'; echo \"set \$2\" >> '$sb/pplog'; exit 0; fi
exit 0
"
export PATH="$sb:$PATH"

plug()   { echo 1 > "$REFRACT_POWER_SUPPLY_DIR/AC0/online"; }
unplug() { echo 0 > "$REFRACT_POWER_SUPPLY_DIR/AC0/online"; }
mode()   { echo "$1" > "$STATE_FILE"; }
prof()   { cat "$PROFILE"; }
run()    { bash "$PWRCTL" "$@" 2>&1; }

# --- Normal mode follows the cable ------------------------------------------
mode normal; plug;  run apply >/dev/null
assert_eq "Normal on mains -> balanced" "balanced" "$(prof)"
unplug; run apply >/dev/null
assert_eq "Normal on battery -> power-saver" "power-saver" "$(prof)"
plug; run apply >/dev/null
assert_eq "plugging back in -> balanced" "balanced" "$(prof)"

# --- every other mode is left alone -----------------------------------------
# THE POINT. Gaming/AI/Creative are explicit requests for performance. Turning
# one down on unplug silently undoes what the user asked for.
for m in gaming ai creative server; do
    mode "$m"
    echo performance > "$PROFILE"
    unplug; run apply >/dev/null
    assert_eq "$m mode on battery is NOT turned down" "performance" "$(prof)"
done

# --- no mains supply at all (a desktop) -------------------------------------
mode normal
rm -rf "$REFRACT_POWER_SUPPLY_DIR/AC0"
echo performance > "$PROFILE"
run apply >/dev/null
assert_eq "a machine with no mains supply is left alone" "performance" "$(prof)"
assert_contains "status says so plainly" "$(run status)" "no battery on this machine"
mkdir -p "$REFRACT_POWER_SUPPLY_DIR/AC0"; echo Mains > "$REFRACT_POWER_SUPPLY_DIR/AC0/type"

# --- no redundant writes ----------------------------------------------------
# p-p-d broadcasts every profile change and GNOME shows a toast for it. udev can
# fire power_supply events every few seconds while charging, so a no-op write
# would be a notification about nothing, repeatedly.
mode normal; plug; run apply >/dev/null
: > "$sb/pplog"
run apply >/dev/null; run apply >/dev/null
# `grep -c` PRINTS 0 and EXITS 1 when it matches nothing, so the obvious
# `|| echo 0` fallback appends a SECOND zero and the count becomes "0\n0".
n="$(grep -c 'set ' "$sb/pplog" 2>/dev/null)" || n=0
assert_eq "re-applying an already-correct profile writes nothing" "0" "$n"

# --- the off switch ---------------------------------------------------------
echo off > "$REFRACT_POWER_CONFIG"
echo performance > "$PROFILE"
unplug; run apply >/dev/null
assert_eq "disabled means disabled" "performance" "$(prof)"
rm -f "$REFRACT_POWER_CONFIG"
run apply >/dev/null
assert_eq "absent config defaults to ON" "power-saver" "$(prof)"

# --- never fails a udev-triggered unit --------------------------------------
# udev fires this on every machine in every mode. A non-zero exit here would
# fill the journal with failed units on a perfectly healthy box.
for m in normal gaming server; do
    mode "$m"
    bash "$PWRCTL" apply >/dev/null 2>&1
    assert_eq "apply exits 0 in $m mode" "0" "$?"
done

finish

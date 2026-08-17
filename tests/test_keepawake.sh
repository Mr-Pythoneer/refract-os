#!/usr/bin/env bash
#
# distro-keepawake holds a sleep inhibitor while something is downloading — and
# ONLY on mains. The battery half is the one that matters most: a laptop that
# refuses to sleep because something is trickling in the background is how you
# come back to a flat one, and that failure is invisible until the battery is
# already gone.
#
# The rate maths is unit-tested directly rather than by watching a real download,
# because the interesting cases (a counter reset, a stall inside the grace
# period) are ones a real download will not produce on demand.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KA="$REPO_ROOT/modes/power/distro-keepawake"

sb="$(new_stubdir)"
trap 'rm -rf "$sb"' EXIT
export REFRACT_POWER_SUPPLY_DIR="$sb/power_supply"
export REFRACT_NETDEV="$sb/netdev"
export REFRACT_KEEPAWAKE_CONFIG="$sb/keepawake"
mkdir -p "$REFRACT_POWER_SUPPLY_DIR/AC0"
echo Mains > "$REFRACT_POWER_SUPPLY_DIR/AC0/type"

# SOURCE the script, never sed the functions out of it. rx_bytes embeds an awk
# program in single quotes, which terminates whatever quoting an extraction is
# wrapped in — the first version of this test did that and simply hung, waiting
# for a quote that never came.
kaf() {  # kaf <function> [args…] -> run the real function in a subshell
    ( DISTRO_KEEPAWAKE_SOURCE=1; export DISTRO_KEEPAWAKE_SOURCE
      # shellcheck disable=SC1090
      . "$KA"; "$@" )
}

netdev() {  # netdev <lo_rx> <eth_rx>
    cat > "$REFRACT_NETDEV" <<EOF
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes
    lo: $1 100 0 0 0 0 0 0 500 5 0 0 0 0 0 0
  eth0: $2 200 0 0 0 0 0 0 900 9 0 0 0 0 0 0
EOF
}

# --- loopback must not count as a download ----------------------------------
# A local backup or a container pulling from a local registry is not the case
# this exists for, and loopback traffic can be enormous — counting it would pin
# a laptop awake for something that never touched the network.
netdev 999999999 4096
got="$(kaf rx_bytes)"
assert_eq "loopback bytes are excluded from the download total" "4096" "$got"

# --- the rate maths ---------------------------------------------------------
rate() {  # rate <prev> <now> <interval>
    ( REFRACT_KEEPAWAKE_INTERVAL="$3"; export REFRACT_KEEPAWAKE_INTERVAL
      kaf current_kbs "$1" "$2" )
}
assert_eq "1 MB over 10s reads as 102 KB/s" "102" "$(rate 0 1048576 10)"
assert_eq "no traffic reads as 0 KB/s"      "0"   "$(rate 500 500 10)"
# An interface counter can wrap or reset when a device re-appears. Treating that
# as a colossal negative — or as a huge positive — would either wedge the
# inhibitor on or drop it at the worst moment.
assert_eq "a counter reset reads as 0, not a negative or a spike" "0" "$(rate 5000 10 10)"

# --- on battery it must do nothing ------------------------------------------
# Asked for explicitly. Verified through the real on_ac(), not by reading it.
onac() { if kaf on_ac; then echo mains; else echo battery; fi; }
echo 1 > "$REFRACT_POWER_SUPPLY_DIR/AC0/online"
assert_eq "plugged in is detected as mains" "mains" "$(onac)"
echo 0 > "$REFRACT_POWER_SUPPLY_DIR/AC0/online"
assert_eq "unplugged is detected as battery — the whole point" "battery" "$(onac)"

# A desktop has no mains supply entry at all; it also never goes into a bag.
rm -rf "$REFRACT_POWER_SUPPLY_DIR/AC0"
assert_eq "a machine with no battery counts as plugged in" "mains" "$(onac)"
mkdir -p "$REFRACT_POWER_SUPPLY_DIR/AC0"; echo Mains > "$REFRACT_POWER_SUPPLY_DIR/AC0/type"; echo 1 > "$REFRACT_POWER_SUPPLY_DIR/AC0/online"

# --- the off switch ---------------------------------------------------------
netdev 0 0
echo off > "$REFRACT_KEEPAWAKE_CONFIG"
out="$(bash "$KA" run 2>&1)"
assert_contains "disabled means it exits immediately" "$out" "disabled"
rm -f "$REFRACT_KEEPAWAKE_CONFIG"

# --- status never lies about the battery case -------------------------------
echo 0 > "$REFRACT_POWER_SUPPLY_DIR/AC0/online"
out="$(bash "$KA" status 2>&1)"
assert_contains "status says it is inactive on battery" "$out" "deliberately inactive"
echo 1 > "$REFRACT_POWER_SUPPLY_DIR/AC0/online"
out="$(bash "$KA" status 2>&1)"
assert_contains "status says it is active on mains" "$out" "plugged in"

# --- the inhibitor must be released on exit ---------------------------------
# A leaked inhibitor is a laptop that never sleeps again until reboot, with
# nothing on screen explaining why — strictly worse than the problem this solves.
assert_contains "an EXIT trap releases the lock" "$(cat "$KA")" "trap cleanup EXIT INT TERM"
assert_contains "the unit is a USER unit tied to the session" \
    "$(cat "$REPO_ROOT/modes/power/systemd/user/refract-keepawake.service")" "PartOf=graphical-session.target"

finish

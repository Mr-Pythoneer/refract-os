#!/usr/bin/env bash
#
# Trackpad gestures. The property that matters most is that this does the RIGHT
# NOTHING on Wayland — GNOME's own gestures are already active there, touchegg
# cannot send input to a Wayland compositor, and a tool that cheerfully reports
# "configured" while having achieved nothing is worse than one that says it is
# not needed.
#
# The gesture config itself is validated as XML and against GNOME's real
# keybindings, because a typo in a <keys> element does not error anywhere — the
# gesture just silently does nothing, which is indistinguishable from the bug
# this whole feature exists to fix.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GES="$REPO_ROOT/modes/normal/bin/distro-gestures"
CONF="$REPO_ROOT/modes/normal/gestures/touchegg.conf"

sb="$(new_stubdir)"
trap 'rm -rf "$sb"' EXIT
export XDG_CONFIG_HOME="$sb/config"
export REFRACT_GESTURES_CONF="$CONF"

run() { bash "$GES" "$@" 2>&1; }

# --- Wayland: say so, change nothing ----------------------------------------
out="$(XDG_SESSION_TYPE=wayland run status)"
assert_contains "on Wayland it reports GNOME handles gestures" "$out" "handled by GNOME itself"
out="$(XDG_SESSION_TYPE=wayland run setup)"
assert_contains "on Wayland setup is a no-op that says why" "$out" "Nothing to do"
if [ -e "$XDG_CONFIG_HOME/touchegg/touchegg.conf" ]; then
    fail "Wayland setup writes no touchegg config" "touchegg cannot work on Wayland"
else
    pass "Wayland setup writes no touchegg config"
fi

# --- X11 without touchegg: name the missing piece ---------------------------
out="$(XDG_SESSION_TYPE=x11 PATH="$sb/empty:/usr/bin:/bin" run status)"
assert_contains "on X11 it explains GNOME's gestures are Wayland-only" \
    "$out" "do not work on Xorg"

# --- X11 with touchegg: install the config ----------------------------------
stub "$sb" touchegg 'exit 0'
stub "$sb" systemctl 'exit 3'   # "inactive", the realistic first-run state
out="$(XDG_SESSION_TYPE=x11 PATH="$sb:$PATH" run setup)"
assert_contains "on X11 setup reports success" "$out" "Gestures configured"
dst="$XDG_CONFIG_HOME/touchegg/touchegg.conf"
if [ -r "$dst" ]; then pass "the config is written to the user's own config dir"
else fail "the config is written to the user's own config dir"; fi

# --- NEVER clobber a config somebody tuned ----------------------------------
# touchegg's config is exactly the kind of file people edit. Replacing it on an
# update would undo their work with no warning and no way to notice.
printf '<touchégg><!-- mine --></touchégg>\n' > "$dst"
out="$(XDG_SESSION_TYPE=x11 PATH="$sb:$PATH" run setup)"
assert_contains "a hand-edited config is left alone, loudly" "$out" "leaving it alone"
assert_contains "and its contents survive" "$(cat "$dst")" "mine"

# --- the config itself -------------------------------------------------------
out="$(python3 - "$CONF" <<'PY'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
g = r.findall('.//gesture')
print("COUNT", len(g))
# Every gesture must carry an action with an <on> phase; touchegg silently
# ignores one that does not, so a missing element is a dead gesture.
bad = [x.get('type') for x in g if x.find('action/on') is None]
print("ALL_HAVE_PHASE", not bad)
# Two-finger horizontal must be scoped to browsers ONLY. Globally it would
# hijack every sideways scroll in a spreadsheet or an editor, which is the most
# irritating thing a gesture daemon can be configured to do.
glob = r.find("application[@name='All']")
two = [x for x in glob.findall('gesture') if x.get('fingers') == '2']
print("NO_GLOBAL_TWO_FINGER", not two)
apps = [a.get('name') for a in r.findall('application') if a.get('name') != 'All']
print("HAS_BROWSER_SCOPE", any('chrome' in (n or '').lower() for n in apps))
# The bindings must be GNOME's own, or gestures and the keyboard disagree.
keys = {(x.findtext('action/modifiers',''), x.findtext('action/keys','')) for x in g}
print("USES_SUPER", any('Super' in m for m, _ in keys))
print("APPGRID_IS_SUPER_A", ('Super_L', 'A') in keys)
PY
)"
get() { printf '%s\n' "$out" | awk -v k="$1" '$1==k {print $2; exit}'; }
n="$(get COUNT)"
if [ "${n:-0}" -ge 8 ]; then pass "the config defines $n gestures"; else fail "the config defines gestures" "$out"; fi
assert_eq "every gesture declares an action phase" "True" "$(get ALL_HAVE_PHASE)"
assert_eq "two-finger swipe is NOT bound globally" "True" "$(get NO_GLOBAL_TWO_FINGER)"
assert_eq "two-finger back/forward is scoped to browsers" "True" "$(get HAS_BROWSER_SCOPE)"
assert_eq "gestures use GNOME's Super key, not invented shortcuts" "True" "$(get USES_SUPER)"
assert_eq "four-finger up is GNOME's real app-grid binding" "True" "$(get APPGRID_IS_SUPER_A)"

# --- the Wayland switch must document the way back --------------------------
# It edits GDM to use a session that is known to hang on some Intel panels. A
# black screen with no printed recovery path is how somebody reinstalls a machine
# that was fine.
src="$(cat "$GES")"
assert_contains "switching to Wayland warns about the hang" "$src" "black screen"
assert_contains "and prints the console recovery path"      "$src" "Ctrl+Alt+F3"
assert_contains "and the exact command to undo it"          "$src" "distro-gestures wayland off"

finish

#!/usr/bin/env bash
#
# distro-appgrid hides stock launchers that Refract's own tools replace. It edits
# what the desktop advertises, so it is run for real here against fixture
# directories rather than checked by reading its source.
#
# The properties that matter are all about NOT doing damage: the app must stay
# launchable, a local customisation must never be clobbered, and every hide must
# be exactly reversible.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPGRID="$REPO_ROOT/modes/appgrid/distro-appgrid"

sb="$(new_stubdir)"
trap 'rm -rf "$sb"' EXIT
export REFRACT_STOCK_DIR="$sb/usr-share"
export REFRACT_SHADOW_DIR="$sb/usr-local-share"
mkdir -p "$REFRACT_STOCK_DIR" "$REFRACT_SHADOW_DIR"

# The IDs here are the ones install-smoke's app-grid inventory reported from the
# shipped image, not plausible-looking guesses. An earlier version of the tool
# named gnome-system-monitor.desktop, which does not exist on Ubuntu 24.04, so
# dedupe matched nothing and reported success — and a fixture using the same
# wrong name would have passed right alongside it.
cat > "$REFRACT_STOCK_DIR/org.gnome.SystemMonitor.desktop" <<'EOF'
[Desktop Entry]
Name=System Monitor
Exec=gnome-system-monitor
Icon=org.gnome.SystemMonitor
Type=Application
MimeType=application/x-foo;
EOF
cat > "$REFRACT_STOCK_DIR/update-manager.desktop" <<'EOF'
[Desktop Entry]
Name=Software Updater
Exec=/usr/bin/update-manager
Icon=system-software-update
Type=Application
EOF

run() { bash "$APPGRID" "$@" 2>&1; }

# --- before -----------------------------------------------------------------
out="$(run status)"
assert_contains "status reports an unhidden duplicate" "$out" "still in the app grid"

# --- dedupe -----------------------------------------------------------------
run dedupe >/dev/null
shadow="$REFRACT_SHADOW_DIR/org.gnome.SystemMonitor.desktop"
if [ -f "$shadow" ]; then pass "a shadow launcher is written"; else fail "a shadow launcher is written"; fi
assert_contains "the shadow hides the entry" "$(cat "$shadow")" "NoDisplay=true"

# THE POINT OF SHADOWING RATHER THAN DELETING: anything that launches the app by
# desktop-file ID must keep working. Losing Exec would turn "hidden" into
# "broken", and update-notifier launches Software Updater exactly that way.
assert_contains "Exec survives the shadow" "$(cat "$shadow")" "Exec=gnome-system-monitor"
assert_contains "Icon survives the shadow" "$(cat "$shadow")" "Icon=org.gnome.SystemMonitor"
assert_contains "MimeType survives the shadow" "$(cat "$shadow")" "MimeType=application/x-foo;"
if [ -f "$REFRACT_STOCK_DIR/org.gnome.SystemMonitor.desktop" ]; then
    pass "the stock launcher is NOT deleted"
else
    fail "the stock launcher is NOT deleted" "hiding must never become uninstalling"
fi
assert_contains "status now reports one entry per job" "$(run status)" "One entry per job"

# --- idempotent -------------------------------------------------------------
run dedupe >/dev/null
n="$(grep -c '^NoDisplay=true' "$shadow")"
assert_eq "re-running dedupe does not duplicate NoDisplay" "1" "$n"

# --- restore ----------------------------------------------------------------
run restore >/dev/null
if [ -f "$shadow" ]; then fail "restore removes the shadow"; else pass "restore removes the shadow"; fi
assert_contains "status reports the duplicate again" "$(run status)" "still in the app grid"

# --- never clobber somebody else's file -------------------------------------
# A file in /usr/local/share/applications that this tool did not write is a
# local customisation. Overwriting it would be precisely the silent damage the
# shadow mechanism exists to avoid.
printf '[Desktop Entry]\nName=My Own Thing\nExec=mine\nType=Application\n' > "$shadow"
out="$(run dedupe)"
assert_contains "a foreign shadow is skipped, loudly" "$out" "was not written by this tool"
assert_contains "the foreign file is untouched" "$(cat "$shadow")" "Name=My Own Thing"
out="$(run restore)"
assert_contains "restore also refuses to delete a foreign file" "$out" "not written by this tool"
if [ -f "$shadow" ]; then pass "the foreign file survives restore"; else fail "the foreign file survives restore"; fi

# --- an app that isn't installed is not invented ----------------------------
rm -f "$shadow" "$REFRACT_STOCK_DIR/org.gnome.SystemMonitor.desktop"
out="$(run status)"
assert_contains "an absent stock app is reported as nothing to do" "$out" "is not installed"
run dedupe >/dev/null
if [ -f "$shadow" ]; then
    fail "no shadow is written for an app that isn't installed" "would put a dead launcher in the grid"
else
    pass "no shadow is written for an app that isn't installed"
fi

finish

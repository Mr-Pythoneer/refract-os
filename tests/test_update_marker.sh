#!/usr/bin/env bash
#
# The update MARKER is the whole non-terminal update story, so it gets a test.
#
# distro-update's `check` writes ~/.local/state/refract/update-available when a
# newer build exists and removes it when there isn't one. The GNOME top-bar
# extension watches exactly that file and shows "Update available — install…"
# when it is present. That is the only route to an update for somebody who does
# not open a terminal, and it is a contract spread across two files in two
# languages that nothing else checks.
#
# Network-free: `curl` is stubbed, so all three branches are deterministic and
# this runs the same on a CI runner with no egress as on a laptop.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$REPO_ROOT/modes/update/distro-update"
EXT="$REPO_ROOT/iso/gnome-extensions/refract-modes@refract-os/extension.js"

REMOTE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

sb="$(new_stubdir)"
trap 'rm -rf "$sb"' EXIT
MARKER="$sb/state/refract/update-available"

# curl stub: prints the commit JSON remote_commit greps, or fails outright when
# OFFLINE=1 — which is how "could not check" is reproduced without unplugging
# anything.
stub "$sb" curl '
if [ "${OFFLINE:-}" = "1" ]; then exit 7; fi
printf "{\"sha\": \"'"$REMOTE_SHA"'\", \"commit\": {}}\n"
'
export PATH="$sb:$PATH"

# The updater reuses a recent successful answer instead of asking again (see
# tests/test_update_backoff.sh). That cache lives in XDG_CACHE_HOME, so it has
# to be redirected here alongside XDG_STATE_HOME — otherwise this test reads the
# developer's real ~/.cache/refract and its outcome depends on what that machine
# happened to do in the last five minutes.
export REFRACT_CACHE_DIR="$sb/cache"

run_check() {  # run_check <installed-commit> -> exit code, marker side effects
    printf 'REFRACT_COMMIT=%s\n' "$1" > "$sb/build-id"
    XDG_STATE_HOME="$sb/state" REFRACT_BUILD_ID_FILE="$sb/build-id" \
        bash "$UPDATE" check >/dev/null 2>&1
}

# --- behind: the marker appears, holding the commit we could move to ---------
run_check "$OTHER_SHA"; rc=$?
assert_eq "check exits 10 when a newer build exists" "10" "$rc"
if [ -f "$MARKER" ]; then
    pass "marker written when an update is available"
    assert_eq "marker holds the remote commit" "$REMOTE_SHA" "$(cat "$MARKER")"
else
    fail "marker written when an update is available" "no $MARKER"
fi

# --- current: the marker goes, or the top bar nags forever -------------------
run_check "$REMOTE_SHA"; rc=$?
assert_eq "check exits 0 when up to date" "0" "$rc"
if [ -f "$MARKER" ]; then
    fail "marker cleared when up to date" "the top-bar notice would never go away"
else
    pass "marker cleared when up to date"
fi

# --- offline: LEAVE IT ALONE ------------------------------------------------
# "Could not check" is not "up to date". Clearing on a failed lookup would make
# a genuine pending update vanish from the top bar because the wifi blipped.
run_check "$OTHER_SHA" >/dev/null 2>&1   # re-arm the marker
printf 'REFRACT_COMMIT=%s\n' "$OTHER_SHA" > "$sb/build-id"
# Drop the cached answer: with one present no request is sent at all, and this
# case is specifically about what happens when the request FAILS.
rm -f "$sb/cache/last-check"
OFFLINE=1 XDG_STATE_HOME="$sb/state" REFRACT_BUILD_ID_FILE="$sb/build-id" \
    bash "$UPDATE" check >/dev/null 2>&1; rc=$?
assert_eq "check exits 1 when GitHub is unreachable" "1" "$rc"
if [ -f "$MARKER" ]; then
    pass "a failed check does NOT erase a pending update"
else
    fail "a failed check does NOT erase a pending update" "marker was removed"
fi

# --- the cross-file contract -------------------------------------------------
# The path is built independently in bash and in GJS. If either side is renamed
# the badge silently stops appearing, with nothing failing anywhere.
assert_contains "distro-update writes refract/update-available" \
    "$(cat "$UPDATE")" "refract/update-available"
assert_contains "the extension reads the same file" \
    "$(cat "$EXT")" "'refract', 'update-available'"
assert_contains "the extension resolves it under the XDG state dir" \
    "$(cat "$EXT")" "GLib.get_user_state_dir()"

# --- updated machine == freshly installed machine ----------------------------
# `apply` installs the launchers and the update timer itself, because until it
# did, the updater could fix any COMMAND it shipped but never the launcher or
# notification that are the only way a non-terminal user reaches it. That only
# holds if it writes where iso/build.sh writes — otherwise an updated machine
# quietly diverges from a fresh install of the same commit, with two copies of
# each launcher and no error anywhere.
BUILDSH="$REPO_ROOT/iso/build.sh"
for dir in /usr/share/applications /usr/lib/systemd/user; do
    if grep -qF "$dir" "$UPDATE" && grep -qF "$dir" "$BUILDSH"; then
        pass "apply and build.sh agree on $dir"
    else
        fail "apply and build.sh agree on $dir" \
             "update:$(grep -cF "$dir" "$UPDATE") build.sh:$(grep -cF "$dir" "$BUILDSH")"
    fi
done
assert_contains "apply refreshes the app-grid cache" \
    "$(cat "$UPDATE")" "update-desktop-database"

finish

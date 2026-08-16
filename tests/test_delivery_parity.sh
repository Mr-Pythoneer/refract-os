#!/usr/bin/env bash
#
# A fresh install and an updated machine must end up the same.
#
# There are two delivery paths — iso/build.sh at install time and
# `distro-update apply` afterwards — and nothing compared them, which is exactly
# how Refract Tips shipped broken: apply installed its .desktop (pointing at
# /usr/local/bin/refract-tips) but its symlink loop matched only `distro-*`, so
# the launcher existed and the command it launches did not. refract-monitor and
# refract-updates hid the gap because build.sh had created THEIR symlinks at
# install time; it only became visible once an app was added after an image
# shipped, which is the entire purpose of having an updater.
#
# These assertions are deliberately about the CONTRACT between the two files
# rather than about either one alone. A change to one that the other does not
# follow is the failure being guarded against.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUILD="$REPO_ROOT/iso/build.sh"
UPDATE="$REPO_ROOT/modes/update/distro-update"
build_src="$(cat "$BUILD")"
update_src="$(cat "$UPDATE")"

# --- every shipped app must be reachable by BOTH paths ----------------------
# The set is derived from the tree, not hardcoded, so an app added tomorrow is
# checked tomorrow without anyone remembering to edit this file.
apps=()
while IFS= read -r f; do apps+=("$(basename "$f")"); done < <(
    find "$REPO_ROOT/modes" "$REPO_ROOT/drivers" -type f \
         \( -name 'distro-*' -o -name 'refract-*' \) \
         ! -name '*.pyc' ! -name '*.desktop' ! -name '*.service' ! -name '*.timer' \
         ! -path '*/__pycache__/*' ! -path '*/legacy-*/*' 2>/dev/null | sort
)
if [ "${#apps[@]}" -gt 0 ]; then
    pass "found ${#apps[@]} shipped commands to check"
else
    fail "found shipped commands to check" "the discovery glob matched nothing"
fi

# build.sh names each one explicitly; apply finds them with one glob. So the
# check differs per path: build.sh must MENTION it, apply's glob must MATCH it.
missing_build=""
for a in "${apps[@]}"; do
    case "$build_src" in *"$a"*) ;; *) missing_build="$missing_build $a" ;; esac
done
if [ -z "$missing_build" ]; then
    pass "iso/build.sh puts every shipped command in the image"
else
    fail "iso/build.sh puts every shipped command in the image" "missing:$missing_build"
fi

# apply's find must cover refract-* as well as distro-*, and must exclude the
# bytecode py_compile drops beside the Python apps — a .pyc symlinked into PATH
# is a command that does nothing when run.
assert_contains "apply's symlink loop covers refract-* too" \
    "$update_src" "-name 'distro-*' -o -name 'refract-*'"
assert_contains "apply's symlink loop excludes bytecode" \
    "$update_src" "! -name '*.pyc'"
assert_contains "apply's symlink loop excludes __pycache__" \
    "$update_src" "! -path '*/__pycache__/*'"

# Prove the glob actually selects the real apps, rather than trusting the flags.
matched=0
while IFS= read -r _f; do matched=$((matched + 1)); done < <(
    find "$REPO_ROOT/modes" "$REPO_ROOT/drivers" -type f \
         \( -name 'distro-*' -o -name 'refract-*' \) \
         ! -name '*.pyc' ! -name '*.desktop' ! -name '*.service' ! -name '*.timer' \
         ! -path '*/__pycache__/*' 2>/dev/null
)
if [ "$matched" -ge "${#apps[@]}" ]; then
    pass "the glob matches all $matched command files and no .desktop/.service/.pyc"
else
    fail "the glob matches every command file" "matched $matched of ${#apps[@]}"
fi

# --- autostart must reach EXISTING users, not just new ones -----------------
# /etc/skel is copied when an account is created. An entry added there after a
# machine is installed reaches nobody who already uses it.
if printf '%s\n' "$build_src" | grep -q 'skel/.config/autostart/refract-'; then
    fail "autostart entries go to /etc/xdg/autostart, not /etc/skel" \
         "a skel entry never reaches the person already using the machine"
else
    pass "autostart entries go to /etc/xdg/autostart, not /etc/skel"
fi
assert_contains "build.sh installs autostart system-wide" \
    "$build_src" 'etc/xdg/autostart'
assert_contains "apply installs autostart system-wide too" \
    "$update_src" '/etc/xdg/autostart'

# Every firstlogin entry must be installed by both paths.
while IFS= read -r f; do
    n="$(basename "$f")"
    case "$build_src" in *"$n"*) pass "build.sh ships $n" ;;
                         *) fail "build.sh ships $n" ;; esac
done < <(find "$REPO_ROOT/modes" -path '*/firstlogin/*.desktop' 2>/dev/null | sort)

# --- shared destinations must not drift -------------------------------------
for dir in /usr/share/applications /usr/lib/systemd/system /usr/lib/udev/rules.d /usr/share/refract; do
    if printf '%s\n' "$build_src" | grep -qF "$dir" && printf '%s\n' "$update_src" | grep -qF "$dir"; then
        pass "both paths agree on $dir"
    else
        fail "both paths agree on $dir" \
             "build.sh:$(printf '%s\n' "$build_src" | grep -cF "$dir") apply:$(printf '%s\n' "$update_src" | grep -cF "$dir")"
    fi
done

finish

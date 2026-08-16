#!/usr/bin/env bash
#
# Builds the ISO via debian-live's `lb` (live-build) tool.
#
# MUST run on a real Debian/Ubuntu Linux machine with live-build installed
# (`sudo apt-get install live-build`) — it uses debootstrap, chroot, and
# bind-mounts that don't exist on macOS, so there is no way to even
# syntax-check this beyond the contents of the scripts it copies in (those
# have already been checked separately with shellcheck). This script has
# NOT been run yet — see README.md status section.
#
# Usage: ./build.sh [strain]   (run from this directory: refract-os/iso/)
#   strain is one of: workstation (default) | laptop | lowspec | server |
#   handheld | cloud — see iso/strains/*.list.chroot and iso/strains/README.md.

set -euo pipefail

STRAIN="${1:-workstation}"
VALID_STRAINS=(workstation laptop lowspec server handheld cloud)

# REFRACT_TESTING=1 builds a DANGEROUS developer-only image: it auto-logs in
# with NO PASSWORD and strips the boot splash, so a tester lands on a desktop
# without touching anything. That means ANYONE who boots it gets a root-capable
# session with no authentication whatsoever. It is never built by default, is
# published only under a scarily-named release, and must never be handed to a
# user as "Refract OS". See iso/TESTING-BUILD.md.
REFRACT_TESTING="${REFRACT_TESTING:-0}"
if [ "$REFRACT_TESTING" = "1" ]; then
    cat >&2 <<'WARN'
###############################################################################
#  ####   ####  ##  ##  ####  ####  ####       #####  ##   ## ##  ##      ##  #
#  DANGER DANGER DANGER DANGER DANGER DANGER DANGER DANGER DANGER DANGER     #
###############################################################################
#  Building a TESTING image: NO LOGIN, NO PASSWORD, NO SPLASH.               #
#  Anyone who boots this gets an unauthenticated, sudo-capable desktop.      #
#  DO NOT DISTRIBUTE. DO NOT INSTALL. DEVELOPER TESTING ONLY.                #
###############################################################################
WARN
fi

# REFRACT_OMIT_MODES: space- or comma-separated list of OPTIONAL modes to leave
# out of this build ENTIRELY (gaming/ai/server/creative). Mirrors the
# REFRACT_TESTING flag above: a workflow_dispatch input forwarded via
# `sudo -E ./build.sh`, "always remove, then conditionally keep". Unlike the
# SOFT runtime hide (/etc/refract/enabled-modes), an omitted mode is PROVABLY
# ABSENT from the installed system — its modes/<mode>/ tree, switcher profile,
# PATH symlinks, wallpaper, mode-exclusive strain packages and installer slide
# are all stripped here, so nothing that could ever install it ships in the ISO
# (design doc §4). 'normal' is the always-on base desktop and can NEVER be
# omitted; anything outside gaming|ai|server|creative is rejected.
REFRACT_OMIT_MODES="${REFRACT_OMIT_MODES:-}"
REFRACT_OMIT_MODES="${REFRACT_OMIT_MODES//,/ }"
read -ra _omit_req <<< "$REFRACT_OMIT_MODES"
OMITTED=()
for _m in "${_omit_req[@]}"; do
    case "$_m" in
        normal)
            echo "REFRACT_OMIT_MODES: 'normal' is the always-on base desktop and cannot be omitted." >&2
            exit 1 ;;
        gaming|ai|server|creative) ;;
        *)
            echo "REFRACT_OMIT_MODES: unknown mode '$_m' (valid: gaming ai server creative)." >&2
            exit 1 ;;
    esac
    [[ " ${OMITTED[*]} " == *" $_m "* ]] || OMITTED+=("$_m")
done
if [ "${#OMITTED[@]}" -gt 0 ]; then
    echo -e "\033[33mOmitting modes entirely from this build (provably absent): ${OMITTED[*]}\033[0m"
fi

if [ "$(uname)" != "Linux" ]; then
    echo "live-build only runs on Linux. Run this on the actual Ubuntu build host, not here." >&2
    exit 1
fi

if ! command -v lb >/dev/null 2>&1; then
    echo "live-build not installed. Run: sudo apt-get install live-build" >&2
    exit 1
fi

if [[ ! " ${VALID_STRAINS[*]} " == *" $STRAIN "* ]]; then
    echo "Unknown strain '$STRAIN'. Valid: ${VALID_STRAINS[*]}" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Anchor the CWD to iso/. Staging paths below are script-relative, but `lb config`,
# the `>> config/binary` append, `lb build` and the output scan are all
# CWD-relative — and nothing enforced where this runs. Invoked from the repo root
# it did NOT fail loudly: lb config would happily create a default tree there, lb
# build would produce binary.hybrid.iso, and the rename would ship it as
# refract-os-<strain>.iso — a stock Ubuntu live image wearing the Refract name,
# with none of the strain packages, hooks or includes. Only a prose warning in the
# header guarded that.
cd "$(dirname "${BASH_SOURCE[0]}")"
INCLUDES="config/includes.chroot"
PACKAGE_LISTS="config/package-lists"
STRAIN_FILE="$REPO_ROOT/iso/strains/${STRAIN}.list.chroot"

echo -e "\033[36mStrain: $STRAIN\033[0m"
[ -f "$STRAIN_FILE" ] || { echo "Strain manifest not found: $STRAIN_FILE" >&2; exit 1; }

# Repeat builds in ONE checkout. The non-GNOME/headless branch below deletes
# GIT-TRACKED files out of config/package-lists and config/hooks, and nothing
# puts them back — so `./build.sh lowspec && ./build.sh workstation` in the same
# tree silently ships the second image with NO polish/macos-look layer and no
# build-time error at all. CI never sees it (fresh checkout every run);
# docs/first-hardware-runbook.md §6 chains strains in one tree and does. Restore
# whatever a previous run stripped before we touch anything.
#
# The surgery has to happen in the tree itself: `lb build` only ever reads
# ./config relative to the CWD, and build-iso.yml asserts the omitted-mode
# guarantee against iso/config/includes.chroot BY PATH — building from a staged
# copy elsewhere would make that assertion pass vacuously, which is worse than
# the bug. So: restore, don't relocate.
#
# ONLY files git reports as DELETED are restored, never modified ones. A blanket
# `git checkout -- iso/config/hooks` would also revert work-in-progress edits to
# a hook, i.e. silently un-fix an uncommitted fix on someone's box.
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _gone=()
    while IFS= read -r -d '' _f; do _gone+=("$_f"); done < <(
        git -C "$REPO_ROOT" ls-files -z --deleted -- iso/config/package-lists iso/config/hooks)
    if [ "${#_gone[@]}" -gt 0 ]; then
        echo -e "\033[33mRestoring config sources a previous build removed: ${_gone[*]}\033[0m"
        git -C "$REPO_ROOT" checkout -- "${_gone[@]}"
    fi
else
    echo -e "\033[33mNot a git checkout — cannot restore config sources a previous build may have stripped. If a strain builds without its polish/macos-look layer, re-export the tree.\033[0m" >&2
fi

# Only base.list.chroot (universal CLI tools) plus the ONE selected strain's
# packages go into config/package-lists/ — that directory is what live-build
# actually reads, so any other strain's packages must NOT be present here at
# build time, or every strain would get every strain's packages.
find "$PACKAGE_LISTS" -maxdepth 1 -name "strain-*.list.chroot" -delete
cp "$STRAIN_FILE" "$PACKAGE_LISTS/strain-${STRAIN}.list.chroot"

# Mode-exclusive strain packages (REFRACT_OMIT_MODES). Lines that belong to
# exactly ONE optional mode are tagged with a trailing '#@omit-if-no:<mode>'
# sentinel in iso/strains/*.list.chroot (dual-use packages like the Vulkan
# userspace shared by ai/gaming/creative — design §4.1-J — are deliberately
# NOT tagged and always survive). For each omitted mode, delete its tagged
# lines from the build copy; then strip the sentinel comment off every
# surviving line so the bare package name reaches live-build/apt clean and the
# sentinel is a pure build-time annotation that never ships. Operates on the
# copy under config/package-lists/, never the repo source in iso/strains/.
_strain_copy="$PACKAGE_LISTS/strain-${STRAIN}.list.chroot"
for m in "${OMITTED[@]}"; do
    sed -i "/#@omit-if-no:$m\b/d" "$_strain_copy"
done
sed -i 's/[[:space:]]*#@omit-if-no:[a-zA-Z]\{1,\}[[:space:]]*$//' "$_strain_copy"

# Calamares only makes sense for strains that ship a DE -- server/cloud are
# headless and would use cloud-init/preseed instead of an interactive
# installer GUI, not Calamares at all.
HEADLESS_STRAINS=(server cloud)
rm -f "$PACKAGE_LISTS/calamares.list.chroot"
rm -rf "$INCLUDES/etc/calamares"
rm -f "$INCLUDES/usr/share/applications/install-refract-os.desktop"
rm -rf "$INCLUDES/usr/share/initramfs-tools/scripts/casper-bottom"
# Unconditionally purge the installer polkit rule from the persistent (gitignored)
# includes tree. It is now written live-only by the casper-bottom hook, never into
# the squashfs; this guarantees a stale copy from an OLD build (which did bake it
# in) can never survive into any image, including a headless server/cloud ISO.
rm -f "$INCLUDES/etc/polkit-1/rules.d/49-refract-installer.rules"

# The macOS look (WhiteSur theme + dock + liquid-glass) is a DESKTOP feature.
# Strip its package list + build hook from headless strains so server/cloud
# images don't drag in GNOME theme tooling (sassc, gnome-shell-extensions, ...)
# or spend build time compiling WhiteSur for an image with no desktop.
HOOKS_DIR="$(dirname "${BASH_SOURCE[0]}")/config/hooks"
# The macOS look + polish layers are GNOME-specific (WhiteSur GTK, blur-my-shell,
# gnome-sushi, org.gnome.* dconf). Strip them from every NON-GNOME strain: the
# headless ones AND lowspec (which is LXQt/lubuntu-desktop, not GNOME).
NON_GNOME_STRAINS=(server cloud lowspec)
if [[ " ${NON_GNOME_STRAINS[*]} " == *" $STRAIN "* ]]; then
    # These are GIT-TRACKED sources. The restore block near the top heals them,
    # but only on the NEXT run — which leaves the tree sitting with 5 tracked
    # files deleted once this build finishes. A `git add -A && commit` in that
    # window (or an agent/editor doing it for you) removes them from the repo for
    # real. Restore on EXIT instead, so the deletion never outlives this process
    # even if the build fails or is interrupted.
    _stripped=("$PACKAGE_LISTS/macos-look.list.chroot" "$HOOKS_DIR/0300-macos-look.chroot" \
               "$PACKAGE_LISTS/polish.list.chroot" "$HOOKS_DIR/0400-polish.chroot" "$HOOKS_DIR/0410-keyd.chroot")
    if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # shellcheck disable=SC2317  # invoked via trap, not called directly
        _restore_stripped() {
            local _d=()
            while IFS= read -r -d '' _f; do _d+=("$_f"); done < <(
                git -C "$REPO_ROOT" ls-files -z --deleted -- iso/config/package-lists iso/config/hooks)
            [ "${#_d[@]}" -gt 0 ] && git -C "$REPO_ROOT" checkout -- "${_d[@]}" 2>/dev/null || true
        }
        trap _restore_stripped EXIT
    fi
    rm -f "${_stripped[@]}"
fi
if [[ ! " ${HEADLESS_STRAINS[*]} " == *" $STRAIN "* ]]; then
    echo -e "\033[36mWiring in Calamares (installer config, untested -- see iso/calamares/README.md)...\033[0m"
    echo "calamares" > "$PACKAGE_LISTS/calamares.list.chroot"
    mkdir -p "$INCLUDES/etc/calamares"
    rsync -a --delete "$REPO_ROOT/iso/calamares/" "$INCLUDES/etc/calamares/" --exclude README.md
    mkdir -p "$INCLUDES/usr/share/applications"
    cat > "$INCLUDES/usr/share/applications/install-refract-os.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Install Refract OS
Exec=pkexec calamares
Icon=system-software-install
Terminal=false
Categories=System;
EOF
    # The installer needs a passwordless polkit grant (the launcher is
    # `pkexec calamares`, and the live user has no password). That grant is NOT
    # written here anymore: baking it into config/includes.chroot put it in the
    # squashfs, so it ALSO shipped onto every INSTALLED system, where any local
    # desktop user could `pkexec bash` into a passwordless root shell (the
    # "subject.local && active" scope matches the installed user, and nothing
    # removed it). It is now written from the casper-bottom hook below into the
    # LIVE overlay only — an installed system never runs that hook, so it cannot
    # persist. Defensively purge any stale copy a PRIOR build left in the
    # (gitignored, persistent) includes tree so no build ever ships it.
    rm -f "$INCLUDES/etc/polkit-1/rules.d/49-refract-installer.rules"
    # Live-session autostart: a casper-bottom hook (see
    # iso/casper-hooks/casper-bottom/README.md) drops the desktop entry above
    # onto the live user's Desktop during boot -- the same documented
    # mechanism real live-build+Calamares distros use (verified against
    # maui-linux/calamares-casper's casper-bottom script). config/hooks/live/
    # forces an update-initramfs run so this plain dropped-in file (not a
    # .deb, so no dpkg trigger) actually gets embedded into the live initrd.
    mkdir -p "$INCLUDES/usr/share/initramfs-tools/scripts/casper-bottom"
    cp "$REPO_ROOT/iso/casper-hooks/casper-bottom/25-refract-install-icon" \
        "$INCLUDES/usr/share/initramfs-tools/scripts/casper-bottom/"
    chmod +x "$INCLUDES/usr/share/initramfs-tools/scripts/casper-bottom/25-refract-install-icon"
fi

# Strip every trace of an omitted mode from the staged Calamares tree, so a
# no-<mode> image never advertises — or offers to install — a mode it does not
# have (design §4.1-K). Three surfaces, each range-deleted from the $INCLUDES
# copy by its own marker comments:
#   1. show.qml's per-mode Slide      ('// @slide:<mode>' .. '// @endslide:<mode>')
#   2. the "what is this machine for?" checkbox in packagechooser_modes.conf
#      ('# @item:<mode>' .. '# @enditem:<mode>'). Without this a "provably
#      AI-free" ISO still renders an AI checkbox that writes 'ai' into the
#      registry, which load_valid_modes() then silently drops — a dead control
#      that contradicts the whole guarantee.
#   3. that item's screenshot (~245KB each), otherwise dead weight in the
#      squashfs pointed at by an item that no longer exists.
# Guarded by [ -d ] because the headless strains (server/cloud) ship no Calamares
# tree at all (it is rm -rf'd above and only re-created for non-headless). The
# intro slide is deliberately mode-agnostic (no per-mode enumeration), so nothing
# there needs stripping.
_cala="$INCLUDES/etc/calamares"
if [ -d "$_cala" ]; then
    for m in "${OMITTED[@]}"; do
        sed -i "/\/\/ @slide:$m$/,/\/\/ @endslide:$m$/d" \
            "$_cala/branding/refractos/show.qml"
        sed -i "/# @item:$m$/,/# @enditem:$m$/d" \
            "$_cala/modules/netinstall_modes.conf"
        rm -f "$_cala/branding/refractos/$m.png"
    done
    # The old "every optional mode omitted -> drop the empty page" special case is
    # gone with packagechooser. netinstall_modes.conf always keeps its Normal
    # group (it carries no @item sentinels, so no omission can strip it), so the
    # page always has at least one checkbox and is never a dead step. Verified by
    # simulating all four range-deletes: omitting everything leaves ["Normal"].
fi

echo -e "\033[36mCopying repo scripts into the image (opt/distro/, /usr/local/bin)...\033[0m"
# Copied fresh from the repo at build time rather than committed as a
# duplicate in git — there is exactly one copy of these scripts to keep in
# sync, the one under modes/ and drivers/ at the repo root.
# usr/local/bin is rebuilt from scratch every run. Nothing else stages anything
# into it, and the rsync --delete below does NOT cover it (that only cleans
# inside opt/distro/{modes,drivers}) — so without this wipe the distro-ai-*
# symlinks written by a PRIOR build in the same tree survive an omitted build as
# dangling links: distro-ai-ask still on $PATH in a "provably AI-free" ISO.
rm -rf "$INCLUDES/usr/local/bin"
mkdir -p "$INCLUDES/opt/distro" "$INCLUDES/usr/local/bin"
rsync -a --delete "$REPO_ROOT/modes" "$REPO_ROOT/drivers" "$INCLUDES/opt/distro/"

# --- HARD mode omission (REFRACT_OMIT_MODES) --------------------------------
# Physically remove each omitted mode's footprint from the staged image so the
# installed system has PROVABLY nothing of it (design §4). systemd units and the
# legacy-crucible12 sub-tree live under modes/<mode>/, so the rm -rf covers them;
# the wallpaper is dropped later (after the wallpaper cp) and the PATH symlinks
# are skipped in the loop below. All edits target the copy under $INCLUDES —
# never the repo source under modes/.
for m in "${OMITTED[@]}"; do
    rm -rf "$INCLUDES/opt/distro/modes/$m"
    # The switcher profile is NOT under modes/<mode>/ (it is modes/modectl/
    # profiles/<mode>.conf), so it needs a separate delete or `switch <mode>`
    # would still resolve a profile for a mode whose files are gone.
    rm -f "$INCLUDES/opt/distro/modes/modectl/profiles/$m.conf"
done
if [ "${#OMITTED[@]}" -gt 0 ]; then
    # Hard-disable the switcher: drop the omitted modes from the shipped
    # distro-modectl's ALL_MODES=(...) catalog (the switcher now derives
    # VALID_MODES from ALL_MODES + /etc/refract/enabled-modes). Rewrite keeps
    # the canonical mode order and always retains 'normal'. sed the COPY only.
    kept=(); apply_kept=()
    for cm in gaming ai server creative normal; do
        [[ " ${OMITTED[*]} " == *" $cm "* ]] && continue
        kept+=("$cm")
        # distro-apply-mode-selection's OPTIONAL_MODES lists only the modes the
        # installer page can offer, so 'normal' is deliberately absent from it.
        [ "$cm" = normal ] || apply_kept+=("$cm")
    done
    sed -i "s/^ALL_MODES=(.*/ALL_MODES=(${kept[*]})/" \
        "$INCLUDES/opt/distro/modes/modectl/distro-modectl"
    # Same treatment for the installer helper's own catalog. OPTIONAL_MODES is
    # both the whitelist it filters the Calamares selection through and the list
    # APPLY_HARD_REMOVAL iterates — leave an omitted mode in it and a selection
    # naming that mode gets written straight into the fresh install's registry.
    sed -i "s/^OPTIONAL_MODES=(.*/OPTIONAL_MODES=(${apply_kept[*]})/" \
        "$INCLUDES/opt/distro/modes/modectl/distro-apply-mode-selection"
fi
# Ship a default, world-readable /etc/refract/enabled-modes for the live (and
# freshly-installed) session listing the optional modes this build actually
# ships — omitted modes are absent from it, so the switcher never advertises a
# mode whose files were stripped. 'normal' is always-on and never listed (the
# loader force-appends it). Written here because config/includes.chroot/etc/ is
# gitignored: build.sh is the only place that knows the omit set.
mkdir -p "$INCLUDES/etc/refract"
{
    echo "# Refract OS — enabled optional modes (one per line; '#' comments ok)."
    echo "# 'normal' is the always-on base desktop and is never listed here."
    echo "# Managed at runtime via: distro-modectl modes enable|disable <mode>"
    for cm in gaming ai server creative; do
        [[ " ${OMITTED[*]} " == *" $cm "* ]] || echo "$cm"
    done
} > "$INCLUDES/etc/refract/enabled-modes"
chmod 0644 "$INCLUDES/etc/refract/enabled-modes"

# Symlinks, not copies: distro-modectl looks up profiles/ relative to its
# own location (see modes/modectl/distro-modectl's PROFILE_DIR), so it must
# stay next to that directory rather than be flattened into /usr/local/bin.
ln -sf /opt/distro/modes/modectl/distro-modectl "$INCLUDES/usr/local/bin/distro-modectl"
# distro-layoutctl — desktop LAYOUT (how it looks), orthogonal to modes (what the
# machine is tuned FOR). Same staging shape: real file under /opt/distro, symlink
# into PATH.
ln -sf /opt/distro/modes/layouts/distro-layoutctl "$INCLUDES/usr/local/bin/distro-layoutctl"

# --- Refract's own updater --------------------------------------------------
# Without this an installed machine can never receive a fix: /opt/distro, the
# distro-* commands and the GNOME extension all arrive from the ISO, and there is
# no apt repo behind them. distro-update refreshes exactly that layer; apt keeps
# owning Ubuntu packages and security patches, and the two never touch.
ln -sf /opt/distro/modes/update/distro-update        "$INCLUDES/usr/local/bin/distro-update"
ln -sf /opt/distro/modes/update/refract-updates      "$INCLUDES/usr/local/bin/refract-updates"
ln -sf /opt/distro/modes/update/refract-update-check "$INCLUDES/usr/local/bin/refract-update-check"
# distro-appstore lives here rather than under a mode because it is the other
# half of the same question — "how does software get onto this machine". apt and
# Flathub deliver applications, distro-update delivers Refract itself, and this
# is the command that tells you which of those is broken when the store won't
# open. It must be reachable on EVERY strain, including one whose dock the old
# apply_pinned_apps emptied, so it is a PATH entry and not a dock icon.
ln -sf /opt/distro/modes/update/distro-appstore      "$INCLUDES/usr/local/bin/distro-appstore"
# distro-appgrid — one app-grid entry per job. Refract ships its own monitor and
# updater, and ubuntu-desktop-minimal drags in gnome-system-monitor and
# update-manager transitively, so both pairs ended up in the grid with nothing in
# any package list to show for it. This hides the stock half (reversibly, and
# without uninstalling anything) and hooks/0480-appgrid.chroot runs it at build
# time so a fresh install is already deduplicated.
ln -sf /opt/distro/modes/appgrid/distro-appgrid      "$INCLUDES/usr/local/bin/distro-appgrid"
# distro-powerctl — Normal mode follows the wall socket (power-saver on battery,
# balanced on mains). Every other mode is an explicit request for performance and
# is deliberately left alone; see the script's header.
ln -sf /opt/distro/modes/power/distro-powerctl       "$INCLUDES/usr/local/bin/distro-powerctl"
# distro-fingerprint — why Settings isn't offering fingerprint login. fprintd and
# libpam-fprintd ship on the laptop strain, but "the fingerprint thing is not
# there" has four different causes that all look identical in Settings, and only
# two of them are fixable. This tells them apart by reading the USB bus.
ln -sf /opt/distro/drivers/distro-fingerprint         "$INCLUDES/usr/local/bin/distro-fingerprint"

# --- the update signing key -------------------------------------------------
# The public half of the Ed25519 pair that signs every update. distro-update
# verifies against THIS LOCAL COPY and never against anything it downloads —
# a key fetched over the same channel as the payload proves nothing, since
# whoever can replace one can replace the other. See docs/signing.md.
#
# Absent until the key is generated; the build does not fail over it, and
# distro-update falls back to the announced unsigned path. Do not "fix" that by
# fetching the key at runtime.
mkdir -p "$INCLUDES/usr/share/refract"
# The update history, readable on the machine rather than only in the terminal
# of whoever ran the last update. Refract Tips renders it as its "What's new"
# page; distro-update refreshes this same path on every apply.
[ -f "$REPO_ROOT/WHATS-NEW.md" ] && install -m 0644 "$REPO_ROOT/WHATS-NEW.md" \
    "$INCLUDES/usr/share/refract/WHATS-NEW.md"
if [ -f "$REPO_ROOT/iso/keys/refract-signing.pub" ]; then
    install -m 0644 "$REPO_ROOT/iso/keys/refract-signing.pub" \
        "$INCLUDES/usr/share/refract/refract-signing.pub"
    echo "Staged the update signing key -> /usr/share/refract/refract-signing.pub"
else
    echo "NOTE: no iso/keys/refract-signing.pub — this image will take UNSIGNED updates." >&2
    echo "NOTE:   generate one with docs/signing.md before shipping to anyone else." >&2
fi

# --- system units and udev rules, by convention -----------------------------
# modes/<m>/systemd/system/* and modes/<m>/udev/*.rules. Same convention
# distro-update apply uses, so an updated machine and a fresh install converge:
# if these two ever disagree about where things go, a machine that took an update
# ends up with two copies of a unit and no error anywhere.
#
# Only refract-* units with an [Install] section are ENABLED. Copying a unit is
# inert; enabling one runs code at boot, and that is not something to do to
# whatever happens to be in the tree.
mkdir -p "$INCLUDES/usr/lib/systemd/system/multi-user.target.wants" "$INCLUDES/usr/lib/udev/rules.d"
for unit in "$REPO_ROOT"/modes/*/systemd/system/*; do
    [ -f "$unit" ] || continue
    uname="$(basename "$unit")"
    install -m 0644 "$unit" "$INCLUDES/usr/lib/systemd/system/$uname"
    case "$uname" in
        refract-*)
            grep -q '^\[Install\]' "$unit" || continue
            # Symlink by hand rather than shelling out to `systemctl enable
            # --root`: the includes tree is not a system, and enable would need
            # a full unit search path to resolve against.
            grep -q '^WantedBy=multi-user.target' "$unit" \
                && ln -sf "../$uname" "$INCLUDES/usr/lib/systemd/system/multi-user.target.wants/$uname"
            ;;
    esac
done
for rule in "$REPO_ROOT"/modes/*/udev/*.rules; do
    [ -f "$rule" ] || continue
    install -m 0644 "$rule" "$INCLUDES/usr/lib/udev/rules.d/$(basename "$rule")"
done

# --- Refract Monitor --------------------------------------------------------
# CPU / GPU / Memory / Energy, one page each. Its sampler package sits beside it
# under modes/monitor/, which the rsync above already staged, so only the PATH
# entry and the app-grid launcher are needed here.
ln -sf /opt/distro/modes/monitor/refract-monitor "$INCLUDES/usr/local/bin/refract-monitor"
# mkdir FIRST. This cp used to rely on the directory already existing, which is
# true only on strains that stage the installer launcher — so the server build
# died with "cannot create regular file ... No such file or directory" while
# workstation and handheld passed. A headless strain has no installer icon and
# therefore no usr/share/applications until something makes one.
# EVERY modes/<m>/*.desktop, by the same glob distro-update apply uses. These
# used to be two hand-written cp lines, so adding a third app (Refract Tips)
# meant remembering to edit this file — and forgetting would ship an app with no
# way to launch it, which is not an error anything would catch. It also keeps
# build.sh and distro-update converging on the same set: if they disagree, a
# machine that took an update ends up with launchers a fresh install lacks.
#
# mkdir FIRST. This used to rely on the directory already existing, which is
# true only on strains that stage the installer launcher — so the server build
# died with "cannot create regular file ... No such file or directory" while
# workstation and handheld passed. A headless strain has no installer icon and
# therefore no usr/share/applications until something makes one.
mkdir -p "$INCLUDES/usr/share/applications"
for dtop in "$REPO_ROOT"/modes/*/*.desktop; do
    [ -f "$dtop" ] || continue
    install -m 0644 "$dtop" "$INCLUDES/usr/share/applications/$(basename "$dtop")"
done

# Daily check as a USER timer, not a system one: checking needs no privilege, and
# a root timer that pushes notifications into someone's session is a worse design
# than a user timer that cannot change the system at all. Enabled by symlink
# because `systemctl --user enable` cannot run against an image being built.
mkdir -p "$INCLUDES/usr/lib/systemd/user/timers.target.wants"
cp "$REPO_ROOT/modes/update/refract-update-check.service" \
   "$REPO_ROOT/modes/update/refract-update-check.timer" \
   "$INCLUDES/usr/lib/systemd/user/"
ln -sf ../refract-update-check.timer \
   "$INCLUDES/usr/lib/systemd/user/timers.target.wants/refract-update-check.timer"
# First-login applier. shellprocess@layout can only WRITE /etc/refract/layout —
# at install time the target has no user session and therefore no dconf to apply
# the appearance into. This autostart entry applies it once, when a session
# first exists, and stamps itself so it never overrides a later manual switch.
mkdir -p "$INCLUDES/usr/local/lib/refract" "$INCLUDES/etc/skel/.config/autostart"
install -m 0755 "$REPO_ROOT/modes/layouts/firstlogin/apply-layout-once" \
    "$INCLUDES/usr/local/lib/refract/apply-layout-once"
install -m 0644 "$REPO_ROOT/modes/layouts/firstlogin/refract-layout.desktop" \
    "$INCLUDES/etc/skel/.config/autostart/refract-layout.desktop"
# Refract Tips, shown once on the first graphical login. gnome-initial-setup is
# purged and masked by hooks/0200-refract-identity.chroot, so there is no
# first-run wizard on this image at all — without this, a new owner gets a
# desktop with nothing to indicate that modes, layouts, the top-bar switcher or
# any of the distro-* tools exist. --first-run makes it a no-op after the first.
install -m 0644 "$REPO_ROOT/modes/tips/firstlogin/refract-tips.desktop" \
    "$INCLUDES/etc/skel/.config/autostart/refract-tips.desktop"
ln -sf /opt/distro/modes/tips/refract-tips "$INCLUDES/usr/local/bin/refract-tips"
# Ship the default so a LIVE session (never installed, so no shellprocess ran)
# still has a layout to apply rather than falling back by accident.
mkdir -p "$INCLUDES/etc/refract"
echo refract > "$INCLUDES/etc/refract/layout"
# Symlink every user-facing distro-* CLI into PATH. These resolve their own
# real dir through the symlink (readlink) so relative config/profiles/compat-db
# lookups work. Paths are the /opt/distro layout the rsync above produces.
declare -A DISTRO_BINS=(
    [distro-ai-model]=modes/ai/bin        [distro-ai-image]=modes/ai/bin
    [distro-ai-ask]=modes/ai/bin          [distro-ai-overlay]=modes/ai/bin
    [distro-ai-cloud-toggle]=modes/ai/bin [distro-ai-bind-hotkey]=modes/ai/bin
    [distro-ai-detect-tier]=modes/ai/bin  [distro-ai-setup]=modes/ai/bin
    [distro-gaming-compat]=modes/gaming/bin
    [distro-creative-scratch]=modes/creative/bin [distro-creative-color]=modes/creative/bin
)
for bin in "${!DISTRO_BINS[@]}"; do
    # DISTRO_BINS[$bin] is 'modes/<mode>/bin' — extract <mode> and skip the
    # symlink when that mode was omitted, so we never leave a dangling link to
    # a bin the rm -rf above just deleted.
    binmode="${DISTRO_BINS[$bin]#modes/}"; binmode="${binmode%%/*}"
    [[ " ${OMITTED[*]} " == *" $binmode "* ]] && continue
    ln -sf "/opt/distro/${DISTRO_BINS[$bin]}/$bin" "$INCLUDES/usr/local/bin/$bin"
done
# The handheld strain's ONLY real differentiation. iso/strains/README.md and
# handheld.list.chroot both tell the user that handheld differs from workstation
# "at the session level, see handheld/setup-handheld-ui.sh" — but nothing ever
# copied iso/strains/handheld/ into the image, so that script existed only in the
# git checkout. On the installed system the documented command simply was not
# there, and handheld was byte-for-byte workstation. Stage it, and put it on PATH
# under the distro-* name every other user-facing CLI here uses, so the
# instruction in the docs is one word the user can actually type.
if [ "$STRAIN" = handheld ] && [ -f "$REPO_ROOT/iso/strains/handheld/setup-handheld-ui.sh" ]; then
    mkdir -p "$INCLUDES/opt/distro/strains/handheld"
    cp "$REPO_ROOT/iso/strains/handheld/setup-handheld-ui.sh" \
       "$INCLUDES/opt/distro/strains/handheld/setup-handheld-ui.sh"
    ln -sf /opt/distro/strains/handheld/setup-handheld-ui.sh \
       "$INCLUDES/usr/local/bin/distro-handheld-ui"
    echo "Staged handheld UI setup -> /opt/distro/strains/handheld + PATH as distro-handheld-ui."
fi
find "$INCLUDES/opt/distro" -type f \( -name "*.sh" -o -name "distro-*" \) -exec chmod +x {} +

# ---------------------------------------------------------------------------
# OS IDENTITY — make it boot AS Refract OS, not stock Ubuntu. Refract OS is
# Ubuntu-BASED (kernel + packages are Ubuntu's, ID_LIKE=ubuntu so apt/PPA logic
# keeps working) but everything the user SEES is rebranded: os-release, boot
# splash, wallpaper, hostname, terminal fetch.
# ---------------------------------------------------------------------------
echo -e "\033[36mBaking in Refract OS identity...\033[0m"
VERSION_NUM="1.0"; VERSION_CODENAME="forge"
# Per-strain VARIANT label (capitalize first letter).
VARIANT_LABEL="$(printf '%s' "$STRAIN" | sed 's/^./\U&/')"

# BUILD IDENTITY — what distro-update compares against to decide whether this
# machine is behind. Without a recorded commit there is no way for an installed
# system to know what it is running, and the only "update" available is a full
# reinstall. GITHUB_SHA is set in CI; a local build falls back to git, and to
# "unknown" outside a checkout (in which case distro-update simply always offers
# the latest rather than pretending to compare).
_build_sha="${GITHUB_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
mkdir -p "$INCLUDES/etc/refract"
cat > "$INCLUDES/etc/refract/build-id" <<BUILDID
REFRACT_COMMIT=${_build_sha}
REFRACT_STRAIN=${STRAIN}
REFRACT_BUILT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILDID
echo -e "\033[36mBuild identity: ${_build_sha} (${STRAIN})\033[0m"

mkdir -p "$INCLUDES/etc" "$INCLUDES/usr/lib"
_osrelease() {
cat <<EOF
NAME="Refract OS"
PRETTY_NAME="Refract OS ${VERSION_NUM} (${VARIANT_LABEL})"
ID=refract
ID_LIKE="ubuntu debian"
VERSION="${VERSION_NUM} (${VERSION_CODENAME^})"
VERSION_ID="${VERSION_NUM}"
VERSION_CODENAME=${VERSION_CODENAME}
UBUNTU_CODENAME=noble
HOME_URL="https://mr-pythoneer.github.io/refract-os/"
SUPPORT_URL="https://github.com/Mr-Pythoneer/refract-os"
BUG_REPORT_URL="https://github.com/Mr-Pythoneer/refract-os/issues"
VARIANT="${VARIANT_LABEL}"
VARIANT_ID=${STRAIN}
EOF
}
_osrelease > "$INCLUDES/etc/os-release"           # overrides base-files' symlink
_osrelease > "$INCLUDES/usr/lib/os-release"
cat > "$INCLUDES/etc/lsb-release" <<EOF
DISTRIB_ID=Refract
DISTRIB_RELEASE=${VERSION_NUM}
DISTRIB_CODENAME=${VERSION_CODENAME}
DISTRIB_DESCRIPTION="Refract OS ${VERSION_NUM}"
EOF
printf 'Refract OS %s (%s) \\n \\l\n\n' "$VERSION_NUM" "$VARIANT_LABEL" > "$INCLUDES/etc/issue"
printf 'Refract OS %s\n' "$VERSION_NUM" > "$INCLUDES/etc/issue.net"
# Default hostname + matching hosts entry.
echo "refract" > "$INCLUDES/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\trefract\n' > "$INCLUDES/etc/hosts"
# NOTE: the default /etc/refract/enabled-modes registry is staged earlier
# (right after the REFRACT_OMIT_MODES switcher rewrite) so it can list only the
# optional modes this build actually ships — see that block for the rationale.

# Wallpaper + logos into the image.
mkdir -p "$INCLUDES/usr/share/backgrounds/refract" "$INCLUDES/usr/share/refract"
# The full per-mode wallpaper set (base/gaming/ai/server/creative/normal) —
# distro-modectl swaps between them on `switch <mode>`.
cp "$REPO_ROOT"/branding/out/wallpapers/*.png "$INCLUDES/usr/share/backgrounds/refract/"
# Drop each omitted mode's wallpaper (the glob above copies the full set). Only
# per-mode files are removed; base.png/normal.png always survive ('normal' can
# never be omitted).
for m in "${OMITTED[@]}"; do
    rm -f "$INCLUDES/usr/share/backgrounds/refract/$m.png"
done
# GNOME default (login/base). A SYMLINK, not a second copy: base.png is ~1.3 MB
# and shipping it twice cost that again inside the squashfs. lowspec clears the
# publish threshold by only ~1 MiB (measured: ISO 2143289344 B vs the 2045 MiB
# limit in build-iso.yml), so a duplicated wallpaper is the difference between
# shipping a raw .iso and being demoted to the .iso.xz rung. Relative target so
# it resolves identically in the squashfs, the installed tree and the chroot.
ln -sf refract/base.png "$INCLUDES/usr/share/backgrounds/refract-os.png"
# LOGO-FREE BUILD (deliberate, requested): the OS ships NO Refract mark anywhere
# — no boot splash logo, no greeter logo, no distributor icon, no installer
# logo. Branding is the NAME "Refract OS" as text, nothing pictorial.
#
# What ships instead is a 1x1 fully transparent PNG. That is not laziness: the
# icon-theme names below (ubuntu-logo, start-here, distributor-logo) are shipped
# BY UBUNTU, so simply not overwriting them does not remove a logo — it restores
# Ubuntu's. A transparent file keeps the filename resolvable for anything that
# looks it up while rendering nothing, which is the only way to end up with
# neither mark. Same reasoning for Calamares' branding.desc image keys.
cp "$REPO_ROOT/branding/out/blank.png" "$INCLUDES/usr/share/refract/logo.png"
cp "$REPO_ROOT/branding/out/blank.png" "$INCLUDES/usr/share/refract/logo-small.png"
# A transparent SVG for the .svg icon slots (a PNG written into a .svg filename
# renders as a broken image, so the extension has to be honoured).
cat > "$INCLUDES/usr/share/refract/logo.svg" <<'BLANKSVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1" width="1" height="1"></svg>
BLANKSVG

# Bake Normal mode's accent into /etc/skel so a FRESH install already has it.
# distro-modectl's apply_accent() writes this stylesheet into the user's config
# on every `switch`, but nothing writes it before the FIRST switch — so a
# just-installed desktop (and every live session) rendered WhiteSur's stock blue
# while the profile, the wallpaper, the website's Normal card and the installer
# all say Normal is orange. The mode the machine actually boots in was the one
# mode whose accent never applied.
#
# Derived from the profile instead of hardcoded, so it cannot drift from
# apply_accent()'s source of truth. The marker line is load-bearing and must stay
# byte-identical to the one apply_accent() writes: that function refuses to
# overwrite any gtk.css whose first line lacks it ("user-authored — leaving it
# alone"), so a skel file with a different marker would PERMANENTLY pin every new
# user to orange and silently break switching to the other four modes.
_naccent=""; _nfg=""
# shellcheck disable=SC1090
if [ -r "$REPO_ROOT/modes/modectl/profiles/normal.conf" ]; then
    _naccent=$(sed -n "s/^ACCENT=[\"']\{0,1\}\([^\"']*\).*/\1/p"    "$REPO_ROOT/modes/modectl/profiles/normal.conf" | head -n1)
    _nfg=$(sed -n     "s/^ACCENT_FG=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$REPO_ROOT/modes/modectl/profiles/normal.conf" | head -n1)
fi
if [ -n "$_naccent" ]; then
    for _d in gtk-4.0 gtk-3.0; do
        mkdir -p "$INCLUDES/etc/skel/.config/$_d"
        cat > "$INCLUDES/etc/skel/.config/$_d/gtk.css" <<CSS
/* generated by distro-modectl — per-mode accent; edits are overwritten */
@define-color accent_color $_naccent;
@define-color accent_bg_color $_naccent;
@define-color accent_fg_color ${_nfg:-#1a1a1a};
@define-color theme_selected_bg_color $_naccent;
@define-color theme_selected_fg_color ${_nfg:-#1a1a1a};
CSS
    done
    echo "Baked Normal's accent ($_naccent) into /etc/skel for fresh installs."
else
    echo -e "\033[33mCould not read ACCENT from modes/modectl/profiles/normal.conf — fresh installs will show the stock theme accent until the first mode switch.\033[0m" >&2
fi

# Plymouth boot splash — theme only, no logo image (the script is text-only).
mkdir -p "$INCLUDES/usr/share/plymouth/themes/refract"
cp "$REPO_ROOT/iso/branding/plymouth/refract/refract.plymouth" "$INCLUDES/usr/share/plymouth/themes/refract/"
cp "$REPO_ROOT/iso/branding/plymouth/refract/refract.script"   "$INCLUDES/usr/share/plymouth/themes/refract/"

# GNOME default wallpaper + dark theme via a glib SCHEMA OVERRIDE — the reliable
# mechanism (99_ sorts after Ubuntu's own 10_ override, so ours wins); compiled
# by the 0200-refract-identity chroot hook. Harmless on non-GNOME strains.
mkdir -p "$INCLUDES/usr/share/glib-2.0/schemas"
cp "$REPO_ROOT/iso/branding/glib/99_refract.gschema.override" "$INCLUDES/usr/share/glib-2.0/schemas/99_refract.gschema.override"
# dconf db for favorites (belt-and-suspenders alongside the schema override).
# GNOME Shell extensions we ship ourselves. refract-modes puts a mode switcher in
# the top bar next to Wi-Fi/Bluetooth — modes are this distro's headline feature
# and until now the only way to change one was a terminal command, which is a
# developer's answer to a desktop user's question. Enabled via the dconf
# enabled-extensions list below. Harmless on non-GNOME strains: with no
# gnome-shell to load it, it is a few KB of dormant JavaScript.
if [ -d "$REPO_ROOT/iso/gnome-extensions" ]; then
    mkdir -p "$INCLUDES/usr/share/gnome-shell/extensions"
    rsync -a --delete "$REPO_ROOT/iso/gnome-extensions/" \
        "$INCLUDES/usr/share/gnome-shell/extensions/"
    echo -e "\033[36mStaged GNOME Shell extensions: $(ls -1 "$REPO_ROOT/iso/gnome-extensions" | tr '\n' ' ')\033[0m"
fi

mkdir -p "$INCLUDES/etc/dconf/db/local.d" "$INCLUDES/etc/dconf/profile"
cp "$REPO_ROOT/iso/branding/dconf/local.d/00-refract" "$INCLUDES/etc/dconf/db/local.d/00-refract"
# The polish layer (smoothness/input/fonts/window-buttons) is GNOME dconf — only
# for GNOME strains (skip headless + lowspec/LXQt), matching the package/hook strip.
if [[ ! " ${NON_GNOME_STRAINS[*]} " == *" $STRAIN "* ]]; then
    cp "$REPO_ROOT/iso/branding/dconf/local.d/10-refract-polish" "$INCLUDES/etc/dconf/db/local.d/10-refract-polish"
fi
cp "$REPO_ROOT/iso/branding/dconf/profile/user"        "$INCLUDES/etc/dconf/profile/user"
# GDM greeter branding (background + banner on the login screen; deliberately
# NO logo — see iso/branding/dconf/gdm.d/01-refract). The gdm dconf profile
# ships with gdm3; the hook compiles this db.
mkdir -p "$INCLUDES/etc/dconf/db/gdm.d"
cp "$REPO_ROOT/iso/branding/dconf/gdm.d/01-refract" "$INCLUDES/etc/dconf/db/gdm.d/01-refract"

# --- TESTING-ONLY: strip authentication + splash -----------------------------
# Only ever emitted when REFRACT_TESTING=1. Removing this hook restores normal
# behaviour, and a default build never writes it at all.
TESTING_HOOK="$(dirname "${BASH_SOURCE[0]}")/config/hooks/0900-DANGER-testing-nologin.chroot"
rm -f "$TESTING_HOOK"
if [ "$REFRACT_TESTING" = "1" ]; then
    cat > "$TESTING_HOOK" <<'TESTHOOK'
#!/bin/sh
# DANGER: TESTING IMAGE ONLY — auto-login with no password, no splash.
# Generated by build.sh only when REFRACT_TESTING=1. Never present in a
# normal build. If you are reading this inside a shipped Refract OS image,
# that image is a developer testing build and MUST NOT be used.
set -e

LIVE_USER=ubuntu

# GDM autologin. Ubuntu's gdm3 reads /etc/gdm3/custom.conf; Debian's reads
# daemon.conf. Rather than bet on which this fork produced, write BOTH — the
# unused one is inert, and this cannot silently no-op the way a single guess
# could.
for f in /etc/gdm3/custom.conf /etc/gdm3/daemon.conf; do
    install -d /etc/gdm3
    [ -f "$f" ] || printf '[daemon]\n' > "$f"
    grep -q '^\[daemon\]' "$f" || printf '[daemon]\n' >> "$f"
    for k in "AutomaticLoginEnable=true" "AutomaticLogin=$LIVE_USER"; do
        key="${k%%=*}"
        if grep -q "^${key}=" "$f"; then
            sed -i "s|^${key}=.*|${k}|" "$f"
        else
            sed -i "/^\[daemon\]/a ${k}" "$f"
        fi
    done
done

# Blank the live user's password so any stray auth prompt is just Enter.
passwd -d "$LIVE_USER" 2>/dev/null || true

# Kill the boot splash so the tester sees real kernel output, not a logo.
if [ -f /etc/default/grub ]; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="nosplash systemd.show_status=true"/' /etc/default/grub || true
fi

# Make it impossible to mistake this image for a real one.
cat > /etc/refract-TESTING-BUILD-DO-NOT-USE <<'EOF'
This is a Refract OS DEVELOPER TESTING build.
NO LOGIN. NO PASSWORD. NOT SECURE. NOT FOR INSTALLATION OR DISTRIBUTION.
EOF
sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="Refract OS *** DANGER: TESTING BUILD - NO LOGIN - DO NOT USE ***"/' /etc/os-release 2>/dev/null || true
printf '\n*** DANGER: TESTING BUILD. NO LOGIN. NO PASSWORD. DO NOT USE OR DISTRIBUTE. ***\n\n' > /etc/motd

echo "DANGER-testing: autologin enabled, splash stripped, image marked as TESTING."
TESTHOOK
    chmod 0755 "$TESTING_HOOK"
    echo -e "\033[31mDANGER: testing hook written — this image will have NO LOGIN.\033[0m"
fi

# The identity package list (plymouth-themes/fastfetch/dconf-cli) and the
# 0200-refract-identity chroot hook are committed source files under
# config/package-lists/ and config/hooks/live/ — nothing to generate here.

# Neutralize the old fork's mode-ubuntu gfxboot machinery. Two unconditional
# steps in lb_binary_syslinux assume the long-dead gfxboot-theme-ubuntu
# package (~Ubuntu 12.04):
#   1. `tar xfz /usr/share/gfxboot-theme-ubuntu/bootlogo.tar.gz` into the
#      bootloader dir (gated on mode, NOT theme), and
#   2. a "gfxboot hack" that does `cpio -i < binary/isolinux/bootlogo` and
#      repacks it — an fatal redirect error if bootlogo doesn't exist (this
#      killed run 28566217894 at lb_binary_syslinux line 365).
# So the stub tarball must CONTAIN a file named 'bootlogo' that is a valid
# (empty) cpio archive: the tar extraction places it, the hack round-trips it,
# and since our isolinux.cfg never loads gfxboot.c32 the file is inert on the
# ISO. Also satisfies Check_package so the dead package is never wanted.
mkdir -p "$INCLUDES/usr/share/gfxboot-theme-ubuntu"
_glogo="$(mktemp -d)"
: | cpio --quiet -o > "$_glogo/bootlogo"   # valid cpio archive with only TRAILER
tar -czf "$INCLUDES/usr/share/gfxboot-theme-ubuntu/bootlogo.tar.gz" -C "$_glogo" bootlogo
rm -rf "$_glogo"

# Hooks must be +x: binary hooks are exec'd by the fork's lb_binary_hooks, and
# chroot hooks likewise. Cover BOTH — relying on live-build's implicit chmod
# self-heal is fragile (a 0644 .chroot hook silently not running = its whole
# config, e.g. the WaylandEnable/Xorg fix, never applied). Belt this explicitly.
find "$(dirname "${BASH_SOURCE[0]}")/config/hooks" -maxdepth 1 -type f \
    \( -name "*.binary" -o -name "*.chroot" \) -exec chmod +x {} + 2>/dev/null || true

echo -e "\033[36mConfiguring live-build...\033[0m"
# Ubuntu's live-build fork (3.0~a57-based — what `apt install live-build` gives
# on noble / ubuntu-latest) rejects '--debian-installer none' at the BINARY
# stage ("debian-installer flavour none not supported"; hit by the first real
# CI build, run 28564744308). Its disable value is 'false'. Debian's modern
# live-build (2023xxxx+) is the opposite: it wants 'none'. Pick by version so
# the same script works on either build host.
DI_OFF="none"
# Match 3.0 anywhere in the version string, not just as a prefix: a future/forked
# `lb --version` that prints e.g. "live-build 3.0~a57" would miss a bare '3.0*'
# glob, leaving DI_OFF=none, which the Ubuntu fork rejects at the binary stage —
# the exact failure this line exists to avoid.
case "$(lb --version 2>/dev/null)" in *3.0*) DI_OFF="false" ;; esac
# --syslinux-theme live-build: the fork's DEFAULT theme is 'ubuntu-oneiric'
# (syslinux-themes-ubuntu-oneiric + gfxboot-theme-ubuntu — packages dead since
# ~12.04; run 28565364184 failed there). 'live-build' makes it prefer our
# LOCAL config/bootloaders/isolinux template instead. NOTE: this old fork has
# no EFI support at all (only grub/grub2/syslinux BIOS scripts exist in it),
# so the resulting ISO is BIOS/CSM-boot only — fine for QEMU/SeaBIOS smoke
# tests; real UEFI-only hardware needs the modern-live-build migration (TODO).
# A testing image must announce itself everywhere it can be seen. The ISO9660
# volume label is capped at 11 chars, so it gets the loudest short string that
# fits; --iso-application has no such limit.
if [ "$REFRACT_TESTING" = "1" ]; then
    ISO_APPLICATION="*** DANGER - REFRACT OS TESTING BUILD ($STRAIN) - NO LOGIN - DO NOT USE OR INSTALL ***"
    ISO_VOLUME="DANGER-TEST"
else
    ISO_APPLICATION="Refract OS ($STRAIN)"
    ISO_VOLUME="REFRACTOS"
fi

lb config \
    --distribution noble \
    --architectures amd64 \
    --linux-flavours generic-hwe-24.04 \
    --archive-areas "main restricted universe multiverse" \
    --debian-installer "$DI_OFF" \
    --syslinux-theme live-build \
    --iso-application "$ISO_APPLICATION" \
    --iso-volume "$ISO_VOLUME" \
    --apt-indices false \
    --apt-source-archives false
# --iso-volume deliberately does NOT vary by strain: ISO9660 volume labels
# have an 11-character limit and "REFRACTOS-LOWSPEC" etc. would blow past
# it. --iso-application has no such constraint and is where the strain
# name actually shows up (e.g. in a VM's drive label).
#
# --apt-indices false / --apt-source-archives false: drop the ~50-90 MB of
# /var/lib/apt/lists package indices (and deb-src lines) from the squashfs —
# part of getting each ISO under GitHub's 2 GiB single-asset cap so it ships
# as ONE flashable file instead of split parts. Both flags verified present in
# this fork's lb_config getopt string, and lb_chroot_archives really does
# `rm -rf chroot/var/lib/apt/lists` on LB_APT_INDICES=false. Safe because every
# repo setup script that apt-get installs anything already runs `apt-get
# update` first (audited 2026-07-29) — a fresh install regenerates the lists.
# DO NOT add `--compression xz` here: in this fork --compression only feeds
# lb_binary_tar, which never runs on an amd64 iso-hybrid build — it would be a
# silent no-op that reads like a fix. Squashfs compression is set instead via
# MKSQUASHFS_OPTIONS in config/binary below (empirically verified channel).
# DO NOT add `--apt-recommends false`: ubuntu-desktop-minimal pulls network-
# manager, cups and gnome-terminal via Recommends — it would "save" 400-600 MB
# and ship a desktop with no network UI and no terminal.

# Squashfs compression — THE lever that gets desktop strains under GitHub's
# 2 GiB single-asset cap. EMPIRICAL, from real build logs (runs 30414930853 and
# 30416054636, 2026-07-29): on this fork's amd64 iso-hybrid path the squashfs is
# GZIP, and MKSQUASHFS_OPTIONS from config/binary reaches mksquashfs verbatim —
# setting a bare "-b 1M" produced exactly "gzip compressed, data block size
# 1048576". A source-reading claim that lb_binary_rootfs hardcodes `-comp xz`
# did NOT survive contact with the build; trust the log line "Exportable
# Squashfs 4.0 filesystem, <comp> compressed". So set the compressor ourselves:
# xz is worth ~20-30% over gzip on a desktop rootfs (~450-650 MB here).
# -b 1M is ~6-9% more but costs ~6s of live boot on weak hardware (a 4 KiB read
# must inflate a full 1 MiB block). Installed systems are unaffected either way
# (Calamares copies the tree out of the squashfs). See the -b 1M note below for
# why that cost is accepted on every strain, lowspec and handheld included.
# -Xbcj x86 is now PROVEN SAFE and is a free win. It was held back while "gzip"
# in the log was ambiguous between "live-build appends nothing" and "live-build
# appends its own -comp AFTER ours" — under the second reading an xz-specific
# -X* flag before a -comp aborts mksquashfs and every build fails. Run
# 30530238585 settled it: the log reads "xz compressed, data block size
# 1048576", i.e. BOTH our flags survived verbatim and nothing is appended. The
# BCJ x86 branch-target filter costs nothing measurable at decompression.
#
# -b 1M now applies to EVERY strain, lowspec and handheld included. Earlier it
# was withheld from those two to protect weak hardware from random-read
# amplification (a 4 KiB read must inflate a whole 1 MiB block, ~6s of live
# boot). Measurements changed the trade: at 128 KiB blocks handheld missed the
# single-asset cap by 0.83 MB and lowspec by 198 MB, which would push exactly
# the two weakest-hardware strains back to SPLIT .part files — the one shape
# balenaEtcher cannot flash at all. The cost is a slower LIVE session only:
# the installed system is unaffected (Calamares copies the tree out of the
# squashfs), and the live session exists mainly to run the installer. A
# one-time slower live boot beats "you must cat the parts back together first".
#
# Must sit AFTER `lb config` (which regenerates config/binary) and BEFORE
# `lb build`. verify-boot-fixes.yml asserts the shipped squashfs really is xz,
# so a silent regression back to gzip cannot creep in unnoticed.
printf 'MKSQUASHFS_OPTIONS="-comp xz -Xbcj x86 -b 1M"\n' >> config/binary

echo -e "\033[36mBuilding ISO (this takes a long time and a lot of disk — run on the build host, not a laptop)...\033[0m"
lb build

# ---------------------------------------------------------------------------
# UEFI: Ubuntu's live-build fork emits a BIOS-only ISO (its lb_binary has no EFI
# path at all). Rather than migrate to modern live-build, post-process the built
# ISO into a HYBRID BIOS+UEFI image: extract the tree, add an EFI El Torito boot
# image (grub-mkstandalone with an embedded menu that `search --file`s for the
# casper volume), and repack with xorriso keeping the isolinux BIOS boot + a GPT
# ESP so it's still USB-writable. OVMF-verified (uefi-remaster.yml lineage).
# Failure-tolerant: if the tools/paths are missing it logs and ships BIOS-only.
# ---------------------------------------------------------------------------
# Args: <iso> <volume-id> <application-id>. The ids are passed in rather than
# hardcoded because this repack is the LAST thing to touch the ISO — whatever it
# writes is what a tester actually sees, so baking in a friendly "REFRACTOS"
# here would quietly overwrite the DANGER-TEST label a REFRACT_TESTING build
# promises, on the one image where the label matters most.
remaster_uefi() {
    local iso="$1" vol="$2" app="$3" work isohdpfx mb
    command -v xorriso >/dev/null 2>&1 && command -v grub-mkstandalone >/dev/null 2>&1 \
        && command -v mkfs.vfat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1 \
        || { echo "UEFI: tools missing (need xorriso, grub-efi-amd64-bin, dosfstools, mtools) — shipping BIOS-only." >&2; return 1; }
    isohdpfx=""
    for p in /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/syslinux/isohdpfx.bin; do [ -f "$p" ] && isohdpfx="$p" && break; done
    [ -n "$isohdpfx" ] || { echo "UEFI: isohdpfx.bin not found — shipping BIOS-only." >&2; return 1; }
    work="$(mktemp -d)"
    if ! xorriso -osirrox on -indev "$iso" -extract / "$work/tree" >/dev/null 2>&1; then
        echo "UEFI: could not extract the ISO — shipping BIOS-only." >&2; rm -rf "$work"; return 1; fi
    chmod -R u+w "$work/tree" 2>/dev/null || true
    [ -f "$work/tree/casper/vmlinuz" ] || { echo "UEFI: no casper/vmlinuz in ISO — shipping BIOS-only." >&2; rm -rf "$work"; return 1; }
    cat > "$work/grub-embed.cfg" <<'GRUB'
set timeout=5
set default=0
insmod all_video
search --set=root --file /casper/vmlinuz
# console ORDER matters: the LAST console= is where /dev/console and the
# emergency shell land. Put the serial console FIRST and tty0 (the laptop
# panel) LAST so on a real X1 an early failure shows ON SCREEN — with the old
# order the emergency shell went to an invisible ttyS0 and any recoverable
# failure looked like an identical silent hang. Serial is still mirrored for
# QEMU capture in CI.
menuentry "Refract OS (live)" {
    linux /casper/vmlinuz boot=casper quiet splash console=ttyS0,115200 console=tty0 ---
    initrd /casper/initrd.img
}
menuentry "Refract OS (verbose boot -- show progress)" {
    linux /casper/vmlinuz boot=casper nosplash systemd.show_status=true console=ttyS0,115200 console=tty0 ---
    initrd /casper/initrd.img
}
menuentry "Refract OS (recovery -- Intel display quirks: no PSR/FBC)" {
    linux /casper/vmlinuz boot=casper nosplash i915.enable_psr=0 i915.enable_fbc=0 console=ttyS0,115200 console=tty0 ---
    initrd /casper/initrd.img
}
menuentry "Refract OS (SOFTWARE GRAPHICS -- bypass the GPU, slow but works)" {
    linux /casper/vmlinuz boot=casper nomodeset nosplash console=ttyS0,115200 console=tty0 ---
    initrd /casper/initrd.img
}
GRUB
    # A REFRACT_TESTING image promises "NO SPLASH" everywhere — its whole point is
    # a visible, unattended developer boot. The DANGER autologin and the INSTALLED
    # grub already get nosplash (the /etc/default/grub sed above), but the LIVE
    # default menu entry still said "quiet splash", so a testing ISO booted live
    # showed the exact splash it promised to drop. Flip ONLY the live entry here:
    # it is the only entry carrying "quiet splash" (verbose/recovery/softgfx are
    # already nosplash), and this mirrors the installed-grub cmdline. This is the
    # UEFI path (the X1's boot path); the BIOS/isolinux live menu is left as-is.
    if [ "$REFRACT_TESTING" = "1" ]; then
        sed -i 's/boot=casper quiet splash/boot=casper nosplash systemd.show_status=true/' \
            "$work/grub-embed.cfg"
    fi
    if ! grub-mkstandalone -O x86_64-efi -o "$work/bootx64.efi" \
        --modules="part_gpt part_msdos fat iso9660 normal linux search configfile echo all_video gfxterm test" \
        "boot/grub/grub.cfg=$work/grub-embed.cfg" >/dev/null 2>&1; then
        echo "UEFI: grub-mkstandalone failed — shipping BIOS-only." >&2; rm -rf "$work"; return 1; fi
    mb=$(( $(stat -c%s "$work/bootx64.efi") / 1048576 + 4 ))
    dd if=/dev/zero of="$work/efiboot.img" bs=1M count="$mb" >/dev/null 2>&1
    mkfs.vfat "$work/efiboot.img" >/dev/null 2>&1
    mmd -i "$work/efiboot.img" ::/EFI ::/EFI/BOOT >/dev/null 2>&1
    mcopy -i "$work/efiboot.img" "$work/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI >/dev/null 2>&1
    mkdir -p "$work/tree/EFI/boot"; cp "$work/efiboot.img" "$work/tree/EFI/boot/efiboot.img"
    rm -f "$work/tree/isolinux/boot.cat"
    if ! xorriso -as mkisofs -iso-level 3 -V "$vol" -A "$app" -r -J -joliet-long \
        -isohybrid-mbr "$isohdpfx" \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e EFI/boot/efiboot.img -no-emul-boot -isohybrid-gpt-basdat \
        -o "$work/hybrid.iso" "$work/tree" >/dev/null 2>&1; then
        echo "UEFI: xorriso repack failed — shipping BIOS-only." >&2; rm -rf "$work"; return 1; fi
    mv "$work/hybrid.iso" "$iso"; rm -rf "$work"
    echo -e "\033[32mUEFI: $iso is now a hybrid BIOS+UEFI image.\033[0m"
}

# Output name differs by live-build generation: Ubuntu's 3.0~a57 fork writes
# binary.hybrid.iso / binary.iso (source-verified in its lb_binary_iso);
# Debian's modern live-build writes live-image-amd64.hybrid.iso. The first
# successful build (run 28568346976) produced binary.hybrid.iso.
RENAMED="refract-os-${STRAIN}.iso"
OUT=""
for cand in binary.hybrid.iso live-image-amd64.hybrid.iso binary.iso; do
    if [ -f "$cand" ]; then OUT="$cand"; break; fi
done
if [ -n "$OUT" ]; then
    mv "$OUT" "$RENAMED"
    remaster_uefi "$RENAMED" "$ISO_VOLUME" "$ISO_APPLICATION" \
        || echo -e "\033[33mUEFI remaster skipped/failed — the ISO is BIOS/CSM-boot only.\033[0m" >&2
    echo -e "\033[32mDone — $RENAMED ($(du -h "$RENAMED" | cut -f1))\033[0m"
else
    echo -e "\033[33mlb build finished but no known output ISO name was found — check the build log above.\033[0m" >&2
    exit 1
fi

# ┌─ REFRACT PRISM · BAND 7 of 7 · VIOLET ─────────────────────────────────────┐
# │                                                                            │
# │ If you have found the other six, you have read the four bugs that stopped  │
# │ this OS from installing, the purge that deleted its desktop, the spinner   │
# │ that killed its theme, the robot that nearly clicked Cancel, and the       │
# │ question that made it stop imitating macOS. Seven bands, recombined:       │
# │ white light. Which is the joke — a prism splits light, and you have spent  │
# │ real time putting ours back together. That is the whole prize. There is no │
# │ coupon.                                                                    │
# │                                                                            │
# │ What you actually found is the honest version of this project. Every band  │
# │ is a thing that was broken for longer than anyone realised, usually because│
# │ something claimed it was fine: a guard matching the wrong word, a test that│
# │ could not fail, a "cancelled" that was a timeout. The comments in this repo│
# │ are long on purpose. Every one of them is a bug that got to bite twice.    │
# │                                                                            │
# │ You are reading the last line of the script that produces the ISO. It runs │
# │ on a machine none of its authors could execute it on — every build of this │
# │ operating system has happened somewhere else, watched through a log.       │
# │                                                                            │
# │ Go break something. Then write down why.                                   │
# │                                                    — Refract OS, 2026      │
# └────────────────────────────────────────────────────────────────────────────┘

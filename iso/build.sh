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
INCLUDES="$(dirname "${BASH_SOURCE[0]}")/config/includes.chroot"
PACKAGE_LISTS="$(dirname "${BASH_SOURCE[0]}")/config/package-lists"
STRAIN_FILE="$REPO_ROOT/iso/strains/${STRAIN}.list.chroot"

echo -e "\033[36mStrain: $STRAIN\033[0m"
[ -f "$STRAIN_FILE" ] || { echo "Strain manifest not found: $STRAIN_FILE" >&2; exit 1; }

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
    rm -f "$PACKAGE_LISTS/macos-look.list.chroot" "$HOOKS_DIR/0300-macos-look.chroot" \
          "$PACKAGE_LISTS/polish.list.chroot" "$HOOKS_DIR/0400-polish.chroot" "$HOOKS_DIR/0410-keyd.chroot"
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
    # Without this, launching the installer pops an "Authenticate to manage disks"
    # polkit prompt (whose default button is Cancel) and the install never starts.
    # Real live ISOs grant the local live session passwordless access to the disk /
    # installer / reboot actions. Scoped to a live session (no persistence, so it's
    # gone on an installed system) by only matching the active local subject.
    mkdir -p "$INCLUDES/etc/polkit-1/rules.d"
    cat > "$INCLUDES/etc/polkit-1/rules.d/49-refract-installer.rules" <<'EOF'
polkit.addRule(function(action, subject) {
    if (subject.local && subject.active &&
        (action.id.indexOf("org.freedesktop.udisks2.") === 0 ||
         action.id.indexOf("com.github.calamares.") === 0 ||
         action.id === "org.freedesktop.policykit.exec" ||
         action.id.indexOf("org.freedesktop.login1.") === 0)) {
        return polkit.Result.YES;
    }
});
EOF
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

# Strip the installer slideshow slide for any omitted mode, so a no-<mode> image
# never advertises a mode it cannot install (design §4.1-K). Each per-mode Slide
# in show.qml is wrapped with '// @slide:<mode>' / '// @endslide:<mode>' marker
# comments; range-delete them from the build copy. Guarded by [ -f ] because the
# headless strains (server/cloud) ship no Calamares tree at all. The intro slide
# is deliberately mode-agnostic (no per-mode enumeration), so nothing there needs
# stripping.
_qml="$INCLUDES/etc/calamares/branding/refractos/show.qml"
if [ -f "$_qml" ]; then
    for m in "${OMITTED[@]}"; do
        sed -i "/\/\/ @slide:$m$/,/\/\/ @endslide:$m$/d" "$_qml"
    done
fi

echo -e "\033[36mCopying repo scripts into the image (opt/distro/, /usr/local/bin)...\033[0m"
# Copied fresh from the repo at build time rather than committed as a
# duplicate in git — there is exactly one copy of these scripts to keep in
# sync, the one under modes/ and drivers/ at the repo root.
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
    kept=()
    for cm in gaming ai server creative normal; do
        [[ " ${OMITTED[*]} " == *" $cm "* ]] || kept+=("$cm")
    done
    sed -i "s/^ALL_MODES=(.*/ALL_MODES=(${kept[*]})/" \
        "$INCLUDES/opt/distro/modes/modectl/distro-modectl"
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
LOGO=refract
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
cp "$REPO_ROOT/branding/out/wallpapers/base.png" "$INCLUDES/usr/share/backgrounds/refract-os.png"  # GNOME default (login/base)
cp "$REPO_ROOT/branding/out/logo-clean.png" "$INCLUDES/usr/share/refract/logo.png"
cp "$REPO_ROOT/branding/out/logo-small.png" "$INCLUDES/usr/share/refract/logo-small.png"
# The SVG source too — the identity hook copies it over any start-here.svg /
# ubuntu-logo.svg (a PNG written into a .svg filename renders blank).
cp "$REPO_ROOT/branding/src/logo.svg" "$INCLUDES/usr/share/refract/logo.svg"

# Plymouth boot splash (theme + its logo).
mkdir -p "$INCLUDES/usr/share/plymouth/themes/refract"
cp "$REPO_ROOT/iso/branding/plymouth/refract/refract.plymouth" "$INCLUDES/usr/share/plymouth/themes/refract/"
cp "$REPO_ROOT/iso/branding/plymouth/refract/refract.script"   "$INCLUDES/usr/share/plymouth/themes/refract/"
cp "$REPO_ROOT/branding/out/logo-clean.png" "$INCLUDES/usr/share/plymouth/themes/refract/logo.png"

# GNOME default wallpaper + dark theme via a glib SCHEMA OVERRIDE — the reliable
# mechanism (99_ sorts after Ubuntu's own 10_ override, so ours wins); compiled
# by the 0200-refract-identity chroot hook. Harmless on non-GNOME strains.
mkdir -p "$INCLUDES/usr/share/glib-2.0/schemas"
cp "$REPO_ROOT/iso/branding/glib/99_refract.gschema.override" "$INCLUDES/usr/share/glib-2.0/schemas/99_refract.gschema.override"
# dconf db for favorites (belt-and-suspenders alongside the schema override).
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
case "$(lb --version 2>/dev/null)" in 3.0*) DI_OFF="false" ;; esac
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
    --iso-volume "$ISO_VOLUME"
# --iso-volume deliberately does NOT vary by strain: ISO9660 volume labels
# have an 11-character limit and "REFRACTOS-LOWSPEC" etc. would blow past
# it. --iso-application has no such constraint and is where the strain
# name actually shows up (e.g. in a VM's drive label).

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
remaster_uefi() {
    local iso="$1" work isohdpfx mb
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
    if ! xorriso -as mkisofs -iso-level 3 -V REFRACTOS -r -J -joliet-long \
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
    remaster_uefi "$RENAMED" || echo -e "\033[33mUEFI remaster skipped/failed — the ISO is BIOS/CSM-boot only.\033[0m" >&2
    echo -e "\033[32mDone — $RENAMED ($(du -h "$RENAMED" | cut -f1))\033[0m"
else
    echo -e "\033[33mlb build finished but no known output ISO name was found — check the build log above.\033[0m" >&2
    exit 1
fi

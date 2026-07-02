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
# Usage: ./build.sh [strain]   (run from this directory: crucible-os/iso/)
#   strain is one of: workstation (default) | laptop | lowspec | server |
#   handheld | cloud — see iso/strains/*.list.chroot and iso/strains/README.md.

set -euo pipefail

STRAIN="${1:-workstation}"
VALID_STRAINS=(workstation laptop lowspec server handheld cloud)

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

# Calamares only makes sense for strains that ship a DE -- server/cloud are
# headless and would use cloud-init/preseed instead of an interactive
# installer GUI, not Calamares at all.
HEADLESS_STRAINS=(server cloud)
rm -f "$PACKAGE_LISTS/calamares.list.chroot"
rm -rf "$INCLUDES/etc/calamares"
rm -f "$INCLUDES/usr/share/applications/install-crucible-os.desktop"
rm -rf "$INCLUDES/usr/share/initramfs-tools/scripts/casper-bottom"
if [[ ! " ${HEADLESS_STRAINS[*]} " == *" $STRAIN "* ]]; then
    echo -e "\033[36mWiring in Calamares (installer config, untested -- see iso/calamares/README.md)...\033[0m"
    echo "calamares" > "$PACKAGE_LISTS/calamares.list.chroot"
    mkdir -p "$INCLUDES/etc/calamares"
    rsync -a --delete "$REPO_ROOT/iso/calamares/" "$INCLUDES/etc/calamares/" --exclude README.md
    mkdir -p "$INCLUDES/usr/share/applications"
    cat > "$INCLUDES/usr/share/applications/install-crucible-os.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Install Crucible OS
Exec=calamares
Icon=system-software-install
Terminal=false
Categories=System;
EOF
    # Live-session autostart: a casper-bottom hook (see
    # iso/casper-hooks/casper-bottom/README.md) drops the desktop entry above
    # onto the live user's Desktop during boot -- the same documented
    # mechanism real live-build+Calamares distros use (verified against
    # maui-linux/calamares-casper's casper-bottom script). config/hooks/live/
    # forces an update-initramfs run so this plain dropped-in file (not a
    # .deb, so no dpkg trigger) actually gets embedded into the live initrd.
    mkdir -p "$INCLUDES/usr/share/initramfs-tools/scripts/casper-bottom"
    cp "$REPO_ROOT/iso/casper-hooks/casper-bottom/25-crucible-install-icon" \
        "$INCLUDES/usr/share/initramfs-tools/scripts/casper-bottom/"
    chmod +x "$INCLUDES/usr/share/initramfs-tools/scripts/casper-bottom/25-crucible-install-icon"
fi

echo -e "\033[36mCopying repo scripts into the image (opt/distro/, /usr/local/bin)...\033[0m"
# Copied fresh from the repo at build time rather than committed as a
# duplicate in git — there is exactly one copy of these scripts to keep in
# sync, the one under modes/ and drivers/ at the repo root.
mkdir -p "$INCLUDES/opt/distro" "$INCLUDES/usr/local/bin"
rsync -a --delete "$REPO_ROOT/modes" "$REPO_ROOT/drivers" "$INCLUDES/opt/distro/"
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
    ln -sf "/opt/distro/${DISTRO_BINS[$bin]}/$bin" "$INCLUDES/usr/local/bin/$bin"
done
find "$INCLUDES/opt/distro" -type f \( -name "*.sh" -o -name "distro-*" \) -exec chmod +x {} +

# ---------------------------------------------------------------------------
# OS IDENTITY — make it boot AS Crucible OS, not stock Ubuntu. Crucible OS is
# Ubuntu-BASED (kernel + packages are Ubuntu's, ID_LIKE=ubuntu so apt/PPA logic
# keeps working) but everything the user SEES is rebranded: os-release, boot
# splash, wallpaper, hostname, terminal fetch.
# ---------------------------------------------------------------------------
echo -e "\033[36mBaking in Crucible OS identity...\033[0m"
VERSION_NUM="1.0"; VERSION_CODENAME="forge"
# Per-strain VARIANT label (capitalize first letter).
VARIANT_LABEL="$(printf '%s' "$STRAIN" | sed 's/^./\U&/')"

mkdir -p "$INCLUDES/etc" "$INCLUDES/usr/lib"
_osrelease() {
cat <<EOF
NAME="Crucible OS"
PRETTY_NAME="Crucible OS ${VERSION_NUM} (${VARIANT_LABEL})"
ID=crucible
ID_LIKE="ubuntu debian"
VERSION="${VERSION_NUM} (${VERSION_CODENAME^})"
VERSION_ID="${VERSION_NUM}"
VERSION_CODENAME=${VERSION_CODENAME}
UBUNTU_CODENAME=noble
HOME_URL="https://mr-pythoneer.github.io/crucible-os/"
SUPPORT_URL="https://github.com/Mr-Pythoneer/crucible-os"
BUG_REPORT_URL="https://github.com/Mr-Pythoneer/crucible-os/issues"
VARIANT="${VARIANT_LABEL}"
VARIANT_ID=${STRAIN}
LOGO=crucible
EOF
}
_osrelease > "$INCLUDES/etc/os-release"           # overrides base-files' symlink
_osrelease > "$INCLUDES/usr/lib/os-release"
cat > "$INCLUDES/etc/lsb-release" <<EOF
DISTRIB_ID=Crucible
DISTRIB_RELEASE=${VERSION_NUM}
DISTRIB_CODENAME=${VERSION_CODENAME}
DISTRIB_DESCRIPTION="Crucible OS ${VERSION_NUM}"
EOF
printf 'Crucible OS %s (%s) \\n \\l\n\n' "$VERSION_NUM" "$VARIANT_LABEL" > "$INCLUDES/etc/issue"
printf 'Crucible OS %s\n' "$VERSION_NUM" > "$INCLUDES/etc/issue.net"
# Default hostname + matching hosts entry.
echo "crucible" > "$INCLUDES/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tcrucible\n' > "$INCLUDES/etc/hosts"

# Wallpaper + logos into the image.
mkdir -p "$INCLUDES/usr/share/backgrounds/crucible" "$INCLUDES/usr/share/crucible"
# The full per-mode wallpaper set (base/gaming/ai/server/creative/normal) —
# distro-modectl swaps between them on `switch <mode>`.
cp "$REPO_ROOT"/branding/out/wallpapers/*.png "$INCLUDES/usr/share/backgrounds/crucible/"
cp "$REPO_ROOT/branding/out/wallpapers/base.png" "$INCLUDES/usr/share/backgrounds/crucible-os.png"  # GNOME default (login/base)
cp "$REPO_ROOT/branding/out/logo-clean.png" "$INCLUDES/usr/share/crucible/logo.png"
cp "$REPO_ROOT/branding/out/logo-small.png" "$INCLUDES/usr/share/crucible/logo-small.png"

# Plymouth boot splash (theme + its logo).
mkdir -p "$INCLUDES/usr/share/plymouth/themes/crucible"
cp "$REPO_ROOT/iso/branding/plymouth/crucible/crucible.plymouth" "$INCLUDES/usr/share/plymouth/themes/crucible/"
cp "$REPO_ROOT/iso/branding/plymouth/crucible/crucible.script"   "$INCLUDES/usr/share/plymouth/themes/crucible/"
cp "$REPO_ROOT/branding/out/logo-clean.png" "$INCLUDES/usr/share/plymouth/themes/crucible/logo.png"

# GNOME default wallpaper + dark theme via a glib SCHEMA OVERRIDE — the reliable
# mechanism (99_ sorts after Ubuntu's own 10_ override, so ours wins); compiled
# by the 0200-crucible-identity chroot hook. Harmless on non-GNOME strains.
mkdir -p "$INCLUDES/usr/share/glib-2.0/schemas"
cp "$REPO_ROOT/iso/branding/glib/99_crucible.gschema.override" "$INCLUDES/usr/share/glib-2.0/schemas/99_crucible.gschema.override"
# dconf db for favorites (belt-and-suspenders alongside the schema override).
mkdir -p "$INCLUDES/etc/dconf/db/local.d" "$INCLUDES/etc/dconf/profile"
cp "$REPO_ROOT/iso/branding/dconf/local.d/00-crucible" "$INCLUDES/etc/dconf/db/local.d/00-crucible"
cp "$REPO_ROOT/iso/branding/dconf/profile/user"        "$INCLUDES/etc/dconf/profile/user"
# GDM greeter branding (crucible logo + background on the login screen). The
# gdm dconf profile ships with gdm3; the hook compiles this db.
mkdir -p "$INCLUDES/etc/dconf/db/gdm.d"
cp "$REPO_ROOT/iso/branding/dconf/gdm.d/01-crucible" "$INCLUDES/etc/dconf/db/gdm.d/01-crucible"

# The identity package list (plymouth-themes/fastfetch/dconf-cli) and the
# 0200-crucible-identity chroot hook are committed source files under
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

# Binary hooks are exec'd directly by the fork's lb_binary_hooks — must be +x.
find "$(dirname "${BASH_SOURCE[0]}")/config/hooks" -maxdepth 1 -type f -name "*.binary" -exec chmod +x {} + 2>/dev/null || true

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
lb config \
    --distribution noble \
    --architectures amd64 \
    --linux-flavours generic-hwe-24.04 \
    --archive-areas "main restricted universe multiverse" \
    --debian-installer "$DI_OFF" \
    --syslinux-theme live-build \
    --iso-application "Crucible OS ($STRAIN)" \
    --iso-volume "CRUCIBLEOS"
# --iso-volume deliberately does NOT vary by strain: ISO9660 volume labels
# have an 11-character limit and "CRUCIBLEOS-LOWSPEC" etc. would blow past
# it. --iso-application has no such constraint and is where the strain
# name actually shows up (e.g. in a VM's drive label).

echo -e "\033[36mBuilding ISO (this takes a long time and a lot of disk — run on the build host, not a laptop)...\033[0m"
lb build

# Output name differs by live-build generation: Ubuntu's 3.0~a57 fork writes
# binary.hybrid.iso / binary.iso (source-verified in its lb_binary_iso);
# Debian's modern live-build writes live-image-amd64.hybrid.iso. The first
# successful build (run 28568346976) produced binary.hybrid.iso.
RENAMED="crucible-os-${STRAIN}.iso"
OUT=""
for cand in binary.hybrid.iso live-image-amd64.hybrid.iso binary.iso; do
    if [ -f "$cand" ]; then OUT="$cand"; break; fi
done
if [ -n "$OUT" ]; then
    mv "$OUT" "$RENAMED"
    echo -e "\033[32mDone — $RENAMED ($(du -h "$RENAMED" | cut -f1))\033[0m"
else
    echo -e "\033[33mlb build finished but no known output ISO name was found — check the build log above.\033[0m" >&2
    exit 1
fi

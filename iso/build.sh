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

# Neutralize the old fork's mode-ubuntu gfxboot step: lb_binary_syslinux runs
# `tar xfz /usr/share/gfxboot-theme-ubuntu/bootlogo.tar.gz` in the chroot for
# EVERY syslinux theme (it's gated on mode, not theme), but that package died
# ~Ubuntu 12.04. An empty tarball pre-placed via includes.chroot makes the tar
# a no-op AND satisfies the fork's Check_package existence test so it never
# tries to install the dead package. (~45 bytes in the installed system.)
mkdir -p "$INCLUDES/usr/share/gfxboot-theme-ubuntu"
tar -czf "$INCLUDES/usr/share/gfxboot-theme-ubuntu/bootlogo.tar.gz" -T /dev/null

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

OUT="live-image-amd64.hybrid.iso"
RENAMED="crucible-os-${STRAIN}.iso"
if [ -f "$OUT" ]; then
    mv "$OUT" "$RENAMED"
    echo -e "\033[32mDone — $RENAMED\033[0m"
else
    echo -e "\033[33mlb build finished but $OUT wasn't found — check the build log above.\033[0m" >&2
fi

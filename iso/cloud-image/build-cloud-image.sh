#!/usr/bin/env bash
#
# Builds the `cloud` strain as a real qcow2 cloud image instead of an
# installer ISO, per DESIGN.md §5b: "its delivery format should eventually
# be a qcow2/raw cloud image rather than an installer ISO." Uses the
# standard debootstrap + loop-device partition + grub-install + qemu-img
# convert pipeline (the same general recipe documented across Debian's own
# cloud-image tooling and most "build a minimal cloud image by hand"
# write-ups) -- not invented from scratch, but ALSO not run end to end
# anywhere, see "Status" below.
#
# MUST run as root on a real Debian/Ubuntu Linux host with: debootstrap,
# parted, grub-pc-bin, qemu-utils, and loop-device support (not a container
# without /dev/loop-control access). live-build is NOT used for this path at
# all -- this produces a raw disk image directly, not an ISO.
#
# Usage: sudo ./build-cloud-image.sh [size_in_GB]   (default: 4)

set -euo pipefail

# Resolved ONCE, and absolute. iso/build.sh had the same construct re-evaluated
# after a cd and it silently double-prefixed; nothing here cds, but a relative
# invocation (`./iso/cloud-image/build-cloud-image.sh`) still makes every later
# `dirname "$BASH_SOURCE"` depend on the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "build-cloud-image.sh: must run as root (loop devices, mount, chroot, grub-install)." >&2
    exit 1
fi

if [ "$(uname)" != "Linux" ]; then
    echo "build-cloud-image.sh: only runs on Linux (debootstrap, losetup, chroot don't exist on macOS)." >&2
    exit 1
fi

for tool in debootstrap parted mkfs.ext4 losetup partprobe grub-install qemu-img chroot; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "build-cloud-image.sh: required tool not found: $tool" >&2
        echo "Install with: apt-get install debootstrap parted e2fsprogs util-linux grub-pc-bin qemu-utils" >&2
        exit 1
    fi
done

SIZE_GB="${1:-4}"
WORK_DIR="$(mktemp -d /tmp/refract-cloud-build.XXXXXX)"
RAW_IMG="$WORK_DIR/cloud.img"
MOUNT_DIR="$WORK_DIR/rootfs"
OUT_QCOW2="refract-os-cloud.qcow2"

cleanup() {
    set +e
    if mountpoint -q "$MOUNT_DIR/dev" 2>/dev/null; then umount "$MOUNT_DIR/dev"; fi
    if mountpoint -q "$MOUNT_DIR/proc" 2>/dev/null; then umount "$MOUNT_DIR/proc"; fi
    if mountpoint -q "$MOUNT_DIR/sys" 2>/dev/null; then umount "$MOUNT_DIR/sys"; fi
    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then umount "$MOUNT_DIR"; fi
    if [ -n "${LOOP_DEV:-}" ]; then losetup -d "$LOOP_DEV" 2>/dev/null; fi
}
trap cleanup EXIT

mkdir -p "$MOUNT_DIR"

echo "Creating ${SIZE_GB}G raw image: $RAW_IMG"
qemu-img create -f raw "$RAW_IMG" "${SIZE_GB}G"

# --partscan is REQUIRED: a loop device attached without it (and with the loop
# module's default max_part=0) never gets /dev/loopXp1 partition nodes created,
# so mkfs.ext4 on ${LOOP_DEV}p1 would fail with "No such file or directory".
# --find --show also makes the attach atomic, avoiding the losetup -f / losetup
# two-step TOCTOU race.
LOOP_DEV="$(losetup --partscan --find --show "$RAW_IMG")"

echo "Partitioning $LOOP_DEV (single ext4 partition, BIOS/GRUB legacy boot -- no ESP, see Status notes)..."
parted -s "$LOOP_DEV" mklabel msdos
parted -s "$LOOP_DEV" mkpart primary ext4 1MiB 100%
parted -s "$LOOP_DEV" set 1 boot on
partprobe "$LOOP_DEV"
# Wait deterministically for the partition node to appear rather than guessing a
# fixed sleep. Fall back to a bounded poll if udevadm isn't present.
udevadm settle 2>/dev/null || { for _ in $(seq 1 10); do [ -b "${LOOP_DEV}p1" ] && break; sleep 0.5; done; }

PART_DEV="${LOOP_DEV}p1"
mkfs.ext4 -F "$PART_DEV"
mount "$PART_DEV" "$MOUNT_DIR"

echo "Running debootstrap (noble, minimal)..."
debootstrap --arch=amd64 --variant=minbase noble "$MOUNT_DIR" http://archive.ubuntu.com/ubuntu

UUID="$(blkid -s UUID -o value "$PART_DEV")"
cat > "$MOUNT_DIR/etc/fstab" <<EOF
UUID=$UUID / ext4 defaults 0 1
EOF

cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"
mount --bind /dev "$MOUNT_DIR/dev"
mount -t proc proc "$MOUNT_DIR/proc"
mount -t sysfs sysfs "$MOUNT_DIR/sys"

echo "Installing kernel, GRUB, cloud-init, and the cloud strain's package list inside the chroot..."
# Inner chroot bash -c shells do NOT inherit the outer set -euo pipefail, so
# each gets its own — otherwise a failed apt-get whose block ends on a
# succeeding `rm` would return 0 and the outer set -e would never see it,
# producing a "Done" image silently missing packages.
chroot "$MOUNT_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive bash -c '
    set -euo pipefail
    apt-get update
    apt-get install -y --no-install-recommends \
        linux-image-generic grub-pc cloud-init cloud-guest-utils openssh-server
'

cp "$SCRIPT_DIR/../strains/cloud.list.chroot" "$MOUNT_DIR/tmp/cloud.list.chroot" 2>/dev/null || true
if [ -f "$MOUNT_DIR/tmp/cloud.list.chroot" ]; then
    chroot "$MOUNT_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive bash -c '
        set -euo pipefail
        grep -v "^##" /tmp/cloud.list.chroot | xargs -r apt-get install -y --no-install-recommends
        rm -f /tmp/cloud.list.chroot
    '
fi

# ---------------------------------------------------------------------------
# FIREWALL. This pipeline does NOT use live-build — it never reads
# base.list.chroot and never runs anything in iso/config/hooks — so ufw was
# simply absent and 0460-firewall.chroot never executed. The image installs
# openssh-server five lines above, which means the cloud strain, the ONE strain
# that boots straight onto a public network, shipped :22 open with no firewall
# at all, while every desktop strain that has no sshd got one.
#
# The hook is strain-agnostic and self-gating — it exits if ufw is missing and
# only opens :22 after confirming openssh-server is installed — so it runs here
# unmodified rather than being reimplemented and drifting.
chroot "$MOUNT_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends ufw
if [ -f "$SCRIPT_DIR/../config/hooks/0460-firewall.chroot" ]; then
    cp "$SCRIPT_DIR/../config/hooks/0460-firewall.chroot" "$MOUNT_DIR/tmp/firewall.sh"
    # NOT fatal. A cloud image that fails to build helps nobody; a loud warning
    # in the build log is the right severity for a step whose absence is visible
    # to `ufw status` on the running instance.
    chroot "$MOUNT_DIR" sh /tmp/firewall.sh \
        || echo "WARNING: the firewall hook did not complete — this image may have no firewall." >&2
    rm -f "$MOUNT_DIR/tmp/firewall.sh"
else
    echo "WARNING: 0460-firewall.chroot not found — cloud image built WITHOUT a firewall." >&2
fi

# ---------------------------------------------------------------------------
# REFRACT IDENTITY. Everything above this point produces a stock Ubuntu noble
# rootfs; without this block the script wrote out a file called
# refract-os-cloud.qcow2 whose contents were plain Ubuntu — no os-release, no
# hostname, no modes, no distro-modectl. Anyone who followed
# docs/first-hardware-runbook.md got Ubuntu under a Refract filename.
#
# This is a deliberately SMALL identity layer, not a copy of the ISO pipeline's:
# a cloud image is headless, so the splash/wallpaper/icon/GTK work in
# iso/config/hooks/ is all inapplicable. What matters here is that the system
# identifies as Refract and that the mode machinery is present and usable.
# Keep VERSION_NUM/CODENAME in step with iso/build.sh — they are duplicated
# because the two pipelines share no common file yet; unifying them is still
# outstanding (see iso/cloud-image/README.md).
echo "Baking in Refract OS identity (os-release, hostname, modes)..."
VERSION_NUM="1.0"; VERSION_CODENAME="forge"
_osrelease() {
cat <<EOF
NAME="Refract OS"
PRETTY_NAME="Refract OS ${VERSION_NUM} (Cloud)"
ID=refract
ID_LIKE="ubuntu debian"
VERSION="${VERSION_NUM} (Forge)"
VERSION_ID="${VERSION_NUM}"
VERSION_CODENAME=${VERSION_CODENAME}
UBUNTU_CODENAME=noble
HOME_URL="https://mr-pythoneer.github.io/refract-os/"
SUPPORT_URL="https://github.com/Mr-Pythoneer/refract-os"
BUG_REPORT_URL="https://github.com/Mr-Pythoneer/refract-os/issues"
VARIANT="Cloud"
EOF
}
_osrelease > "$MOUNT_DIR/etc/os-release"
_osrelease > "$MOUNT_DIR/usr/lib/os-release"
cat > "$MOUNT_DIR/etc/lsb-release" <<EOF
DISTRIB_ID=Refract
DISTRIB_RELEASE=${VERSION_NUM}
DISTRIB_CODENAME=${VERSION_CODENAME}
DISTRIB_DESCRIPTION="Refract OS ${VERSION_NUM}"
EOF
printf 'Refract OS %s (Cloud) \\n \\l\n\n' "$VERSION_NUM" > "$MOUNT_DIR/etc/issue"
printf 'Refract OS %s\n' "$VERSION_NUM" > "$MOUNT_DIR/etc/issue.net"
echo "refract" > "$MOUNT_DIR/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\trefract\n' > "$MOUNT_DIR/etc/hosts"
# GRUB's menu title comes from GRUB_DISTRIBUTOR, and update-grub runs below.
grep -q '^GRUB_DISTRIBUTOR=' "$MOUNT_DIR/etc/default/grub" 2>/dev/null \
    && sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Refract OS"/' "$MOUNT_DIR/etc/default/grub" \
    || echo 'GRUB_DISTRIBUTOR="Refract OS"' >> "$MOUNT_DIR/etc/default/grub"

# The mode machinery, laid out exactly as iso/build.sh does it so paths in the
# docs and in distro-modectl's own PROFILE_DIR lookup resolve identically.
_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$MOUNT_DIR/opt/distro" "$MOUNT_DIR/usr/local/bin" "$MOUNT_DIR/etc/refract"
cp -a "$_repo_root/modes" "$_repo_root/drivers" "$MOUNT_DIR/opt/distro/"
ln -sf /opt/distro/modes/modectl/distro-modectl "$MOUNT_DIR/usr/local/bin/distro-modectl"
find "$MOUNT_DIR/opt/distro" -type f \( -name '*.sh' -o -name 'distro-*' \) -exec chmod +x {} +
# A cloud instance is headless: 'server' is the mode that makes sense here, and
# 'normal' is always-on and never listed (the loader force-appends it). Gaming,
# AI and Creative are desktop modes and are deliberately not advertised.
{
    echo "# Refract OS — enabled optional modes (one per line; '#' comments ok)."
    echo "# 'normal' is the always-on base desktop and is never listed here."
    echo "server"
} > "$MOUNT_DIR/etc/refract/enabled-modes"
chmod 0644 "$MOUNT_DIR/etc/refract/enabled-modes"
# Ubuntu's login banner and ads, same treatment as the ISO's identity hook.
: > "$MOUNT_DIR/etc/legal" 2>/dev/null || true
for _m in 00-header 10-help-text 50-motd-news 88-esm-announce \
          91-release-upgrade 91-contract-ua-esm-status 92-unattended-upgrades; do
    [ -e "$MOUNT_DIR/etc/update-motd.d/$_m" ] && chmod -x "$MOUNT_DIR/etc/update-motd.d/$_m" 2>/dev/null || true
done
mkdir -p "$MOUNT_DIR/etc/update-motd.d"
cat > "$MOUNT_DIR/etc/update-motd.d/00-refract" <<'MOTD'
#!/bin/sh
printf '\n  Refract OS 1.0 (Cloud)  —  headless instance\n'
printf '  switch look+behaviour:  distro-modectl switch server|normal\n\n'
MOTD
chmod +x "$MOUNT_DIR/etc/update-motd.d/00-refract"

echo "Installing GRUB to $LOOP_DEV..."
chroot "$MOUNT_DIR" grub-install --target=i386-pc "$LOOP_DEV"
chroot "$MOUNT_DIR" update-grub

echo "Unmounting and converting raw image to qcow2..."
umount "$MOUNT_DIR/dev" "$MOUNT_DIR/proc" "$MOUNT_DIR/sys"
umount "$MOUNT_DIR"
losetup -d "$LOOP_DEV"
LOOP_DEV=""   # already detached, skip in cleanup trap

qemu-img convert -O qcow2 -c "$RAW_IMG" "$OUT_QCOW2"
rm -rf "$WORK_DIR"

echo -e "\033[32mDone -- $OUT_QCOW2\033[0m"
echo "Boots via any QEMU/KVM/cloud platform that accepts qcow2 + cloud-init"
echo "(NoCloud datasource via attached seed ISO, or the platform's own metadata service)."

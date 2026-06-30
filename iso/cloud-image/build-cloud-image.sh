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
WORK_DIR="$(mktemp -d /tmp/crucible-cloud-build.XXXXXX)"
RAW_IMG="$WORK_DIR/cloud.img"
MOUNT_DIR="$WORK_DIR/rootfs"
OUT_QCOW2="crucible-os-cloud.qcow2"

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

cp "$(dirname "${BASH_SOURCE[0]}")/../strains/cloud.list.chroot" "$MOUNT_DIR/tmp/cloud.list.chroot" 2>/dev/null || true
if [ -f "$MOUNT_DIR/tmp/cloud.list.chroot" ]; then
    chroot "$MOUNT_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive bash -c '
        set -euo pipefail
        grep -v "^##" /tmp/cloud.list.chroot | xargs -r apt-get install -y --no-install-recommends
        rm -f /tmp/cloud.list.chroot
    '
fi

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

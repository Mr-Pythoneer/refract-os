#!/usr/bin/env bash
#
# Installs the proprietary Nvidia driver (open kernel module flavour) and, if
# Secure Boot is enabled, walks through MOK (Machine Owner Key) signing so the
# kernel module actually loads instead of being silently rejected at boot.
# See DESIGN.md §3.
#
# IMPORTANT (RTX 50-series / Blackwell, e.g. the RTX 5090):
#   - Blackwell REQUIRES the *open* kernel module ("-open" packages). The
#     closed proprietary module does not support Blackwell at all and
#     `nvidia-smi` reports "No devices were found". The open module also
#     supports Turing (RTX 20) and newer, so this script defaults to the
#     -open packages, which is correct for this project's target hardware
#     (recent Nvidia RTX + AMD). Pre-Turing GPUs (Pascal/Maxwell) would need
#     the closed module instead -- not the target here.
#   - Blackwell needs driver branch >= 570. The old 550 branch does NOT
#     support the 5090. Pass an explicit recent version (e.g. 580) if the
#     auto path doesn't pick a new enough one.
#
# This does NOT disable Secure Boot for you — that's a meaningful security
# posture change and should be the user's explicit choice, not a default
# this script makes silently.
#
# Usage: ./install-nvidia.sh [driver_version]
#   driver_version: an apt package number like "580" -> installs
#   nvidia-driver-580-open. If omitted, uses `ubuntu-drivers install nvidia`
#   (recommended driver), with a Blackwell fallback note printed.

set -euo pipefail

DRIVER_VERSION="${1:-}"

echo -e "\033[36mDetecting GPU...\033[0m"
if ! lspci | grep -qi nvidia; then
    echo "No Nvidia GPU detected via lspci. Aborting — nothing to install." >&2
    exit 1
fi
lspci | grep -i nvidia

# mokutil is the only reliable way to read Secure Boot state, and it is tiny
# and frequently absent on server/minimal/cloud/non-UEFI installs. Install it
# up front so we never mistake "couldn't check" for "Secure Boot off" -- an
# unsigned module under an ENABLED Secure Boot is silently rejected at boot
# (black screen / nouveau fallback), so a false "no signing needed" message
# would be actively dangerous.
sudo apt-get update
if ! command -v mokutil >/dev/null 2>&1; then
    sudo apt-get install -y mokutil
fi
SECURE_BOOT_STATE=$(mokutil --sb-state 2>/dev/null | grep -o "enabled\|disabled" || echo "unknown")
echo "Secure Boot state: $SECURE_BOOT_STATE"

if [ -n "$DRIVER_VERSION" ]; then
    PKG="nvidia-driver-${DRIVER_VERSION}-open"
    echo -e "\033[36mInstalling $PKG (open kernel module — required for Blackwell)...\033[0m"
    sudo apt-get install -y "$PKG"
else
    if ! command -v ubuntu-drivers >/dev/null 2>&1; then
        sudo apt-get install -y ubuntu-drivers-common
    fi
    # Prefer the OPEN kernel module. The CLOSED module does NOT support Blackwell
    # (RTX 50-series) — nvidia-smi reports "No devices found" — yet a plain
    # `ubuntu-drivers install nvidia` frequently selects the closed recommended
    # driver. So derive the newest available driver branch and install its -open
    # variant; only fall back to the autoinstaller if no -open package exists.
    # `|| true`: under `set -euo pipefail` a no-match grep makes the whole
    # pipeline exit non-zero, which would abort the script BEFORE the graceful
    # `[ -n "$REC_VER" ]` fallback below — the exact new-Blackwell case where no
    # nvidia-driver-NNN line exists yet. Tolerate the empty result instead.
    REC_VER="$(ubuntu-drivers list 2>/dev/null | grep -oE 'nvidia-driver-[0-9]+' | grep -oE '[0-9]+' | sort -rn | head -n1 || true)"
    if [ -n "$REC_VER" ] && apt-cache show "nvidia-driver-${REC_VER}-open" >/dev/null 2>&1; then
        echo -e "\033[36mInstalling nvidia-driver-${REC_VER}-open (open kernel module — Blackwell-safe)...\033[0m"
        sudo apt-get install -y "nvidia-driver-${REC_VER}-open"
    else
        echo -e "\033[33mNo -open driver found in your enabled repos — falling back to ubuntu-drivers autoinstall, which may install the CLOSED module (NOT Blackwell-safe; add ppa:graphics-drivers/ppa for a newer -open).\033[0m" >&2
        sudo ubuntu-drivers install nvidia
    fi
    cat <<'EOF'

NOTE for RTX 50-series / Blackwell (e.g. RTX 5090): the auto-selected driver
only works if a 570+ *-open* driver is actually reachable from your enabled
repos. Stock Ubuntu 24.04 may not carry a new enough one. If `nvidia-smi`
reports "No devices were found" after reboot, install an explicit recent
open driver instead — e.g. via the graphics-drivers PPA:

  sudo add-apt-repository -y ppa:graphics-drivers/ppa
  sudo apt-get update
  ./install-nvidia.sh 580        # installs nvidia-driver-580-open

(The 550 branch and older do NOT support the 5090 at all.)
EOF
fi

if [ "$SECURE_BOOT_STATE" = "disabled" ]; then
    echo -e "\033[32mSecure Boot is disabled — no MOK signing needed. Reboot to load the driver.\033[0m"
else
    # Covers "enabled" AND "unknown": if we cannot PROVE Secure Boot is off,
    # warn rather than falsely reassure.
    if [ "$SECURE_BOOT_STATE" = "unknown" ]; then
        echo -e "\033[33mWARNING: could not determine Secure Boot state. If it is ENABLED, the unsigned Nvidia module will be rejected at boot. Follow the MOK steps below to be safe.\033[0m"
    else
        echo -e "\033[33mSecure Boot is ENABLED.\033[0m"
    fi
    cat <<'EOF'

The Nvidia kernel module (nvidia.ko) is unsigned by default and the kernel
will refuse to load it under Secure Boot unless you either:

  (a) Enroll a Machine Owner Key (MOK) and sign the module — recommended,
      keeps Secure Boot on:

        sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
        # You'll be asked to set a one-time password here.
        # REBOOT. At boot you'll see a blue "MOK management" screen —
        # select "Enroll MOK", enter the password you just set, then continue boot.
        # DKMS (which Ubuntu's nvidia-driver packages use) signs the module
        # automatically against this key on every kernel update afterward.

  (b) Disable Secure Boot in your BIOS/UEFI settings — simpler, but weakens
      boot-chain integrity verification. Your call, not made for you here.

Reboot is required either way before the driver actually loads.
EOF
fi

echo -e "\nAfter rebooting, verify with: nvidia-smi"

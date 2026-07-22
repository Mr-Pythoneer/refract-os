#!/usr/bin/env bash
#
# One-shot check of both driver installs — run after rebooting from
# install-nvidia.sh / install-amd-microcode.sh.

set -uo pipefail   # no -e: we want every check to run even if one fails

PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo -e "\033[32m[PASS]\033[0m $desc"
        PASS=$((PASS + 1))
    else
        echo -e "\033[31m[FAIL]\033[0m $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Nvidia ==="
# Only applicable when an Nvidia GPU is actually present. On a box without one
# (e.g. Intel/AMD-GPU hardware) these checks are not-applicable, not failures —
# skip so a healthy machine still PASSes.
if lspci 2>/dev/null | grep -qi nvidia; then
    check "nvidia-smi runs" nvidia-smi
    if nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
    fi
else
    echo -e "\033[33m[SKIP]\033[0m no Nvidia GPU detected via lspci — not applicable"
fi

echo -e "\n=== AMD microcode ==="
# Likewise: amd64-microcode only applies to AMD CPUs. Skip (don't fail) on
# non-AMD hardware.
if ! grep -qi amd /proc/cpuinfo 2>/dev/null; then
    echo -e "\033[33m[SKIP]\033[0m no AMD CPU detected via /proc/cpuinfo — not applicable"
else
    check "amd64-microcode package installed" dpkg -s amd64-microcode
    if dmesg 2>/dev/null | grep -qiE 'microcode: (Updated early|Current revision|Reload completed)' || (command -v journalctl >/dev/null 2>&1 && journalctl -k -b 2>/dev/null | grep -qi microcode); then
        echo -e "\033[32m[PASS]\033[0m microcode loaded this boot"
        PASS=$((PASS + 1))
    else
        echo -e "\033[31m[FAIL]\033[0m microcode not confirmed loaded this boot (check after a reboot)"
        FAIL=$((FAIL + 1))
    fi
fi

echo -e "\n=== Secure Boot ==="
if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>/dev/null || echo "mokutil installed but --sb-state failed"
else
    echo "mokutil not installed — install it to check Secure Boot state"
fi

echo -e "\n$PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]

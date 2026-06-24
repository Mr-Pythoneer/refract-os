#!/usr/bin/env bash
#
# Installs FreeCAD via Flatpak/Flathub. FreeCAD's Flathub app ID has changed
# historically (org.freecadweb.FreeCAD -> org.freecad.FreeCAD around the
# 0.21 rebrand) — this script tries the current ID first and falls back to
# searching rather than silently failing or guessing wrong.

set -euo pipefail

if ! command -v flatpak >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y flatpak
fi
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

CANDIDATES=("org.freecad.FreeCAD" "org.freecadweb.FreeCAD")
for app_id in "${CANDIDATES[@]}"; do
    echo -e "\033[36mTrying $app_id ...\033[0m"
    if flatpak install -y flathub "$app_id" 2>/dev/null; then
        echo -e "\033[32mInstalled: $app_id\033[0m"
        echo "If modes/modectl/profiles/creative.conf's PINNED_APPS lists a different ID, update it to: ${app_id}.desktop"
        exit 0
    fi
done

echo -e "\033[33mNeither known app ID installed. Searching Flathub for the current one:\033[0m"
flatpak search freecad || true
echo "Install manually with: flatpak install flathub <id-from-above>"
exit 1

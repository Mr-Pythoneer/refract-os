#!/usr/bin/env bash
#
# Installs Kdenlive via Flatpak/Flathub (KDE apps follow the org.kde.<App>
# naming convention consistently, unlike FreeCAD's history).

set -euo pipefail

if ! command -v flatpak >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y flatpak
fi
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

echo -e "\033[36mInstalling Kdenlive...\033[0m"
flatpak install -y flathub org.kde.kdenlive

echo -e "\033[32mKdenlive installed. Launch with: flatpak run org.kde.kdenlive\033[0m"

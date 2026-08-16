#!/usr/bin/env bash
#
# Installs Docker Engine from Docker's own apt repo (Ubuntu's distro package
# is usually older and sometimes a different fork entirely — docker.io vs
# docker-ce). Adds the invoking user to the docker group so sudo isn't
# needed for every command, which is the standard tradeoff Docker itself
# documents (it's root-equivalent access, by design — not a bug to "fix").

set -euo pipefail

. /etc/os-release

sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# UBUNTU_CODENAME, NOT VERSION_CODENAME. Refract sets VERSION_CODENAME=forge in
# /etc/os-release (hooks/0200-refract-identity.chroot) — that is the whole point
# of the identity layer. download.docker.com has no dists/forge, so this line
# used to write a repo that 404s, apt-get update failed, `set -e` killed the
# script before Docker was installed, AND the broken docker.list was left behind
# so every later `apt-get update` on the machine — including GNOME Software's and
# unattended-upgrades' — reported an error from then on. UBUNTU_CODENAME is the
# upstream series (noble) and is exactly what third-party Ubuntu repos want.
codename="${UBUNTU_CODENAME:-}"
if [ -z "$codename" ]; then
    echo -e "\033[31mCould not determine the Ubuntu series from /etc/os-release.\033[0m" >&2
    exit 1
fi

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $codename stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Leave no broken source behind. If the repo is unreachable, removing the file we
# just wrote is the difference between "Docker did not install" and "apt is
# broken on this machine forever".
if ! sudo apt-get update; then
    sudo rm -f /etc/apt/sources.list.d/docker.list
    echo -e "\033[31mCould not reach download.docker.com — removed the repo file so apt keeps working.\033[0m" >&2
    exit 1
fi
echo -e "\033[36mInstalling Docker Engine...\033[0m"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

if ! groups "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    echo -e "\033[33mAdded $USER to the docker group — log out and back in (or run 'newgrp docker') for it to take effect.\033[0m"
fi

sudo systemctl enable --now docker
docker --version

echo -e "\033[32mDocker installed.\033[0m"

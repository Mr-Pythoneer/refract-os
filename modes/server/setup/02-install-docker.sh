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

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $VERSION_CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
echo -e "\033[36mInstalling Docker Engine...\033[0m"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

if ! groups "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    echo -e "\033[33mAdded $USER to the docker group — log out and back in (or run 'newgrp docker') for it to take effect.\033[0m"
fi

sudo systemctl enable --now docker
docker --version

echo -e "\033[32mDocker installed.\033[0m"

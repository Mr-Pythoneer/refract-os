#!/usr/bin/env bash
#
# Installs and hardens OpenSSH server for Server mode. Hardening here means
# disabling password auth by default — NOT auto-generating keys for you,
# since that's the user's credential to control. The script checks an
# authorized key exists before locking out password auth, so it can't lock
# you out of your own machine.

set -euo pipefail

sudo apt-get update
echo -e "\033[36mInstalling openssh-server...\033[0m"
sudo apt-get install -y openssh-server

AUTH_KEYS="$HOME/.ssh/authorized_keys"
if [ ! -s "$AUTH_KEYS" ]; then
    cat <<EOF
WARNING: no keys found in $AUTH_KEYS.

Add at least one public key before disabling password auth, or you will
lock yourself out over SSH:

  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  echo "<your public key>" >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys

Re-run this script after that to apply the password-auth-disabled hardening.
EOF
    exit 1
fi

SSHD_CONFIG="/etc/ssh/sshd_config.d/99-distro-hardening.conf"
echo -e "\033[36mWriting $SSHD_CONFIG (disables password auth, root login)...\033[0m"
sudo tee "$SSHD_CONFIG" >/dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF

sudo systemctl enable --now ssh
sudo sshd -t && sudo systemctl reload ssh

echo -e "\033[32mSSH installed and hardened (key-only auth, no root login).\033[0m"
echo "Consider also: sudo apt-get install -y fail2ban   (optional, not installed by default)"

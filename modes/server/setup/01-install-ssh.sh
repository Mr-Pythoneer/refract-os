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

# Validate BEFORE applying to the running daemon. If we enable/start first and
# the drop-in is broken, a fresh start fails the unit and set -e aborts here
# generically — bypassing this friendly diagnostic. Test first, remove the bad
# drop-in on failure, and only then start/reload.
if ! sudo sshd -t; then
    echo "sshd config test failed — removing $SSHD_CONFIG, the hardening config is broken. See 'sudo sshd -t' output above." >&2
    sudo rm -f "$SSHD_CONFIG"
    exit 1
fi
# OPEN THE PORT. hooks/0460-firewall.chroot enables ufw with a default-deny
# incoming policy, and adds the SSH rule only on strains that ship sshd at BUILD
# time. Server mode is available on every strain, so installing sshd here on a
# workstation/laptop image produced a running, hardened, correctly-enabled sshd
# behind a firewall that silently dropped every connection to it — this script
# printed its green success line and remote login did not work, with nothing
# saying why. Idempotent; a no-op if ufw is absent or the rule already exists.
if command -v ufw >/dev/null 2>&1; then
    if sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
        sudo ufw allow OpenSSH >/dev/null 2>&1 || sudo ufw allow 22/tcp >/dev/null 2>&1 || true
        echo -e "\033[36mOpened SSH in the firewall (ufw).\033[0m"
    fi
fi

sudo systemctl enable --now ssh
sudo systemctl reload ssh

echo -e "\033[32mSSH installed and hardened (key-only auth, no root login).\033[0m"
echo "Consider also: sudo apt-get install -y fail2ban   (optional, not installed by default)"

#!/usr/bin/env bash
#
# Installs Node.js (if needed) and OpenCode (the coding agent CLI).

set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
    echo -e "\033[36mNode.js not found — installing via apt...\033[0m"
    sudo apt-get update
    sudo apt-get install -y nodejs npm
fi

# Version check must run for a PRE-EXISTING node too, not only the freshly
# apt-installed one — an old distro/snap/NodeSource node is exactly the case
# this guard is meant to catch, so it lives outside the install conditional.
NODE_MAJOR=$(node -v | sed -E 's/^v([0-9]+).*/\1/')
if [ "$NODE_MAJOR" -lt 18 ]; then
    cat <<'EOF'

WARNING: the installed Node.js is older than v18, which OpenCode may not
support. Install a current LTS via NodeSource instead:

  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt-get install -y nodejs

Re-run this script after that.
EOF
    exit 1
fi

echo -e "\033[36mInstalling OpenCode (npm install -g opencode-ai)...\033[0m"
sudo npm install -g opencode-ai

VERSION=$(opencode --version)
echo -e "\033[32m\nOpenCode installed: $VERSION\033[0m"
echo "Next: load a coding model and start the server:  distro-ai-model use coding"
echo "Then copy config/opencode.ollama.json into your project as opencode.json before launching 'opencode'."
echo "(For Claude cloud instead: distro-ai-cloud-toggle enable — needs your ANTHROPIC_API_KEY.)"

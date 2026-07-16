#!/usr/bin/env bash
#
# OPTIONAL noob-friendly GUI for AI mode: Alpaca, the GNOME-native Ollama chat
# client (https://flathub.org/apps/com.jeffser.Alpaca). Everything else in AI
# mode is CLI/overlay-driven; this gives a point-and-click chat window for users
# who don't want a terminal. Purely additive — nothing depends on it.
#
# INSTALLED VIA FLATPAK, --user: Alpaca isn't in the Ubuntu archive and ships
# as a Flatpak. flatpak is already pulled in by the laptop strain
# (iso/strains/laptop.list.chroot), so this adds NO new system dependency. We
# install per-user (--user) so it lives in the invoking user's ~/.local, not
# system-wide, matching "run as the normal user" like the other GUI setup steps.
#
# USE THE SYSTEM OLLAMA, NOT ALPACA'S BUNDLED ENGINE: Alpaca can spin up its own
# managed copy of Ollama ("Integrated Instance"). We DON'T want that here — it
# duplicates the model store (a second multi-GB ~/.var copy of weights we
# already pulled to the system Ollama) and its GPU passthrough inside the
# sandbox is flaky. Instead we point Alpaca at the SYSTEM Ollama service (the one
# 01-install-ollama.sh set up) as an EXTERNAL/remote instance on
# http://localhost:11434. Alpaca's Flatpak shares host networking, so
# 'localhost' inside the sandbox reaches the host daemon directly.
#
# Alpaca's remote-instance selection lives in its in-app Instance Manager, whose
# on-disk format has changed across Alpaca releases. Rather than fake a config
# file that a future version might ignore or choke on, we print the exact
# one-time Settings steps for the user to do once (see the end of this script).
#
# Usage: ./06-install-alpaca.sh          (run as your normal user, NOT root)

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, not root (Alpaca installs per-user via 'flatpak --user')." >&2
    exit 1
fi

if ! command -v flatpak >/dev/null 2>&1; then
    # Shouldn't happen on the laptop strain (flatpak is in the package list), but
    # guard so a bare/other strain gets a clear message instead of a 'set -e' abort.
    echo "flatpak not found. It ships in the laptop strain; on another strain: sudo apt-get install -y flatpak" >&2
    exit 1
fi

APP_ID="com.jeffser.Alpaca"

# Ensure the Flathub remote exists at the user level (Alpaca lives on Flathub).
# --if-not-exists makes this a no-op when it's already configured -> idempotent.
echo -e "\033[36mEnsuring the Flathub remote is configured (--user)...\033[0m"
flatpak remote-add --user --if-not-exists \
    flathub https://flathub.org/repo/flathub.flatpakrepo

# Idempotent install: skip the download if Alpaca is already present (either a
# prior --user install or a system-wide one), otherwise pull it from Flathub.
if flatpak info "$APP_ID" >/dev/null 2>&1; then
    echo -e "\033[32mAlpaca ($APP_ID) is already installed — nothing to do.\033[0m"
else
    echo -e "\033[36mInstalling Alpaca ($APP_ID) from Flathub (--user)...\033[0m"
    flatpak install -y --user flathub "$APP_ID"
fi

# One-time manual step: point Alpaca at the system Ollama and pull a first model.
# Unquoted heredoc so the $(printf ...) colour headers expand (same pattern as
# 03-install-comfyui.sh). The body has no other $ / backticks to worry about.
cat <<EOF

$(printf '\033[32mAlpaca installed.\033[0m') Launch it from your app grid, or:  flatpak run com.jeffser.Alpaca

$(printf '\033[33mONE-TIME SETUP — connect Alpaca to the SYSTEM Ollama (do this once):\033[0m')
  1. Open Alpaca, then its menu (three-line ☰) -> Preferences -> Instances.
  2. Add a new instance (the '+' button) and choose the REMOTE / "Connect
     Remote Instance" type (an Ollama connection), NOT the bundled/integrated
     managed instance.
  3. Set the URL to:   http://localhost:11434
     Leave the API key / bearer token blank (the system Ollama needs none).
  4. Save it and set it as the DEFAULT instance.

  Why remote and not the bundled engine: the integrated instance downloads a
  SECOND private copy of every model into ~/.var/app/com.jeffser.Alpaca and has
  flaky in-sandbox GPU access. Using the system Ollama reuses the weights and
  the GPU setup AI mode already configured.

$(printf '\033[33mFIRST RUN — pull one small model so the chat box has something to talk to:\033[0m')
  Easiest, from a terminal (uses the system Ollama your CLI already targets):
      ollama pull llama3.1:8b        # ~8B, good day-to-day default
      ollama pull qwen2.5-coder:7b   # if you mainly want coding help
  On a tight-RAM laptop, prefer a 3B:  ollama pull qwen2.5-coder:3b
  (You can also pull from inside Alpaca's model manager once it's pointed at the
  remote instance above. Either way the model is shared — one copy, one store.)

This script is optional and safe to re-run (idempotent).
EOF

#!/usr/bin/env bash
#
# Installs the Nautilus "ask AI about this file" script into the per-user
# scripts directory Nautilus scans for its right-click Scripts submenu.
# Real, documented Nautilus mechanism (not a guess): any executable file
# under ~/.local/share/nautilus/scripts/ shows up there automatically, no
# separate registration needed. Run as the desktop user, not via sudo --
# this installs into the invoking user's home directory by design.
#
# Usage: ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.local/share/nautilus/scripts"
DEST_NAME="Ask AI about this file"

if [ "$(id -u)" -eq 0 ]; then
    echo "install.sh: run this as the desktop user, not root/sudo -- it installs" >&2
    echo "into \$HOME/.local/share/nautilus/scripts for whoever runs it." >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SCRIPT_DIR/nautilus-ask-ai" "$DEST_DIR/$DEST_NAME"
chmod +x "$DEST_DIR/$DEST_NAME"

echo "Installed. Right-click any file in Nautilus (GNOME Files) -> Scripts -> \"$DEST_NAME\"."
echo "If Nautilus is already running, you may need to refresh (Ctrl+R) or restart it"
echo "for the new script to show up in the Scripts submenu."
echo
echo "Requires distro-ai-ask on PATH (the ISO symlinks it into /usr/local/bin; see"
echo "modes/ai/README.md) and a model loaded via 'distro-ai-model use <case>'."

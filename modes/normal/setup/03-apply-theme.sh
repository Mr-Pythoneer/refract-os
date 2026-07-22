#!/usr/bin/env bash
#
# Applies the WhiteSur GTK/icon/shell theme installed by
# 01-install-whitesur-theme.sh. Uses only well-documented, stable GNOME
# schemas (org.gnome.desktop.interface for GTK/icon theme,
# org.gnome.shell.extensions.user-theme for the shell theme via GNOME's own
# official "User Themes" extension).
#
# What this deliberately does NOT attempt: a literal macOS-style global
# app-menu in the top bar, or a Mission-Control-equivalent overview redesign.
# GNOME has no stable built-in equivalent to either — building those would
# mean picking and pinning a handful of third-party extensions whose APIs
# and even continued existence aren't something to commit to sight-unseen.
# That's real follow-up work for someone iterating against a live session,
# not something to fake here. The Activities overview (already in stock
# GNOME) is the closest existing equivalent and is left as-is.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, not root/sudo." >&2
    exit 1
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    echo "No DBUS_SESSION_BUS_ADDRESS — run this inside a real logged-in graphical session." >&2
    exit 1
fi

THEME_NAME="${1:-WhiteSur-Dark}"

sudo apt-get update
sudo apt-get install -y gnome-shell-extensions gnome-tweaks

if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions enable user-theme@gnome-shell-extensions.gcampax.github.com 2>/dev/null || \
        echo "NOTE: could not enable the User Themes extension automatically — enable it manually via gnome-tweaks > Extensions." >&2
fi

echo -e "\033[36mApplying theme: $THEME_NAME\033[0m"
gsettings set org.gnome.desktop.interface gtk-theme "$THEME_NAME"
# Dark icon variant to match the dark GTK theme + prefer-dark scheme, and to stay
# consistent with the system default (iso dconf/gschema) and every distro-modectl
# mode switch — all of which set 'WhiteSur-dark'. Bare 'WhiteSur' here made the
# first mode switch silently flip the icons.
gsettings set org.gnome.desktop.interface icon-theme "WhiteSur-dark"
gsettings set org.gnome.shell.extensions.user-theme name "$THEME_NAME" 2>/dev/null || \
    echo "NOTE: org.gnome.shell.extensions.user-theme schema not available — User Themes extension may need a session restart to register. Try again after logging out and back in." >&2

echo -e "\033[32mDone. If the theme name doesn't match what install.sh actually produced (check ~/.themes), re-run with the correct name as the first argument.\033[0m"

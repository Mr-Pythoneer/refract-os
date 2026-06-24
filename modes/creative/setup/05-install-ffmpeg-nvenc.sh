#!/usr/bin/env bash
#
# Ensures an NVENC/NVDEC-capable ffmpeg is available. Ubuntu's repo ffmpeg
# is typically NOT built with NVENC support (build-dependency/licensing
# reasons), so this checks the system ffmpeg first and, if it lacks nvenc,
# fetches BtbN's prebuilt static Linux build (github.com/BtbN/FFmpeg-Builds)
# which does include it — same "query latest GitHub release" pattern used
# elsewhere in this repo (see modes/ai/setup/01-install-llamacpp.sh).
#
# Usage: ./05-install-ffmpeg-nvenc.sh [install_dir]
#   install_dir defaults to /usr/local/bin (symlinked there, not overwriting
#   the system ffmpeg package).

set -euo pipefail

INSTALL_DIR="${1:-/usr/local/bin}"

if command -v ffmpeg >/dev/null 2>&1 && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q nvenc; then
    echo -e "\033[32mSystem ffmpeg already has NVENC support — nothing to do.\033[0m"
    ffmpeg -version | head -n1
    exit 0
fi

echo -e "\033[33mSystem ffmpeg lacks NVENC support (or isn't installed). Fetching BtbN's prebuilt NVENC-enabled build...\033[0m"

if ! command -v jq >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y jq
fi

RELEASE_JSON=$(curl -fsSL -H "User-Agent: distro-setup" "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest")
ASSET_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select(.name | test("linux64-gpl\\.tar\\.xz$")) | .browser_download_url' | head -n1)

if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
    echo "Could not find a linux64-gpl build in the latest release. Check https://github.com/BtbN/FFmpeg-Builds/releases manually." >&2
    exit 1
fi

TMP_DIR=$(mktemp -d)
TMP_FILE="$TMP_DIR/ffmpeg.tar.xz"
echo "Downloading $ASSET_URL ..."
curl -fL -o "$TMP_FILE" "$ASSET_URL"
tar -xJf "$TMP_FILE" -C "$TMP_DIR"

BIN_DIR=$(find "$TMP_DIR" -type d -name bin | head -n1)
sudo install -m 0755 "$BIN_DIR/ffmpeg" "$INSTALL_DIR/ffmpeg"
sudo install -m 0755 "$BIN_DIR/ffprobe" "$INSTALL_DIR/ffprobe"
rm -rf "$TMP_DIR"

hash -r
ffmpeg -hide_banner -encoders 2>/dev/null | grep nvenc || echo "WARNING: installed but nvenc encoders still not listed — check the GPU driver is installed (drivers/install-nvidia.sh)." >&2

echo -e "\033[32mDone: $("$INSTALL_DIR/ffmpeg" -version | head -n1)\033[0m"

#!/usr/bin/env bash
#
# Installs DXVK (D3D9/10/11 -> Vulkan) and VKD3D-Proton (D3D12 -> Vulkan) into
# a RAW Wine prefix — for non-Steam/non-Proton Windows apps run via plain Wine
# (Steam's Proton and Bottles already bundle their own copies, so you don't
# need this for those). Per DESIGN.md §2.
#
# Both are fetched from their latest GitHub release and integrity-checked
# against the per-asset SHA-256 the GitHub API publishes (these projects don't
# ship a separate checksum file — the API 'digest' field is the source).
# Verified against current upstream (2026-06): DXVK ships a .tar.gz and NO
# longer includes setup_dxvk.sh (removed since v2.4), so DXVK is installed
# manually (copy DLLs + register native overrides). VKD3D-Proton ships a
# zstd-compressed .tar.zst that DOES include setup_vkd3d_proton.sh.
#
# Usage: ./07-install-dxvk-vkd3d.sh <WINEPREFIX> [dxvk|vkd3d|both]
#   default component: both

set -euo pipefail

WINEPREFIX_ARG="${1:-}"
COMPONENT="${2:-both}"

if [ -z "$WINEPREFIX_ARG" ]; then
    echo "Usage: $(basename "$0") <WINEPREFIX> [dxvk|vkd3d|both]" >&2
    echo "  e.g. $(basename "$0") ~/.wine both" >&2
    exit 1
fi
export WINEPREFIX="$WINEPREFIX_ARG"

for t in curl jq tar; do
    command -v "$t" >/dev/null 2>&1 || { echo "Required tool missing: $t (sudo apt-get install -y curl jq tar)" >&2; exit 1; }
done
if ! command -v wine >/dev/null 2>&1; then
    echo "wine not found — run modes/gaming/setup/03-install-wine-staging.sh first." >&2
    exit 1
fi
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "WINEPREFIX '$WINEPREFIX' doesn't look initialized (no system.reg). Run 'WINEPREFIX=$WINEPREFIX wineboot -i' first." >&2
    exit 1
fi

# fetch_release_asset <repo> <name-regex> -> sets ASSET_URL, ASSET_NAME, ASSET_SHA256
fetch_release_asset() {
    local repo="$1" name_re="$2"
    local json
    json=$(curl -fsSL -H "User-Agent: distro-setup" "https://api.github.com/repos/$repo/releases/latest")
    ASSET_NAME=$(echo "$json" | jq -r --arg re "$name_re" '.assets[] | select(.name | test($re)) | .name' | head -n1)
    ASSET_URL=$(echo "$json" | jq -r --arg re "$name_re" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)
    # GitHub publishes a per-asset digest "sha256:<hex>"; strip the prefix.
    ASSET_SHA256=$(echo "$json" | jq -r --arg re "$name_re" '.assets[] | select(.name | test($re)) | .digest' | head -n1 | sed 's/^sha256://')
    [ -n "$ASSET_URL" ] && [ "$ASSET_URL" != "null" ] || { echo "No asset matching /$name_re/ in $repo latest release." >&2; return 1; }
}

# download_verify <url> <name> <sha256> <dest-dir> -> downloads + sha256 -c
download_verify() {
    local url="$1" name="$2" sha="$3" dir="$4"
    echo "Downloading $name ..."
    curl -fL -o "$dir/$name" "$url"
    if [ -n "$sha" ] && [ "$sha" != "null" ]; then
        echo "Verifying SHA-256 ..."
        ( cd "$dir" && printf '%s  %s\n' "$sha" "$name" | sha256sum -c - ) \
            || { echo "CHECKSUM MISMATCH for $name — refusing to install a corrupted/tampered download." >&2; return 1; }
    else
        echo "WARNING: no published SHA-256 for $name — installing UNVERIFIED." >&2
    fi
}

install_dxvk() {
    echo -e "\033[36m== DXVK ==\033[0m"
    fetch_release_asset "doitsujin/dxvk" 'dxvk-[0-9].*\\.tar\\.gz$'
    echo "Latest DXVK asset: $ASSET_NAME"
    local tmp; tmp=$(mktemp -d)
    download_verify "$ASSET_URL" "$ASSET_NAME" "$ASSET_SHA256" "$tmp"
    tar -xzf "$tmp/$ASSET_NAME" -C "$tmp"
    local src; src=$(find "$tmp" -maxdepth 1 -type d -name 'dxvk-*' | head -n1)

    # DXVK no longer ships setup_dxvk.sh — install manually, then register native
    # overrides. Layout depends on the prefix arch: a WoW64 (win64) prefix has
    # both system32 (64-bit) and syswow64 (32-bit); a pure win32 prefix has only
    # system32 (which holds the 32-bit DLLs). Presence of syswow64 is the test.
    local sys32="$WINEPREFIX/drive_c/windows/system32" syswow="$WINEPREFIX/drive_c/windows/syswow64"
    if [ -d "$syswow" ]; then
        cp "$src/x64/"*.dll "$sys32/"  2>/dev/null || echo "WARNING: could not copy 64-bit DXVK DLLs into $sys32" >&2
        cp "$src/x32/"*.dll "$syswow/" 2>/dev/null || echo "WARNING: could not copy 32-bit DXVK DLLs into $syswow" >&2
    else
        # Pure 32-bit prefix: the x32 DLLs go to system32; x64 DLLs don't apply.
        cp "$src/x32/"*.dll "$sys32/"  2>/dev/null || echo "WARNING: could not copy 32-bit DXVK DLLs into $sys32" >&2
    fi
    for dll in d3d8 d3d9 d3d10core d3d11 dxgi; do
        wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d native /f >/dev/null 2>&1 || \
            echo "WARNING: could not register override for $dll — set it manually in winecfg (Libraries -> $dll -> native)." >&2
    done
    rm -rf "$tmp"
    echo -e "\033[32mDXVK installed into $WINEPREFIX (overrides: d3d8/d3d9/d3d10core/d3d11/dxgi = native).\033[0m"
}

install_vkd3d() {
    echo -e "\033[36m== VKD3D-Proton ==\033[0m"
    fetch_release_asset "HansKristian-Work/vkd3d-proton" 'vkd3d-proton-[0-9].*\\.tar\\.zst$'
    echo "Latest VKD3D-Proton asset: $ASSET_NAME"
    local tmp; tmp=$(mktemp -d)
    download_verify "$ASSET_URL" "$ASSET_NAME" "$ASSET_SHA256" "$tmp"

    # .tar.zst needs zstd support: prefer 'tar --zstd', fall back to the zstd CLI.
    if tar --zstd -tf "$tmp/$ASSET_NAME" >/dev/null 2>&1; then
        tar --zstd -xf "$tmp/$ASSET_NAME" -C "$tmp"
    elif command -v zstd >/dev/null 2>&1; then
        zstd -d "$tmp/$ASSET_NAME" -o "$tmp/vkd3d.tar" && tar -xf "$tmp/vkd3d.tar" -C "$tmp"
    else
        echo "Cannot extract .tar.zst — install zstd: sudo apt-get install -y zstd" >&2
        rm -rf "$tmp"; return 1
    fi

    local src; src=$(find "$tmp" -maxdepth 1 -type d -name 'vkd3d-proton-*' | head -n1)
    # VKD3D-Proton DOES ship its own installer, which handles DLL placement +
    # the d3d12/d3d12core native overrides for us.
    ( cd "$src" && WINEPREFIX="$WINEPREFIX" ./setup_vkd3d_proton.sh install )
    rm -rf "$tmp"
    echo -e "\033[32mVKD3D-Proton installed into $WINEPREFIX (d3d12/d3d12core = native).\033[0m"
}

case "$COMPONENT" in
    dxvk)  install_dxvk ;;
    vkd3d) install_vkd3d ;;
    both)  install_dxvk; install_vkd3d ;;
    *) echo "Unknown component '$COMPONENT' (use dxvk|vkd3d|both)." >&2; exit 1 ;;
esac

echo -e "\033[32m\nDone. These translate DirectX -> Vulkan for apps run via plain Wine in this prefix.\033[0m"
echo "Note: needs a Vulkan-capable GPU + driver at runtime (drivers/install-nvidia.sh)."

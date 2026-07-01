#!/usr/bin/env bash
#
# Pre-flight check for Crucible OS — run this on the build host (the OVH
# server / the 5090 box) BEFORE the expensive `iso/build.sh`, so the first
# real build doesn't fail an hour in on something checkable in seconds.
#
# It is read-only and safe to re-run. Four sections:
#   1. Environment   — OS + required tools for the build paths
#   2. Static checks — bash -n / shellcheck / JSON / YAML across the repo
#   3. Network       — reachability of every external dep the setup scripts pull
#   4. apt packages  — existence on the host's configured repos (best-effort)
#
# Exit code: non-zero if any BLOCKING check fails (env/static). Network and
# apt checks are advisory (WARN) — they can fail transiently or because a
# repo/PPA isn't added yet — so they never fail the run on their own, but are
# printed loudly so you can eyeball them.
#
# Usage: ./preflight.sh [--build-iso | --build-cloud]
#   --build-iso    also require live-build (iso/build.sh path)        [default]
#   --build-cloud  also require debootstrap/parted/... (cloud-image path)

set -uo pipefail   # NOT -e: we want every check to run and tally, not abort

MODE="${1:---build-iso}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0 FAIL=0 WARN=0 SKIP=0

c_green=$'\033[32m'; c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_cyan=$'\033[36m'; c_reset=$'\033[0m'

ok()   { echo "${c_green}[ OK ]${c_reset} $1"; PASS=$((PASS+1)); }
bad()  { echo "${c_red}[FAIL]${c_reset} $1"; FAIL=$((FAIL+1)); }
warn() { echo "${c_yellow}[WARN]${c_reset} $1"; WARN=$((WARN+1)); }
skip() { echo "${c_cyan}[SKIP]${c_reset} $1"; SKIP=$((SKIP+1)); }
section() { echo; echo "${c_cyan}=== $1 ===${c_reset}"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 1. Environment
section "1. Environment"

IS_LINUX=false
if [ "$(uname)" = "Linux" ]; then IS_LINUX=true; ok "Running on Linux"; else
    warn "Not on Linux ($(uname)) — the build itself can't run here; only static + network checks are meaningful"
fi

for t in bash git curl; do
    if have "$t"; then ok "found: $t"; else bad "missing required tool: $t"; fi
done

if [ "$MODE" = "--build-cloud" ]; then
    for t in debootstrap parted mkfs.ext4 losetup partprobe grub-install qemu-img; do
        if have "$t"; then ok "found (cloud-image): $t"
        elif $IS_LINUX; then bad "missing (cloud-image): $t — apt install debootstrap parted e2fsprogs util-linux grub-pc-bin qemu-utils"
        else skip "cloud-image tool $t (not on Linux)"; fi
    done
else
    if have lb; then ok "found: live-build (lb)"
    elif $IS_LINUX; then bad "missing: live-build — sudo apt install live-build"
    else skip "live-build (not on Linux)"; fi
fi

# ---------------------------------------------------------------- 2. Static checks
section "2. Static checks (repo integrity)"

# Discover bash scripts by shebang (same mechanism as the CI workflow).
mapfile -t BASH_FILES < <(grep -rl '^#!/usr/bin/env bash' "$REPO_ROOT" 2>/dev/null | grep -v '/\.git/')
mapfile -t SH_FILES   < <(grep -rl '^#!/bin/sh'         "$REPO_ROOT" 2>/dev/null | grep -v '/\.git/')

synfail=0
for f in "${BASH_FILES[@]}"; do bash -n "$f" 2>/dev/null || { synfail=$((synfail+1)); echo "  syntax error: $f"; }; done
for f in "${SH_FILES[@]}";   do sh   -n "$f" 2>/dev/null || { synfail=$((synfail+1)); echo "  syntax error: $f"; }; done
if [ "$synfail" -eq 0 ]; then ok "bash -n / sh -n clean across ${#BASH_FILES[@]} bash + ${#SH_FILES[@]} sh scripts"
else bad "$synfail script(s) failed syntax check"; fi

if have shellcheck; then
    if shellcheck -S warning "${BASH_FILES[@]}" >/dev/null 2>&1; then ok "shellcheck clean (-S warning)"
    else bad "shellcheck reported warnings/errors — run: shellcheck -S warning <files>"; fi
else
    warn "shellcheck not installed — skipping (apt install shellcheck for the full static pass)"
fi

if have python3; then
    jbad=0
    while IFS= read -r jf; do
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$jf" 2>/dev/null || { jbad=$((jbad+1)); echo "  invalid JSON: $jf"; }
    done < <(find "$REPO_ROOT" -name '*.json' -not -path '*/.git/*')
    [ "$jbad" -eq 0 ] && ok "all JSON files parse" || bad "$jbad JSON file(s) invalid"

    if python3 -c "import yaml" 2>/dev/null; then
        ybad=0
        while IFS= read -r yf; do
            python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$yf" 2>/dev/null || { ybad=$((ybad+1)); echo "  invalid YAML: $yf"; }
        done < <(find "$REPO_ROOT/iso/calamares" \( -name '*.conf' -o -name '*.desc' \) 2>/dev/null; find "$REPO_ROOT/.github" -name '*.yml' 2>/dev/null)
        [ "$ybad" -eq 0 ] && ok "all Calamares/workflow YAML parses" || bad "$ybad YAML file(s) invalid"
    else
        warn "python3 yaml module not available — skipping YAML validation (pip install pyyaml)"
    fi
else
    warn "python3 not found — skipping JSON/YAML validation"
fi

# Key repo files exist
for f in iso/build.sh iso/config/package-lists/base.list.chroot \
         iso/strains/workstation.list.chroot drivers/install-nvidia.sh \
         modes/modectl/distro-modectl; do
    [ -f "$REPO_ROOT/$f" ] && ok "present: $f" || bad "missing expected file: $f"
done

# ---------------------------------------------------------------- 3. Network
section "3. Network reachability (external deps — advisory)"

url_ok() {  # url_ok "<label>" "<url>"
    if curl -fsSL --max-time 20 -o /dev/null "$2" 2>/dev/null; then ok "reachable: $1"
    else warn "unreachable (transient? or moved?): $1 -> $2"; fi
}

if have curl; then
    url_ok "WineHQ noble .sources"     "https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources"
    url_ok "WineHQ signing key"        "https://dl.winehq.org/wine-builds/winehq.key"
    url_ok "GE-Proton latest release"  "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
    url_ok "BtbN FFmpeg latest release" "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest"
    url_ok "Netdata kickstart"         "https://get.netdata.cloud/kickstart.sh"
    url_ok "Docker noble repo"         "https://download.docker.com/linux/ubuntu/dists/noble/Release"
    url_ok "CUDA keyring (ubuntu2404)" "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"
    url_ok "Flathub repo file"         "https://flathub.org/repo/flathub.flatpakrepo"
    url_ok "Flatpak: FreeCAD"          "https://flathub.org/api/v2/appstream/org.freecad.FreeCAD"
    url_ok "Flatpak: Blender"          "https://flathub.org/api/v2/appstream/org.blender.Blender"
    url_ok "Flatpak: Kdenlive"         "https://flathub.org/api/v2/appstream/org.kde.kdenlive"
    url_ok "Flatpak: Bottles"          "https://flathub.org/api/v2/appstream/com.usebottles.bottles"
    # AI mode (LM Studio + ComfyUI) deps
    url_ok "LM Studio installer"       "https://lmstudio.ai/install.sh"
    url_ok "ComfyUI repo"              "https://github.com/comfyanonymous/ComfyUI"
    url_ok "PyTorch cu130 index"       "https://download.pytorch.org/whl/cu130"
    url_ok "HF: Qwen2.5-Coder-32B"     "https://huggingface.co/api/models/lmstudio-community/Qwen2.5-Coder-32B-Instruct-GGUF"
    url_ok "HF: Qwen2.5-VL-32B"        "https://huggingface.co/api/models/lmstudio-community/Qwen2.5-VL-32B-Instruct-GGUF"
    url_ok "HF: SDXL base"             "https://huggingface.co/api/models/stabilityai/stable-diffusion-xl-base-1.0"
else
    skip "network checks (curl missing)"
fi

# ---------------------------------------------------------------- 4. apt packages
section "4. apt package existence (host repos — best-effort)"

if $IS_LINUX && have apt-cache; then
    apt_pkg() {  # apt_pkg "<pkg>"
        local cand
        cand="$(apt-cache policy "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2}')"
        if [ -n "$cand" ] && [ "$cand" != "(none)" ]; then ok "apt: $1 ($cand)"
        else warn "apt: $1 not found in configured repos (enable universe/multiverse, or the package's own repo isn't added yet)"; fi
    }
    for p in ubuntu-desktop-minimal lubuntu-desktop calamares live-build \
             steam-installer gamemode mangohud winetricks lutris \
             amd64-microcode power-profiles-daemon mokutil \
             linux-tools-common linux-tools-generic-hwe-24.04 \
             ubuntu-drivers-common flatpak; do
        apt_pkg "$p"
    done
    note="docker-ce / nvidia-driver-*-open / cuda-toolkit-* / winehq-staging need their own repo or PPA added first — not checked here"
    echo "  (note: $note)"
else
    skip "apt package checks (need a Linux host with apt-cache)"
fi

# ---------------------------------------------------------------- Summary
section "Summary"
echo "${c_green}$PASS passed${c_reset}, ${c_red}$FAIL failed${c_reset}, ${c_yellow}$WARN warnings${c_reset}, ${c_cyan}$SKIP skipped${c_reset}"
if [ "$FAIL" -gt 0 ]; then
    echo "${c_red}Blocking checks failed — fix these before running iso/build.sh.${c_reset}"
    exit 1
fi
echo "${c_green}No blocking failures. Review any WARNs above, then proceed to iso/build.sh.${c_reset}"
exit 0

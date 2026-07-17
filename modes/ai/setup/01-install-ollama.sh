#!/usr/bin/env bash
#
# Installs Ollama as AI mode's default local-LLM runtime. Replaces LM Studio.
#
# WHY OLLAMA, NOT LM STUDIO: LM Studio is proprietary and its App Terms forbid
# redistribution ("distribute, sell... or otherwise transfer the Software"). A
# distro cannot legally ship it, and the exact piece AI mode depended on -- the
# headless `llmster` daemon -- is the closed part (only the `lms` CLI is MIT).
# Ollama is MIT: we can vendor, pin, and ship it inside the ISO. Both wrap the
# same llama.cpp core, so tokens/sec are ~identical -- the win is licensing,
# footprint (no Electron), and a native systemd daemon.
#
# INSTALL METHOD: the pinned tarball, NOT `curl https://ollama.com/install.sh|sh`
# (unpinned network install is not reproducible for an ISO build) and NOT
# `apt install ollama` (no such package in noble). We create the `ollama` system
# user + a Refract-owned unit ourselves instead of letting install.sh do it, so
# the daemon config is ours.
#
# INTEL ARC (the X1 Carbon target): Ollama has NO Intel/SYCL/NPU support. The
# only in-tree path to the Arc 140V iGPU is the Vulkan backend, which is opt-in
# via OLLAMA_VULKAN=1 (set in the systemd drop-in, not here) and needs the
# Vulkan userspace shipped by the laptop strain (mesa-vulkan-drivers etc.). This
# script installs the runtime; distro-ai-detect-tier decides whether the Arc is
# actually usable (real device vs llvmpipe) at runtime.
#
# Usage: sudo ./01-install-ollama.sh          (needs root: creates a system user + unit)

set -euo pipefail

# Pin the version for a reproducible image. Bump deliberately, not via `latest`.
OLLAMA_VERSION="${OLLAMA_VERSION:-0.32.0}"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  TARBALL="ollama-linux-amd64.tar.zst" ;;
    aarch64) TARBALL="ollama-linux-arm64.tar.zst" ;;
    *) echo "Unsupported arch '$ARCH' — Ollama ships amd64/arm64 only." >&2; exit 1 ;;
esac
# NOTE: the plain amd64 tarball WITHOUT the -rocm add-on is used on purpose. The
# ROCm runner bundle is multi-GB dead weight on an Intel-only laptop; the amd64
# tarball already carries the CUDA runners the 5090 desktop path needs.

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo — this creates the 'ollama' system user and installs a systemd unit." >&2
    exit 1
fi

if command -v ollama >/dev/null 2>&1; then
    echo "Ollama already installed: $(ollama --version 2>/dev/null || true)"
else
    echo -e "\033[36mInstalling Ollama ${OLLAMA_VERSION} (pinned tarball) into /usr...\033[0m"
    # Pinned tarballs live on the GitHub RELEASE, not on ollama.com. This was
    # "https://ollama.com/download/v${OLLAMA_VERSION}/${TARBALL}" -- GitHub's
    # path shape pattern-matched onto ollama.com -- which 404s, so this script
    # could never install Ollama on any machine. ollama.com/download/<file>
    # (no version segment) 307-redirects and works, but is UNPINNED; the
    # release URL is both correct and pinned, which is what an ISO needs.
    url="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/${TARBALL}"
    # Fail loudly if the pinned version/tarball 404s rather than shipping nothing.
    curl -fsSL "$url" | tar -x --use-compress-program=unzstd -C /usr \
        || { echo "Download/extract failed for $url" >&2; exit 1; }
fi

# System user + groups, mirroring upstream install.sh so behaviour matches docs.
# render+video = GPU device access (needed for the Arc Vulkan path).
if ! id ollama >/dev/null 2>&1; then
    useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
fi
for grp in render video; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" ollama || true
done
# Add the invoking (sudo) user to the ollama group so the `ollama` CLI reaches
# the service's socket/model store without sudo.
if [ -n "${SUDO_USER:-}" ]; then usermod -aG ollama "$SUDO_USER" || true; fi

# Install Refract's unit (see modes/ai/systemd/). Per-machine defaults like
# OLLAMA_VULKAN=1 get injected as a drop-in by distro-ai-detect-tier, not here.
UNIT_SRC="$(dirname "$0")/../systemd/ollama.service"
if [ -f "$UNIT_SRC" ]; then
    install -m 0644 "$UNIT_SRC" /etc/systemd/system/ollama.service
    systemctl daemon-reload
    systemctl enable --now ollama.service || echo "NOTE: could not start ollama.service now (fine in a chroot/build)." >&2
fi

echo -e "\033[32m\nOllama installed.\033[0m API on http://127.0.0.1:11434 (OpenAI-compatible at /v1)."
echo "Next:"
echo "  distro-ai-detect-tier            # decides your tier (probes the Arc iGPU / Nvidia / RAM)"
echo "  ./02-preload-models.sh           # pull the tier-matched default model"
echo "  distro-ai-model use coding       # switch the loaded model by use-case"

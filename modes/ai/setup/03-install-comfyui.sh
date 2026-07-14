#!/usr/bin/env bash
#
# Installs ComfyUI for AI mode's IMAGE GENERATION (FLUX / SDXL). This is a
# SEPARATE runtime from LM Studio — LM Studio is an LLM/text+vision server and
# cannot run diffusion models. ComfyUI serves its own web UI + API on port 8188.
#
# Installs the PyTorch CUDA wheel for the RTX 5090: Blackwell (sm_120) REQUIRES
# a CUDA 12.8+ torch build. We use the stable cu130 index (what ComfyUI's own
# docs recommend in 2026); cu126 and older will NOT work on a 5090.
#
# Run as the desktop user, NOT root (installs into a per-user venv).
#
# Usage: ./03-install-comfyui.sh [install_dir]   (default: ~/ComfyUI)

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, not root (ComfyUI installs into a per-user venv)." >&2
    exit 1
fi

INSTALL_DIR="${1:-$HOME/ComfyUI}"

for t in git python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "Required tool missing: $t (sudo apt-get install -y git python3 python3-venv)" >&2; exit 1; }
done
python3 -c 'import venv' 2>/dev/null || { echo "python3-venv missing: sudo apt-get install -y python3-venv" >&2; exit 1; }

if [ -d "$INSTALL_DIR/.git" ]; then
    echo -e "\033[36mUpdating existing ComfyUI checkout...\033[0m"
    git -C "$INSTALL_DIR" pull --ff-only || echo "NOTE: git pull failed — continuing with the existing checkout." >&2
else
    echo -e "\033[36mCloning ComfyUI...\033[0m"
    git clone https://github.com/comfyanonymous/ComfyUI.git "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
if [ ! -d venv ]; then
    echo -e "\033[36mCreating Python venv...\033[0m"
    python3 -m venv venv
fi
# shellcheck disable=SC1091
source venv/bin/activate
pip install --upgrade pip

echo -e "\033[36mInstalling PyTorch (CUDA cu130 — required for Blackwell/RTX 5090 sm_120)...\033[0m"
# cu130 stable supports sm_120; cu128 is the floor; cu126/older fail on a 5090.
# Do NOT add xformers on Blackwell — ComfyUI uses PyTorch SDPA and doesn't need it.
# --index-url (NOT --extra-index-url): the CUDA index must be the ONLY source for
# torch, else pip is free to resolve the CPU-only torch wheel from PyPI and leave
# torch.cuda.is_available() False on Blackwell (the exact failure we're avoiding).
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130

echo -e "\033[36mInstalling ComfyUI requirements...\033[0m"
pip install -r requirements.txt

# Create the model dirs the downloader populates.
mkdir -p models/checkpoints models/diffusion_models models/text_encoders models/vae

cat <<EOF

$(printf '\033[32mComfyUI installed at %s\033[0m' "$INSTALL_DIR")

Next:
  ./04-download-image-models.sh "$INSTALL_DIR"   # FLUX.1-schnell (no token) + SDXL
  distro-ai-image                                 # start ComfyUI + open the web UI (port 8188)

If 'torch.cuda.is_available()' is False after install, your Nvidia driver/CUDA
is too old for Blackwell — see drivers/install-nvidia.sh + docs/blackwell-readiness.md.
EOF

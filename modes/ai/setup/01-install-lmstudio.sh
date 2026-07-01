#!/usr/bin/env bash
#
# Installs LM Studio's headless engine + `lms` CLI on Linux. This replaces the
# legacy Crucible12 (llama.cpp + OpenCode) runtime as AI mode's default — see
# DESIGN.md §5 and modes/ai/legacy-crucible12/ for the original.
#
# Uses LM Studio's OFFICIAL headless installer (curl | bash from lmstudio.ai),
# which fetches the `llmster` daemon + `lms` CLI into ~/.lmstudio/bin and does
# NOT require the GUI to ever run. We download from LM Studio's own channel
# rather than re-hosting any binary — LM Studio's terms prohibit redistributing
# the binary, but each user pulling it from the official installer (and
# accepting the EULA themselves) is fine. LM Studio is free for personal AND
# commercial use as of mid-2025.
#
# Requirements: LM Studio's llmster installer wants an Nvidia driver >= 550 and
# CUDA 12 in general — BUT the RTX 5090 (Blackwell) specifically needs the
# >=570 OPEN driver (nvidia-driver-<v>-open); the 550 branch doesn't support the
# 5090 at all. Install that first: drivers/install-nvidia.sh + docs/blackwell-readiness.md.
# Run as the normal desktop user, NOT root — LM Studio installs per-user into ~/.lmstudio.
#
# Usage: ./01-install-lmstudio.sh

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, not root — LM Studio installs into ~/.lmstudio for the invoking user." >&2
    exit 1
fi

LMS="$HOME/.lmstudio/bin/lms"

if [ -x "$LMS" ]; then
    echo "LM Studio CLI already present at $LMS"
else
    echo -e "\033[36mInstalling LM Studio (headless llmster + lms CLI) from the official installer...\033[0m"
    echo "This pulls llmster binaries from llmster.lmstudio.ai (SHA-512 verified by the installer)."
    # The official headless install path. It bootstraps llmster and offers to
    # add ~/.lmstudio/bin to PATH.
    curl -fsSL https://lmstudio.ai/install.sh | bash
fi

if [ ! -x "$LMS" ]; then
    echo "LM Studio install finished but $LMS not found. Check the installer output above." >&2
    echo "Fallback: install the GUI AppImage from https://lmstudio.ai/download, run it once, then: ~/.lmstudio/bin/lms bootstrap" >&2
    exit 1
fi

# Make lms reachable in THIS shell (PATH edits from the installer only apply to
# new shells). Scripts/systemd should call the absolute path anyway.
export PATH="$HOME/.lmstudio/bin:$PATH"

echo -e "\033[36mBringing up the llmster daemon...\033[0m"
"$LMS" daemon up || echo "NOTE: 'lms daemon up' returned nonzero — it may already be running." >&2

echo -e "\033[32m\nLM Studio CLI installed: $("$LMS" version 2>/dev/null || echo "$LMS")\033[0m"
echo "Next:"
echo "  ./02-preload-models.sh           # download the model catalog (~150GB of LLMs — see the warning it prints)"
echo "  distro-ai-model server start     # start the OpenAI-compatible server on port 8080"
echo "  distro-ai-model use coding       # load the best coding model"
echo
echo "Add ~/.lmstudio/bin to your PATH if the installer didn't (open a new terminal first):"
echo "  echo 'export PATH=\"\$HOME/.lmstudio/bin:\$PATH\"' >> ~/.bashrc"

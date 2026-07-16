#!/usr/bin/env bash
# Tests for modes/ai/bin/distro-ai-setup (the one-command AI-mode front door).
# Hermetic: builds a fake bin/ + setup/ layout with a STUB distro-ai-detect-tier
# and stub setup scripts that only echo markers, so nothing installs or downloads
# and no real GPU/Ollama is touched. Config goes to a throwaway XDG_CONFIG_HOME.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETUP_SRC="$REPO_ROOT/modes/ai/bin/distro-ai-setup"

# make_env <detect-exit-code> [image] -> prints the fake root dir
make_env() {
  local rc="$1" image="${2:-flux-dev}" root
  root="$(new_stubdir)"
  mkdir -p "$root/ai/bin" "$root/ai/setup" "$root/cfg/refract-ai"
  cp "$SETUP_SRC" "$root/ai/bin/distro-ai-setup"; chmod +x "$root/ai/bin/distro-ai-setup"
  { printf '#!/usr/bin/env bash\n'
    printf 'printf "ultra\\n" > "$XDG_CONFIG_HOME/refract-ai/tier"\n'
    printf 'printf "%s\\n" > "$XDG_CONFIG_HOME/refract-ai/image"\n' "$image"
    printf 'echo "[detect stub]"; exit %s\n' "$rc"
  } > "$root/ai/bin/distro-ai-detect-tier"; chmod +x "$root/ai/bin/distro-ai-detect-tier"
  local s
  for s in 01-install-ollama 02-preload-models 03-install-comfyui 04-download-image-models; do
    { printf '#!/usr/bin/env bash\n'; printf 'echo "RAN %s $*"\n' "$s"; } > "$root/ai/setup/$s.sh"
    chmod +x "$root/ai/setup/$s.sh"
  done
  # sudo passthrough: distro-ai-setup --install re-execs the (root-only) Ollama
  # installer via sudo. Stub sudo to just run the target (dropping leading flags
  # like --preserve-env=... and VAR=val env args) so the test exercises the real
  # dispatch without needing actual root.
  mkdir -p "$root/binstub"
  { printf '#!/usr/bin/env bash\n'
    printf 'while [ $# -gt 0 ]; do case "$1" in -*|*=*) shift;; *) break;; esac; done\n'
    printf 'exec "$@"\n'
  } > "$root/binstub/sudo"; chmod +x "$root/binstub/sudo"
  echo "$root"
}
run_setup() { local root="$1"; shift; PATH="$root/binstub:$PATH" XDG_CONFIG_HOME="$root/cfg" "$root/ai/bin/distro-ai-setup" "$@"; }

# --- guided (no --install): prints the plan, runs NOTHING ---
root="$(make_env 0 flux-dev)"
out="$(run_setup "$root" --yes 2>&1)"; rc=$?
assert_eq "guided exits 0" "0" "$rc"
assert_contains "guided reports the detected tier" "$out" "'ultra' tier"
assert_contains "guided lists the Ollama install step" "$out" "01-install-ollama.sh"
assert_contains "guided lists the preload step" "$out" "02-preload-models.sh"
assert_contains "guided lists the image step (flux-dev)" "$out" "04-download-image-models.sh --from-config"
assert_not_contains "guided runs no setup script" "$out" "RAN 01-install"
rm -rf "$root"

# --- --install: runs the setup scripts in order, incl. image (flux-dev) ---
root="$(make_env 0 flux-dev)"
out="$(run_setup "$root" --install --yes 2>&1)"; rc=$?
assert_eq "--install exits 0" "0" "$rc"
assert_contains "--install runs Ollama install" "$out" "RAN 01-install-ollama"
assert_contains "--install runs preload" "$out" "RAN 02-preload-models"
assert_contains "--install runs ComfyUI install" "$out" "RAN 03-install-comfyui"
assert_contains "--install runs image download --from-config" "$out" "RAN 04-download-image-models --from-config"
rm -rf "$root"

# --- --install with image=none: skips ComfyUI + image download ---
root="$(make_env 0 none)"
out="$(run_setup "$root" --install --yes 2>&1)"; rc=$?
assert_eq "--install (image none) exits 0" "0" "$rc"
assert_contains "--install (image none) still preloads LLMs" "$out" "RAN 02-preload-models"
assert_not_contains "--install (image none) skips ComfyUI" "$out" "RAN 03-install-comfyui"
assert_not_contains "--install (image none) skips image download" "$out" "RAN 04-download"
assert_contains "--install (image none) says skipped" "$out" "skipped"
rm -rf "$root"

# --- guided with image=none: plan omits the image steps ---
root="$(make_env 0 none)"
out="$(run_setup "$root" --yes 2>&1)"
assert_not_contains "guided (image none) omits ComfyUI step" "$out" "03-install-comfyui.sh"
rm -rf "$root"

# --- datacenter guard: detect-tier exits 3 -> setup exits 3, routes to Server mode ---
root="$(make_env 3 flux-dev)"
out="$(run_setup "$root" --install --yes 2>&1)"; rc=$?
assert_eq "detect exit 3 -> setup exits 3" "3" "$rc"
assert_contains "detect exit 3 mentions Server mode" "$out" "Server mode"
assert_not_contains "detect exit 3 runs no install" "$out" "RAN 01-install"
rm -rf "$root"

# --- detect-tier hard failure (exit 1) -> setup aborts non-zero before installing ---
root="$(make_env 1 flux-dev)"
out="$(run_setup "$root" --install --yes 2>&1)"; rc=$?
assert_eq "detect exit 1 -> setup exits 1" "1" "$rc"
assert_not_contains "detect exit 1 runs no install" "$out" "RAN 01-install"
rm -rf "$root"

finish

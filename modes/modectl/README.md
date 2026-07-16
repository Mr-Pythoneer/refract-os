# distro-modectl — the mode-switcher

The actual mechanism behind DESIGN.md §4's 5 modes. One base system, one script, five profile files — not five OS images.

## What's real in this first pass

- CPU governor switching (`cpupower frequency-set -g <governor>`)
- Power profile switching (`powerprofilesctl set <profile>`)
- Per-mode systemd service enable/disable (checks the unit exists first, warns instead of failing if it doesn't)
- Wiring into AI mode: on entering AI mode it loads the Ollama model for the profile's `AI_AUTOSTART_USECASE` (default `coding`) via `distro-ai-model`; leaving to another mode (`STOP_AI_MODEL=true`) unloads it to free VRAM. This runs as the user (distro-ai-model config is per-user), before the sudo re-exec — see `modes/ai/`.
- A safety prompt before disabling a display manager (gdm/sddm/lightdm) in Server mode, since that can kill an active desktop session — this is exactly the kind of disruptive action that shouldn't happen silently
- Best-effort `PINNED_APPS` dock-pinning via GNOME's `gsettings favorite-apps` (runs pre-sudo, needs the user's own session bus)

## What's explicitly NOT done yet, and why

- **Normal mode's macOS-style shell** (theme, dock position, top bar) IS now built — see `modes/normal/` — but deliberately as **one-time setup scripts**, not something `distro-modectl switch normal` re-applies on every switch. Cosmetic theming isn't a thing you toggle per-session the way a CPU governor is; there's no `DE_DCONF_FILE` field anymore because that was a stub that never actually became a per-switch concept once the real implementation landed. A true macOS-style global app-menu / Mission-Control-equivalent overview is still NOT attempted (see `modes/normal/README.md`) — GNOME has no stable built-in equivalent, and picking third-party extensions for it sight-unseen isn't something to commit to without a live session to verify against.
- **Creative mode's color-managed display profile**: now **scaffolded** as `modes/creative/bin/distro-creative-color` (colord/colormgr) — still monitor-specific (needs the real panel's measured ICC profile + a connected display + colord), so it's a correct parameterized scaffold, not headless-verifiable.
- **GPU performance-state pinning**: now **wired in** as `apply_gpu_perf` (driven by each profile's `GPU_PERF=max|auto`). It uses `nvidia-smi` persistence + clock-lock (headless/Wayland-safe) and additionally `nvidia-settings GpuPowerMizerMode` when an X DISPLAY is present — Gaming/Creative pin max, the others reset to adaptive. Web-verified command set (nvidia-smi man page / NVIDIA forums) but **unverified on real hardware** — no GPU yet. `apply_gpu_perf` no-ops cleanly when `nvidia-smi` is absent.

These aren't guesses dressed up as working code — the README says exactly where the gaps are so nothing here gets mistaken for verified.

## Usage (once installed on a real machine)

```bash
sudo mkdir -p /opt/distro-modectl && sudo cp -r modes/modectl/* /opt/distro-modectl/
sudo ln -sf /opt/distro-modectl/distro-modectl /usr/local/bin/distro-modectl

distro-modectl switch gaming
distro-modectl switch ai       # also loads the 'coding' Ollama model via distro-ai-model
distro-modectl switch server   # will prompt before disabling the display manager
distro-modectl status
```

## Verification checklist (blocked the same way as modes/ai/ — no test machine yet)

- [ ] `cpupower`/`powerprofilesctl` calls actually change state on real hardware (need a non-Mac Linux box at minimum — doesn't require the GPU server specifically, any Ubuntu machine/VM works for this part)
- [ ] Service enable/disable doesn't fight with systemd defaults on a stock Ubuntu install
- [ ] AI mode handoff: leaving AI mode (`STOP_AI_MODEL=true`) unloads the Ollama model so another mode gets the VRAM (`distro-ai-model unload`)
- [x] Display-manager confirmation prompt non-interactive behavior — fixed: `switch <mode> --yes` auto-confirms, and without `--yes` on a non-TTY stdin the script now refuses and exits instead of hanging on `read`. Still needs a real run to confirm the `-t 0` TTY check behaves as expected under whatever actually calls this (cron, a GUI helper, etc.).

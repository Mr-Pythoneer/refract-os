# distro-modectl — the mode-switcher

The actual mechanism behind DESIGN.md §4's 5 modes. One base system, one script, five profile files — not five OS images.

## What's real in this first pass

- CPU governor switching (`cpupower frequency-set -g <governor>`)
- Power profile switching (`powerprofilesctl set <profile>`)
- Per-mode systemd service enable/disable (checks the unit exists first, warns instead of failing if it doesn't)
- Wiring into AI mode: stops the running Crucible12 preset when leaving AI mode, starts the configured preset when entering it, via `distro-ai-preset` (see `modes/ai/`)
- A safety prompt before disabling a display manager (gdm/sddm/lightdm) in Server mode, since that can kill an active desktop session — this is exactly the kind of disruptive action that shouldn't happen silently

## What's explicitly NOT done yet, and why

- **Normal mode's macOS-style shell** (dock, top bar, Mission Control-style overview): this is a GNOME extension install + dconf configuration job, not a power/service toggle. Building it requires iterating against a real running GNOME session to check it actually looks/behaves right — not something to fabricate blind in a script with no desktop to test on. Stubbed as a `DE_DCONF_FILE` hook in each profile for now.
- **Creative mode's color-managed display profile**: monitor-specific (depends on the actual panel's ICC profile), can't be meaningfully implemented without a real display attached.
- **GPU performance-state pinning beyond `power-profiles-daemon`**: `nvidia-settings`/PRIME-style per-GPU power state control needs a real Nvidia GPU + driver to test against (same hardware-availability gap as `modes/ai/`).

These aren't guesses dressed up as working code — the README says exactly where the gaps are so nothing here gets mistaken for verified.

## Usage (once installed on a real machine)

```bash
sudo mkdir -p /opt/distro-modectl && sudo cp -r modes/modectl/* /opt/distro-modectl/
sudo ln -sf /opt/distro-modectl/distro-modectl /usr/local/bin/distro-modectl

distro-modectl switch gaming
distro-modectl switch ai       # also starts the 'crucible' preset via distro-ai-preset
distro-modectl switch server   # will prompt before disabling the display manager
distro-modectl status
```

## Verification checklist (blocked the same way as modes/ai/ — no test machine yet)

- [ ] `cpupower`/`powerprofilesctl` calls actually change state on real hardware (need a non-Mac Linux box at minimum — doesn't require the GPU server specifically, any Ubuntu machine/VM works for this part)
- [ ] Service enable/disable doesn't fight with systemd defaults on a stock Ubuntu install
- [ ] AI mode handoff: switching away from AI mode actually frees the GPU before another mode tries to use it (race condition risk if `distro-ai-preset stop` returns before `llama-server` fully releases VRAM)
- [x] Display-manager confirmation prompt non-interactive behavior — fixed: `switch <mode> --yes` auto-confirms, and without `--yes` on a non-TTY stdin the script now refuses and exits instead of hanging on `read`. Still needs a real run to confirm the `-t 0` TTY check behaves as expected under whatever actually calls this (cron, a GUI helper, etc.).

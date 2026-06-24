# Project TODO — full framework

Living checklist for the whole distro. Organized by the same structure as `DESIGN.md`. Check items off as they're built; every item should eventually link to the file/dir that implements it. Items marked **(needs hardware)** can't be verified until the GPU server exists (~3 months out, see `modes/ai/README.md`) or a generic test VM/box is available; items marked **(needs live desktop)** need an actual running GNOME session to build/verify against, not just a remote shell.

## 0. Foundation

- [x] Architecture plan (`DESIGN.md`)
- [x] Repo scaffolding, disk-as-cache workflow established
- [ ] Pick/reserve a distro name (currently unnamed — repo is `custom-linux-distro` as a placeholder)
- [ ] LICENSE for the distro project itself (currently has none — Crucible12's MIT license doesn't automatically cover this repo)

## 1. Base system

- [ ] Ubuntu 24.04 LTS base image pinned (specific point release to build from)
- [ ] HWE kernel + Mesa backport PPA selection finalized and documented
- [ ] Base package list (minimal install + the tools every mode needs: `curl`, `jq`, `git`, `cpupower`, `power-profiles-daemon`)

## 2. Drivers (§3) — `drivers/`

- [x] Design doc section written
- [x] Nvidia proprietary driver install script
- [x] Secure Boot MOK signing flow (documented/guided, not silently automated — see `drivers/install-nvidia.sh`)
- [x] AMD CPU microcode package install/verification script
- [x] Driver verification script (confirm `nvidia-smi` works, confirm microcode loaded via `dmesg`/`journalctl`)
- [ ] **(needs hardware)** end-to-end test on a real Nvidia GPU + AMD CPU box

## 3. AI mode (§5) — `modes/ai/`

- [x] Bash port of all Crucible12 setup/run/benchmark scripts
- [x] systemd unit template (`crucible12@.service`)
- [x] `distro-ai-preset` control script
- [x] OpenCode configs carried over
- [ ] **(needs hardware)** build verification: `01-install-llamacpp.sh` actually compiles against real CUDA toolkit
- [ ] **(needs hardware)** each preset starts cleanly, GPU utilization confirmed via `benchmark.sh`
- [ ] **(needs hardware)** systemd unit permissions/ownership under the `crucible12` service user
- [ ] **(needs hardware)** preset-switch handoff doesn't race on port 8080 / VRAM release
- [ ] Global hotkey assistant overlay (thin client hitting `localhost:8080`) — **(needs live desktop)**
- [ ] File-manager "ask AI about this file" context menu action — **(needs live desktop)**
- [ ] Optional Claude-cloud fallback toggle (explicit opt-in, OpenClaw-style gateway pattern)

## 4. Mode-switcher (§4) — `modes/modectl/`

- [x] `distro-modectl switch <mode>` — CPU governor, power profile, service toggling
- [x] Wired into `distro-ai-preset`
- [x] Display-manager-disable confirmation safety + `--yes` flag for non-interactive use
- [x] Best-effort `PINNED_APPS` dock-pinning via `gsettings` (GNOME-only, runs pre-sudo so it has the user's session bus; desktop-file IDs unverified)
- [ ] **(needs hardware/VM)** verify `cpupower`/`powerprofilesctl` calls on a real (non-Mac) Linux box — this part doesn't need the GPU server specifically
- [ ] **(needs hardware/VM)** verify service enable/disable doesn't fight stock Ubuntu defaults
- [ ] GPU performance-state pinning beyond `power-profiles-daemon` (`nvidia-settings`/PRIME) — **(needs hardware)**

## 5. Gaming mode — `modes/gaming/`

- [x] Proton-GE install/update script (latest GitHub release, auto-fetched)
- [x] Wine-staging install (WineHQ repo, with fallback if codename unsupported yet)
- [x] Bottles install (Flatpak/Flathub, GUI front-end so most users never touch raw `wine`)
- [x] GameMode + MangoHud install (per-launch, not system services)
- [x] winetricks bundled (via wine-staging script)
- [x] Steam + Lutris install scripts
- [x] verify-gaming.sh sanity check
- [ ] DXVK + VKD3D-Proton standalone install for raw Wine prefixes outside Bottles/Proton-GE (low priority — both already bundle their own)
- [ ] Curated compatibility-fix database for known-troublesome apps (Lutris-install-script style)
- [ ] Confirm `PINNED_APPS` desktop-file IDs in `modes/modectl/profiles/gaming.conf` against a real install
- [ ] **(needs hardware/VM)** verify a real Proton-GE game launch end to end

## 6. Server mode — `modes/server/`

- [x] SSH hardening defaults (key-only auth, refuses to lock out the user if no key is on file yet)
- [x] Docker install script (Docker's own apt repo)
- [x] Netdata install script (official kickstart, telemetry disabled)
- [x] verify-server.sh sanity check
- [ ] Headless boot verification (no display attached, mode still fully usable) — **(needs hardware/VM)**
- [ ] **(needs hardware/VM)** verify `distro-modectl switch server` doesn't break an active SSH session when disabling the display manager

## 7. Creative mode — `modes/creative/`

- [ ] FreeCAD install script
- [ ] Blender install script
- [ ] DaVinci Resolve install script (official native Linux build — check current download/license flow, Nvidia driver dependency)
- [ ] Kdenlive install script (lighter native alternative)
- [ ] ffmpeg build/verify with NVENC/NVDEC support
- [ ] Scratch-disk/cache path defaults pointed at fastest local NVMe
- [ ] Explicit "not supported" doc: SolidWorks/AutoCAD/Premiere/After Effects under Wine — don't attempt, point to Resolve/FreeCAD instead
- [ ] Color-managed display profile loading — **(needs live desktop + real monitor)**

## 8. Normal mode — `modes/normal/`

- [ ] GNOME extension install script (Dash to Dock, top-bar tweaks) — **(needs live desktop)**
- [ ] WhiteSur (or similar) macOS-style theme install — **(needs live desktop)**
- [ ] dconf profile capturing the dock/top-bar/Mission-Control-style layout — **(needs live desktop)**
- [ ] Balanced power defaults verification

## 9. Build pipeline — `iso/`

- [ ] live-build config skeleton (package lists, base hooks)
- [ ] Hook scripts wiring in driver install + mode bundles at build time
- [ ] First buildable ISO (boots in a VM, even before all modes are polished)
- [ ] Calamares installer config + branding
- [ ] CI: automated nightly/release ISO builds (GitHub Actions)

## 10. CI / quality

- [x] shellcheck baseline run on existing scripts (clean)
- [ ] GitHub Actions workflow: shellcheck + `bash -n` on every script, on push/PR
- [ ] Workflow excludes `modes/modectl/profiles/*.conf` from shellcheck (sourced data fragments, not standalone scripts — checking them standalone produces false-positive "unused variable" warnings)

## 11. Open questions (carried over from DESIGN.md, still unanswered)

- Target hardware scope beyond your own rig — how broad does day-one hardware support need to be?
- Solo project or structured for eventual contributors?
- Distro name

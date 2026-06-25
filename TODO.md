# Project TODO — full framework

Living checklist for the whole distro. Organized by the same structure as `DESIGN.md`. Check items off as they're built; every item should eventually link to the file/dir that implements it. Items marked **(needs hardware)** can't be verified until the GPU server exists (~3 months out, see `modes/ai/README.md`) or a generic test VM/box is available; items marked **(needs live desktop)** need an actual running GNOME session to build/verify against, not just a remote shell.

## 0. Foundation

- [x] Architecture plan (`DESIGN.md`)
- [x] Repo scaffolding, disk-as-cache workflow established
- [x] Name picked: **Crucible OS** (2026-06-25). No collisions found (checked against existing "Forge OS"/"Anvil Linux" projects, which were taken — Crucible OS/Crucible Linux was clear). Repo renamed to `crucible-os`, Calamares branding/build.sh/ISO strings updated to match.
- [x] LICENSE (MIT, matching Crucible12) + NOTICE crediting upstream projects without vendoring them
- [x] Top-level README.md (was missing entirely — repo had DESIGN.md/TODO.md but nothing GitHub would show on the repo homepage), links the landing page

## 1. Base system

- [x] Ubuntu 24.04 base image — not hard-pinned to a specific `.x`, `iso/build.sh` targets `--distribution noble` + `--linux-flavours generic-hwe-24.04`, which auto-tracks whatever HWE stack is current. As of 2026-06-25 that's Ubuntu 24.04.4 LTS / kernel 6.17 / Mesa 25.2.7 — current enough that no extra Mesa/kernel PPA is needed on top. See DESIGN.md §1.
- [x] HWE kernel + Mesa: resolved by the above — `generic-hwe-24.04` IS the backport mechanism, no separate PPA needed. Canonical's roadmap has another HWE bump (~August 2026, kernel 6.20/7.0) that this will pick up automatically with no config change.
- [x] Base package list — see `iso/config/package-lists/base.list.chroot` (universal CLI tools) + `iso/strains/*.list.chroot` (DE + strain-specific). `cpupower` itself isn't a literal apt package name — it's provided by `linux-tools-common` + `linux-tools-generic`, which IS what's listed (caught and fixed earlier, not a remaining gap, just correcting this TODO line's wording).

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

- [x] FreeCAD install script (Flatpak, handles the org.freecad/org.freecadweb ID rebrand uncertainty)
- [x] Blender install script (Flatpak)
- [x] DaVinci Resolve install script (wraps BMD's official .run installer — download itself can't be automated, requires manual registration on BMD's site)
- [x] Kdenlive install script (Flatpak)
- [x] ffmpeg with NVENC/NVDEC (checks system ffmpeg first, falls back to BtbN's prebuilt static build)
- [x] verify-creative.sh sanity check
- [x] Explicit "not supported" doc: SolidWorks/AutoCAD/Premiere/After Effects under Wine — don't attempt, point to Resolve/FreeCAD instead (see modes/creative/README.md)
- [ ] Scratch-disk/cache path defaults pointed at fastest local NVMe
- [ ] Color-managed display profile loading — **(needs live desktop + real monitor)**
- [ ] **(needs hardware)** verify NVENC actually works, Resolve actually launches with a real Nvidia GPU

## 8. Normal mode — `modes/normal/`

- [x] WhiteSur GTK/icon/shell theme install script (vinceliuice's own install.sh, user-local)
- [x] Dock repositioning to bottom/floating/autohide (uses Ubuntu's built-in dash-to-dock-based dock, no new extension needed)
- [x] Theme application script (GTK/icon theme + GNOME's official User Themes extension)
- [x] Removed the dead `DE_DCONF_FILE` stub field from all modectl profiles once real implementation landed elsewhere
- [ ] macOS-style global app-menu / Mission-Control-equivalent overview — explicitly not attempted, see `modes/normal/README.md` (no stable GNOME built-in equivalent; needs live-session iteration to pick a real extension)
- [ ] **(needs live desktop)** verify theme/dock changes actually render correctly
- [ ] **(needs live desktop)** confirm the WhiteSur theme name `install.sh` actually produces matches what `03-apply-theme.sh` assumes (`WhiteSur-Dark`)
- [ ] Balanced power defaults verification

## 9. Build pipeline — `iso/`

- [x] live-build config skeleton (`build.sh`, package lists, includes.chroot wiring)
- [x] Scope decision: lean baked image (plain-apt packages only) + post-boot setup scripts for everything needing extra repos/Flatpak/GitHub releases — see `iso/README.md` for why the apt-`archives/` mechanism was deliberately deferred rather than guessed at
- [x] Caught and fixed a real gap while adding strain selection: `base.list.chroot` never included a desktop environment package at all — the original skeleton would have produced a GUI-less image regardless of strain. DE choice moved to per-strain files.
- [x] 6 hardware strains scaffolded (`iso/strains/`, `iso/build.sh [strain]`): workstation, laptop, lowspec, server, handheld, cloud — see DESIGN.md §5b for the Tier 1/2/3 breakdown (ARM/Apple Silicon/RISC-V and embedded explicitly deferred, not silently dropped)
- [x] Strain-selection file-copy/cleanup logic actually execution-tested (stubbed `lb`, ran `build.sh lowspec` then `build.sh laptop`, confirmed no cross-contamination between strains) — the one part of `iso/` that's been run for real, not just read and trusted
- [ ] **(needs Linux build host — live-build doesn't run on macOS at all)** actually run `./build.sh` for the first time, for each strain
- [ ] First buildable ISO (boots in a VM, even before all modes are polished) — **(needs Linux build host)**
- [x] Confirmed `lubuntu-desktop`/`ubuntu-desktop-minimal` are both current real Noble (24.04) metapackages (Launchpad-verified, 2026-06-25). Also confirmed `lubuntu-desktop` is LXQt, not legacy LXDE (transitioned in 2018) — the `iso/strains/lowspec.list.chroot` comment describing it as LXQt was already correct.
- [ ] `handheld` strain's actual differentiation (touch/gamepad UI) — currently identical to workstation, scaffolded but not built
- [ ] `cloud` strain's delivery format — should eventually be a qcow2/raw cloud image + cloud-init, not an installer ISO; currently only the package-selection half exists
- [ ] Decide whether to invest in `config/archives/` to bake Docker/Steam/etc. in at build time, once verified against a real host
- [x] Calamares installer config skeleton (`iso/calamares/`: settings, welcome, users, partition modules + branding descriptor) — YAML-validated, but unverified against a real Calamares run; `partition.conf` flagged as lowest confidence
- [ ] Brand assets (logo.png, welcome.png, show.qml slideshow) — not created, need a real logo now that the name exists, and a renderer to check the QML slideshow actually displays correctly
- [x] Wire Calamares config + package into `iso/build.sh`/`includes.chroot` — moved up ahead of DESIGN.md §7's original "do this last" ordering since a real test host is imminent and it's cheaper to have everything ready for one end-to-end pass than to do this in two passes. Only wired for GUI strains (workstation/laptop/lowspec/handheld); server/cloud stay headless (cloud-init/preseed territory, not Calamares). Execution-tested the strain-switch cleanup logic with a stubbed `lb` across workstation→server→lowspec — caught and fixed a real bug where the installer desktop-entry file leaked across strain switches (cleaned up `etc/calamares` but not the separate `.desktop` file).
- [ ] No live-session autostart hook for Calamares — added a manual-launch desktop entry only, since I'm not confident which autostart mechanism (casper hook vs. autostart `.desktop` with a live-media check) is correct for this live-build/Calamares combination without a host to verify against
- [ ] **(needs Linux host)** install Calamares package, drop this config in, run an actual install end to end
- [ ] CI: automated nightly/release ISO builds (GitHub Actions)

## 10. CI / quality

- [x] shellcheck baseline run on existing scripts (clean)
- [x] GitHub Actions workflow (`.github/workflows/shellcheck.yml`): shellcheck + `bash -n` on every script (discovered by shebang), on push/PR
- [x] Second CI job validates every Calamares config as YAML
- [x] Workflow excludes `modes/modectl/profiles/*.conf` from shellcheck (sourced data fragments, not standalone scripts — checking them standalone produces false-positive "unused variable" warnings)
- [x] Caught a real bug class via manual bash-5 execution (not just `-n`/shellcheck, which can't see this): `set -e` does NOT trigger on a non-last command failing inside a `&&` chain (verified empirically, not just asserted). Found and fixed 5 instances: `distro-modectl status` exiting 1 just because `powerprofilesctl` wasn't installed; 4 `apt-get update && apt-get install` lines that would silently continue past a failed `update`; an `sshd -t && systemctl reload` that would silently skip the reload (and still print a success message) if the config test failed. Fixed by splitting into sequential statements or explicit `if`-checks.
- [ ] Run the same kind of manual bash-5 execution pass on a real Ubuntu box, not just locally via homebrew bash on macOS — this caught real bugs but isn't a substitute for testing in the actual target environment
- [ ] CI currently only lints/parses — no job actually executes any script (can't, most need real system state). Worth revisiting whether any script could get a meaningful smoke test in CI (e.g. `distro-modectl status` with no root needed) once this is on a real Linux runner doing more than syntax checks

## 11. Open questions (carried over from DESIGN.md, still unanswered)

- Target hardware scope beyond your own rig — how broad does day-one hardware support need to be?
- Solo project or structured for eventual contributors?
- Distro name

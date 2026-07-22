# Project TODO — full framework

> **Design doc:** [`docs/mode-selection-design.md`](docs/mode-selection-design.md) — the "choose your modes" installer feature (let users deselect Gaming/AI/Server/Creative; AI can be made *provably absent* via a build flag, for the anti-AI-in-the-OS audience). **Shipped** (commit 8cd2a3c); the Calamares installer-page half is still pending first-real-install validation.

Living checklist for the whole distro. Organized by the same structure as `DESIGN.md`. Check items off as they're built; every item should eventually link to the file/dir that implements it. Items marked **(needs hardware)** can't be verified until the real build lands (**RTX 5090 ~late July 2026, full 5090+9950X3D build ~early August 2026** — see `modes/ai/README.md` and `docs/blackwell-readiness.md`) or a generic test VM/box is available; items marked **(needs live desktop)** need an actual running GNOME session to build/verify against, not just a remote shell.

## 0. Foundation

- [x] Architecture plan (`DESIGN.md`)
- [x] Repo scaffolding, disk-as-cache workflow established
- [x] Name picked: **Refract OS** (2026-06-25). No collisions found (checked against existing "Forge OS"/"Anvil Linux" projects, which were taken — Refract OS/Refract Linux was clear). Repo renamed to `refract-os`, Calamares branding/build.sh/ISO strings updated to match.
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

**Runtime switched to Ollama + ComfyUI (2026-06-30; swapped off LM Studio because
its proprietary terms forbid shipping it in an ISO — Ollama is MIT)** — the
Crucible12/llama.cpp port is preserved in `modes/ai/legacy-crucible12/`. See §5 /
`modes/ai/README.md`.

- [x] Ollama install (`setup/01-install-ollama.sh`, pinned tarball run with `sudo`; creates the `ollama` system user + systemd unit)
- [x] **Tiered model catalogs (2026-07-01)** — six `config/models.catalog.<tier>.json` (`cpu`/`entry`/`mid`/`high`/`max`/`ultra`) of web-verified quantized GGUF models sized per VRAM, so every hardware variant preloads local AIs that fit. `setup/02-preload-models.sh` auto-reads the detected tier (or `--tier X`).
- [x] **Enterprise/workstation `ultra` tier (2026-07-01)** — 48–96GB workstation cards (RTX PRO 6000 96G, RTX 6000 Ada/A6000 48G, W7900 48G, or 2× pooled): 70B fully in VRAM at 48G; 104B/123B + gpt-oss-120B at 96G. 96GB-class models gated by `min_vram_gb` (auto-fallback + load-time warning in `distro-ai-model`). Datacenter GPUs (A100/H100/H200/B200/MI300X/Gaudi/Grace) route to Server mode, NOT a desktop tier. Backed by a verified 6-dimension GPU-landscape study.
- [x] **Hardware auto-detect** (`bin/distro-ai-detect-tier`) — VRAM (Nvidia `nvidia-smi` / AMD-APU sysfs) + RAM + laptop-vs-desktop → tier; **multi-GPU homogeneous VRAM pooling** (sum same-model cards, never mixed vendors); **datacenter guard** → Server mode; laptop power profile (efficiency/balance/power); image-gen opt-in. Writes `~/.config/refract-ai/{tier,profile,image,vram_mib}`. Hermetically tested with injected hardware inputs (`tests/test_detect_tier.sh`, 63 assertions; never touches a real GPU).
- [x] `distro-ai-model` use-case switcher (list/use/load/server/status/unload) — replaces `distro-ai-preset`; tier/profile/VRAM-aware; drives `ollama pull`/load via the API and `ollama ps`; execution-tested with a **stubbed `ollama`** (`tests/test_ai_model.sh`, 30 assertions; never touches a real Ollama daemon)
- [x] **Auto-activation (2026-07-01)** — the tier system now actually fires for a real user: `distro-modectl switch ai` auto-runs `distro-ai-detect-tier` on first entry (idempotent, failure-tolerant), and `bin/distro-ai-setup` is a one-command front door (detect → install Ollama/ComfyUI → preload the fitting models; non-destructive without `--install`). Hermetically tested (`tests/test_ai_setup.sh` 21 assertions + a modectl auto-detect regression).
- [x] ComfyUI image-gen subsystem (`setup/03-install-comfyui.sh` w/ PyTorch cu130 for Blackwell, `setup/04-download-image-models.sh` FLUX.1-schnell+SDXL, now with `--from-config` to fetch only the image model the user picked at detect time, `bin/distro-ai-image`)
- [x] **Website Download configurator (2026-07-01)** — the deferred "pick your hardware → get a tailored build" flow is built: `docs/index.html` `#download` section is an interactive static widget. Pick **GPU** (49 cards across 11 vendor groups, each split out), **CPU** class, and **RAM** → it maps VRAM → tier (same thresholds as `distro-ai-detect-tier`), and RAM/CPU genuinely gate the result (e.g. 5090 + <48GB RAM drops the 70B to 32B; low-core CPU flags slow cpu-tier). Routes datacenter GPUs to Server mode; honest "no prebuilt ISO yet — build from source" framing + build/releases buttons. Site also refreshed off the stale Crucible12/llama.cpp copy onto Ollama + ComfyUI. See `docs/website-configurator-design.md` (BUILT).
- [x] systemd units (`systemd/ollama.service` — system service on :11434, `systemd/comfyui.service`)
- [x] OpenCode→Ollama config (`config/opencode.ollama.json`, points at :11434); cloud toggle repointed
- [x] Optional Alpaca GUI (`setup/06-install-alpaca.sh`) — GNOME-native `com.jeffser.Alpaca` Ollama chat client, Flatpak, pointed at the system Ollama on localhost:11434
- [x] Legacy Crucible12 port preserved + documented (`legacy-crucible12/`)
- [~] **Ollama serve CI-verified on CPU (`ai-serve-smoke.yml`, `ollama-serve-contract`)** — the SAME pinned Ollama tarball the ISO ships installs headless, `ollama serve` comes up, and `/api/tags` + the OpenAI-compatible `/v1/chat/completions` both respond on **:11434** with a tiny model (`qwen2.5:0.5b`) — api_key is the required-but-ignored literal "ollama". This is the "installs + serves headless" clause. **Still (needs hardware)**: each catalog model pulling + loading with correct GPU/CPU layer offload + real tokens/sec (a runner has no GPU).
- [ ] **(needs hardware)** Llama-3.3-70B partial-offload (~6-12 tok/s), `qwen2.5vl` vision model loads + accepts an image, ComfyUI sees the 5090, FLUX/SDXL render
- [~] **Serve+thin-client contract CI-verified on CPU (`ai-serve-smoke.yml`, same job)** — the repo's `distro-ai-ask` thin client hits Ollama on **:11434** and returns a real completion, proving the exact `/v1/chat/completions` contract the overlay / Nautilus action / AI mode all use. The `switch ai` model-autoload plumbing is separately unit-tested (`test_modectl.sh`). **Still (needs hardware)**: the real use-case model auto-loading on a GPU box and thin clients answering from *that*.
- [x] Global hotkey assistant overlay (`bin/distro-ai-overlay`, zenity-based, thin client hitting `localhost:11434` via shared `bin/distro-ai-ask`) + best-effort GNOME keybinding wiring (`bin/distro-ai-bind-hotkey`). Request/response plumbing execution-tested against a stub HTTP server (happy path, empty prompt, unreachable server, malformed response shape) — visual rendering still **(needs live desktop)**
- [x] File-manager "ask AI about this file" context menu action (`integrations/nautilus-ask-ai` + `integrations/install.sh`) — real Nautilus "Scripts" mechanism (`~/.local/share/nautilus/scripts/`, `NAUTILUS_SCRIPT_SELECTED_FILE_PATHS`), not fabricated. Control flow execution-tested with a stubbed `zenity` — menu entry appearing in a real Nautilus session still **(needs live desktop)**
- [x] Optional Claude-cloud fallback toggle (`distro-ai-cloud-toggle enable|disable|status`) — explicit opt-in, refuses to proceed without the user's own `ANTHROPIC_API_KEY`. Execution-tested all 3 subcommands end to end. The JSON config's env-var interpolation syntax is flagged as an unverified guess (not confirmed against OpenCode's actual schema) — printed as a warning every time `enable` runs, not buried.

## 4. Mode-switcher (§4) — `modes/modectl/`

- [x] `distro-modectl switch <mode>` — CPU governor, power profile, service toggling
- [x] Wired into `distro-ai-model` (Ollama model switcher; was `distro-ai-preset`)
- [x] Display-manager-disable confirmation safety + `--yes` flag for non-interactive use
- [x] Best-effort `PINNED_APPS` dock-pinning via `gsettings` (GNOME-only, runs pre-sudo so it has the user's session bus; desktop-file IDs unverified)
- [x] **VM-verified (2026-07-03, mode-test `live` job)** — `sudo distro-modectl switch <mode>` runs in a real GNOME VM: it issues `cpupower frequency-set` / `powerprofilesctl set` and **degrades gracefully when a VM lacks cpufreq/ppd** (screenshot-captured WARNINGs, mode still switches). Real cpufreq/ppd effect still (needs hardware) — the arm64 Pi (`docs/pi-test-runbook.md`).
- [x] **VM-verified (2026-07-03, mode-test `live` job)** — service enable/disable takes effect without fighting Ubuntu: `switch server`'s `systemctl disable --now gdm` actually tore down the live session (proof it applied). Full multi-service matrix still nice-to-have on the Pi.
- [x] GPU performance-state pinning — `apply_gpu_perf` in `distro-modectl`, driven by each profile's `GPU_PERF=max|auto` (Gaming/Creative pin max, others reset). nvidia-smi persistence + clock-lock (headless/Wayland-safe) + nvidia-settings GpuPowerMizerMode on X11. Web-verified command set; **(needs hardware)** to confirm it changes GPU state.

## 5. Gaming mode — `modes/gaming/`

- [x] Proton-GE install/update script (latest GitHub release, auto-fetched)
- [x] Wine-staging install (WineHQ repo, with fallback if codename unsupported yet)
- [x] Bottles install (Flatpak/Flathub, GUI front-end so most users never touch raw `wine`)
- [x] GameMode + MangoHud install (per-launch, not system services)
- [x] winetricks bundled (via wine-staging script)
- [x] Steam + Lutris install scripts
- [x] verify-gaming.sh sanity check
- [x] DXVK + VKD3D-Proton standalone install (`modes/gaming/setup/07-install-dxvk-vkd3d.sh`) for raw Wine prefixes — latest-release fetch with SHA-256 verification via the GitHub API digest. Web-verified current upstream: DXVK v3.x `.tar.gz` (no setup script → manual install), VKD3D-Proton v3.x `.tar.zst` (ships `setup_vkd3d_proton.sh`).
- [x] Curated compatibility-fix database for known-troublesome apps (`compat-db/apps.json` + `bin/distro-gaming-compat`, Lutris-install-script style) — 11 entries across workaround/broken/native-alternative statuses, execution-tested end to end with a stubbed `winetricks`
- [x] `PINNED_APPS` desktop-file IDs web-verified (2026-06): fixed `lutris.desktop` → `net.lutris.Lutris.desktop` (reverse-DNS migration); steam.desktop, the FreeCAD/Blender/Kdenlive/Bottles Flatpak IDs all confirmed correct.
- [ ] **(needs hardware/VM)** verify a real Proton-GE game launch end to end

## 6. Server mode — `modes/server/`

- [x] SSH hardening defaults (key-only auth, refuses to lock out the user if no key is on file yet)
- [x] Docker install script (Docker's own apt repo)
- [x] Netdata install script (official kickstart, telemetry disabled)
- [x] verify-server.sh sanity check
- [x] **Headless boot VERIFIED (2026-07-03)** — the `server` strain ISO booted under OVMF with `-display none` and reached systemd/userspace over serial (`uefi-boot.yml`). A headless server strain hitting `login:` with no GNOME = headless-usable.
- [x] **VM-verified (2026-07-04, `server-ssh-survival.yml`)** — `distro-modectl switch server` (which runs `systemctl disable --now gdm`) inside a live SSH session did NOT drop the admin. On the GitHub runner (a real Ubuntu systemd VM) gdm was **active**, the switch **stopped** it, yet the SSH session AND sshd stayed up and a fresh connection still worked (`gdm=active`→`gdm_active=inactive`, `sshd=active` throughout). No lockout.

## 7. Creative mode — `modes/creative/`

- [x] FreeCAD install script (Flatpak, handles the org.freecad/org.freecadweb ID rebrand uncertainty)
- [x] Blender install script (Flatpak)
- [x] DaVinci Resolve install script (wraps BMD's official .run installer — download itself can't be automated, requires manual registration on BMD's site)
- [x] Kdenlive install script (Flatpak)
- [x] ffmpeg with NVENC/NVDEC (checks system ffmpeg first, falls back to BtbN's prebuilt static build)
- [x] verify-creative.sh sanity check
- [x] Explicit "not supported" doc: SolidWorks/AutoCAD/Premiere/After Effects under Wine — don't attempt, point to Resolve/FreeCAD instead (see modes/creative/README.md)
- [x] Scratch-disk/cache path defaults pointed at fastest local NVMe (`bin/distro-creative-scratch detect|setup`) — `df`+`lsblk`-based detection with honest fallback tiers, best-effort Blender preference wiring, Resolve/ffmpeg flagged as not scriptable. Execution-tested with stubbed `df`/`lsblk`/`blender` across all branches.
- [x] Color-managed display profile loading — scaffolded as `modes/creative/bin/distro-creative-color` (colord/colormgr import + assign-to-default-display, web-verified command sequence). **(needs live desktop + real monitor + measured ICC profile)** to actually run.
- [ ] **(needs hardware)** verify NVENC actually works, Resolve actually launches with a real Nvidia GPU

## 8. Normal mode — `modes/normal/`

- [x] WhiteSur GTK/icon/shell theme install script (vinceliuice's own install.sh, user-local)
- [x] Dock repositioning to bottom/floating/autohide (uses Ubuntu's built-in dash-to-dock-based dock, no new extension needed)
- [x] Theme application script (GTK/icon theme + GNOME's official User Themes extension)
- [x] Removed the dead `DE_DCONF_FILE` stub field from all modectl profiles once real implementation landed elsewhere
- [x] macOS-style global app-menu / Mission-Control — **web-researched and documented** (resolved, not built): no stable maintained GNOME 46+ global-menu extension exists (all stale); GNOME's built-in Activities IS the Mission-Control analogue; Open Bar/Dash-to-Dock are the maintained cosmetic options. See `modes/normal/README.md`.
- [x] **theme/dock render VERIFIED (2026-07-02/03)** — boot-smoke + screenshot-tour screendumps show the macOS-style bottom dock, WhiteSur icons, wallpaper, and the per-mode look actually render on the live GNOME desktop in QEMU.
- [x] WhiteSur theme name web-verified (2026-06): a default install produces `WhiteSur-Dark` (gtk, capitalized) and `WhiteSur` (icon, base) — both exactly what `03-apply-theme.sh` assumes. Confirmed correct.
- [x] Balanced power defaults reviewed: governor/PPD values are all real and sensible per mode (gaming/creative=performance/performance, ai/normal=schedutil/balanced, server=powersave/power-saver), matching DESIGN.md §4.

## 9. Build pipeline — `iso/`

- [x] live-build config skeleton (`build.sh`, package lists, includes.chroot wiring)
- [x] Scope decision: lean baked image (plain-apt packages only) + post-boot setup scripts for everything needing extra repos/Flatpak/GitHub releases — see `iso/README.md` for why the apt-`archives/` mechanism was deliberately deferred rather than guessed at
- [x] Caught and fixed a real gap while adding strain selection: `base.list.chroot` never included a desktop environment package at all — the original skeleton would have produced a GUI-less image regardless of strain. DE choice moved to per-strain files.
- [x] 6 hardware strains scaffolded (`iso/strains/`, `iso/build.sh [strain]`): workstation, laptop, lowspec, server, handheld, cloud — see DESIGN.md §5b for the Tier 1/2/3 breakdown (ARM/Apple Silicon/RISC-V and embedded explicitly deferred, not silently dropped)
- [x] Strain-selection file-copy/cleanup logic actually execution-tested (stubbed `lb`, ran `build.sh lowspec` then `build.sh laptop`, confirmed no cross-contamination between strains) — the one part of `iso/` that's been run for real, not just read and trusted
- [x] **ALL 5 live-build strains BUILD (2026-07-03)** — workstation, laptop, lowspec, server, handheld all built green in CI (`build-iso.yml`). This first per-strain run caught two real bugs: laptop's `tlp`↔`power-profiles-daemon` conflict, and the GNOME macOS-look/polish leaking onto LXQt `lowspec` — both fixed. (`cloud` uses the separate `build-cloud-image.sh` pipeline, not live-build.)
- [x] **`laptop` strain hardened + fully verified for the first hardware target — Intel ThinkPad X1 Carbon (2026-07-04)**. Two independent audits confirmed the no-GPU/Intel paths are crash-free (NVIDIA installer is opt-in-only with a correct lspci guard; AI detect cleanly falls to `cpu` tier). Added `intel-media-va-driver-non-free` (VAAPI HW decode), `thermald`, `fprintd`+`libpam-fprintd`, and pinned `linux-firmware`; made `apply_cpu_governor` intel_pstate-aware (maps `schedutil`→`powersave` so the default modes stop printing a governor warning; 6 new unit tests). Laptop ISO verified end to end: builds hybrid **BIOS+UEFI** (the X1 is UEFI-only — critical gate GREEN), boots clean to the Refract desktop (boot-smoke), passes **UEFI-boot** under OVMF, and its Calamares installer is correctly assembled (install-smoke inspect). Flash guide: `docs/thinkpad-x1-carbon.md`.
- [x] **First buildable ISO — DONE + boots in a VM (2026-07-02)** — CI builds it (ubuntu-latest = the Linux build host) and boot-smoke boots it to a full GNOME desktop in QEMU/KVM; now also BIOS+UEFI (uefi-boot.yml).
- [x] Confirmed `lubuntu-desktop`/`ubuntu-desktop-minimal` are both current real Noble (24.04) metapackages (Launchpad-verified, 2026-06-25). Also confirmed `lubuntu-desktop` is LXQt, not legacy LXDE (transitioned in 2018) — the `iso/strains/lowspec.list.chroot` comment describing it as LXQt was already correct.
- [x] `handheld` strain's actual differentiation (`iso/strains/handheld/setup-handheld-ui.sh`: on-screen keyboard, UI text scaling, Steam Big Picture autostart via stable GNOME gsettings schemas) — execution-tested all branches (root/session guards, Steam present/absent) with stubbed `gsettings`/`steam`
- [x] `cloud` strain's real delivery format (`iso/cloud-image/build-cloud-image.sh`: debootstrap + loop-device + grub-install + qemu-img convert to qcow2, separate from the live-build/Calamares ISO pipeline) — guard checks (root/Linux/tool-presence) execution-tested for real; full pipeline control-flow verified with every external tool stubbed, but debootstrap/partition/grub semantics are unverified. **(needs Linux host with root + loop devices)**
- [x] `config/archives/` decision made: researched and verified the real mechanism against Debian's live-manual, then **deliberately not adopted** for mode-specific tools (Docker/Steam/etc.) since modes are opt-in/runtime-switchable and strains are build-time-only — baking a mode's repo into a strain's image would blur that separation and conflict with existing runtime apt-source setup. See `iso/README.md`'s "Architecture decision" section.
- [x] Calamares installer config skeleton (`iso/calamares/`: settings, welcome, users, partition modules + branding descriptor) — YAML-validated, but unverified against a real Calamares run; `partition.conf` flagged as lowest confidence
- [x] Brand assets: logo.png + welcome.png (`branding/src/*.svg` + `branding/build.sh`, refract-vessel motif, rasterized via `qlmanage`, visually reviewed, copied into `iso/calamares/branding/refractos/` and `docs/`) — see `branding/README.md`
- [x] show.qml slideshow — 6 slides, written against Calamares' own fetched default `show.qml` + branding README (not guessed), `slideshowAPI: 2` set in `branding.desc`. **(needs Calamares run)** to verify it actually renders — no local QML tooling (`qmlscene`/`qmllint`) to check ahead of time, only brace/paren balance was checkable here.
- [x] Wire Calamares config + package into `iso/build.sh`/`includes.chroot` — moved up ahead of DESIGN.md §7's original "do this last" ordering since a real test host is imminent and it's cheaper to have everything ready for one end-to-end pass than to do this in two passes. Only wired for GUI strains (workstation/laptop/lowspec/handheld); server/cloud stay headless (cloud-init/preseed territory, not Calamares). Execution-tested the strain-switch cleanup logic with a stubbed `lb` across workstation→server→lowspec — caught and fixed a real bug where the installer desktop-entry file leaked across strain switches (cleaned up `etc/calamares` but not the separate `.desktop` file).
- [x] Live-session autostart hook for Calamares (`iso/casper-hooks/casper-bottom/25-refract-install-icon` + `iso/config/hooks/live/0100-update-initramfs-for-casper-hook.hook.chroot`) — verified against a real working example (maui-linux/calamares-casper) rather than guessed between candidate mechanisms. Wired into `iso/build.sh` for GUI strains only, execution-tested across workstation/server/lowspec with a stubbed `lb`. **(needs Linux build host)** to confirm it actually works on a real live boot.
- [ ] **(needs Linux host)** install Calamares package, drop this config in, run an actual install end to end
- [x] CI: `.github/workflows/build-iso.yml` — `workflow_dispatch`-only (strain chosen via dropdown). Runs on a real `ubuntu-latest` GitHub runner (root + loop devices).
- [x] **FIRST ISO BUILT (2026-07-02)** — run 28568346976 produced `refract-os-workstation` (2.45 GB artifact, `binary.hybrid.iso` inside) after 7 CI iterations fixing six real decade-old bugs in Ubuntu's live-build fork (3.0~a57): `--debian-installer none`→`false` (version-detected), dead oneiric/gfxboot theme packages (local `config/bootloaders/isolinux` template + `--syslinux-theme live-build`), the unconditional gfxboot-hack `cpio -i < bootlogo` (valid-empty-cpio stub generated by build.sh), config binary hooks running from the BUILD ROOT not `binary/` (`config/hooks/500-refract-bootfix.binary` renames casper kernels + stages noble-path isolinux.bin/ldlinux.c32), `isohybrid` moved from `syslinux` to `syslinux-utils` (chroot package list), and the fork's `binary.hybrid.iso` output name (build.sh rename now tries all generations). Every fix source-verified against the fork's extracted .deb, not guessed.
- [x] **QEMU boot smoke test in CI — PASSED (2026-07-02, run 28570187277)**: `.github/workflows/boot-smoke.yml` downloads the ISO artifact and boots it on the runner with KVM. Phase A (SeaBIOS→isolinux→kernel→**full GNOME desktop at t=180s**, screendump-verified + screenshots in the `boot-smoke-evidence` artifact) and Phase B (direct-kernel, serial console: casper mounts the live squashfs, systemd reaches userspace) both green. Refract OS boots to a desktop. Boot splash is still stock Ubuntu Plymouth (cosmetic TODO); theming is post-install by design.
  - **Live session lands straight on the Refract desktop — verified 2026-07-04 (run 28690252613)**: the polish layer had exposed Ubuntu's `gnome-initial-setup` "Welcome!" wizard on the live session. Root cause: on GNOME 46 it's launched by a systemd *user* unit, so an `/etc/skel` stamp (raced by casper) and hiding the XDG autostart `.desktop` both did nothing (build logs confirmed the hook ran, wizard still showed). Fixed by **purging `gnome-initial-setup`** (only a *Recommends* of ubuntu-desktop{,-minimal}, so dependency-safe) in `iso/config/hooks/0400-polish.chroot`, + apt pin + `InitialSetupEnable=false` + masking the systemd user units (as casper's `52gnome_initial_setup` does). t180 screenshot now shows the prism-logo desktop + top bar, no wizard. Dock is `autohide=true`/`intellihide=true` (macOS-style), so it reveals on bottom-edge hover.
- [x] **Installer config VERIFIED (2026-07-02, install-smoke `inspect` job)** — mounted the live squashfs on a runner and asserted the Calamares install is correctly assembled: binary present, every shipped module config present + referenced by the sequence, and **unpackfs source == `/cdrom/casper/filesystem.squashfs`** (the audit's previously-unproven concern, now proven against the real image). Also ran the distro CLIs AND the full test suite inside the shipped image userland (overlay+chroot, as uid 1000) — all green. `.github/workflows/install-smoke.yml`.
- [~] **Behavioral install (install-smoke `install` job)** — **installer now LAUNCHES cleanly** (2026-07-03): fixed a real bug where double-clicking Install popped an "Authenticate to manage disks" polkit prompt (default button Cancel) and nothing happened → now `Exec=pkexec calamares` + a live-session polkit rule (`/etc/polkit-1/rules.d/49-refract-installer.rules`, udisks2/calamares/pkexec/login1, active-local only). Screenshot-verified: Calamares opens as root, all pages render (Welcome/Locale/Keyboard/Partition/Users/Summary). The full unattended GUI-drive is **NOT reliably automatable in CI** (non-deterministic window position, VNC statelessness — `move`+`click` must be one call, no a11y hooks; one attempt hit the 60-min timeout). Marked best-effort (`continue-on-error`). **Realistic end-to-end check = a human clicking through Calamares once via `docs/utm-guide.md`.** The deterministic proof (assembly + unpackfs source) is the `inspect` job, which passes.
- [x] **UEFI boot — DONE + OVMF-VERIFIED (2026-07-03)** — didn't need the modern-live-build migration after all: `.github/workflows/uefi-remaster.yml` post-processes the BIOS ISO into a hybrid BIOS+UEFI image (inject an EFI El Torito boot image via `grub-mkstandalone` with an embedded menu that `search --file /casper/vmlinuz`; repack with `xorriso -as mkisofs -isohybrid-mbr isohdpfx.bin -eltorito-alt-boot -e EFI/boot/efiboot.img -isohybrid-gpt-basdat`), then **boots it under real UEFI firmware (OVMF) in QEMU → reached systemd/userspace, PASS**. **FOLDED INTO build.sh (2026-07-03)** — the build now post-processes its own output into a hybrid image (log: "UEFI: … is now a hybrid BIOS+UEFI image"), so every built + published ISO is natively BIOS+UEFI. Verified by `.github/workflows/uefi-boot.yml` (asserts the UEFI El Torito record, then OVMF-boots the freshly-built ISO → PASS). `uefi-remaster.yml` retired.
- [x] **First public download (2026-07-03)** — `build-iso.yml` publishes the ISO to a rolling `latest-<strain>` GitHub Release; >2GiB ISOs are `split` into <2GiB parts with cross-platform rejoin notes (GitHub's 2GiB asset cap). Docs reframed (`docs/install.html`): download→flash(any OS)→install is the headline; build-from-source is an optional contributor step. `docs/utm-guide.md` added for VM testing.

## 10. CI / quality

- [x] shellcheck baseline run on existing scripts (clean)
- [x] GitHub Actions workflow (`.github/workflows/shellcheck.yml`): shellcheck + `bash -n` on every script (discovered by shebang), on push/PR
- [x] Second CI job validates every Calamares config as YAML
- [x] Workflow excludes `modes/modectl/profiles/*.conf` from shellcheck (sourced data fragments, not standalone scripts — checking them standalone produces false-positive "unused variable" warnings)
- [x] Caught a real bug class via manual bash-5 execution (not just `-n`/shellcheck, which can't see this): `set -e` does NOT trigger on a non-last command failing inside a `&&` chain (verified empirically, not just asserted). Found and fixed 5 instances: `distro-modectl status` exiting 1 just because `powerprofilesctl` wasn't installed; 4 `apt-get update && apt-get install` lines that would silently continue past a failed `update`; an `sshd -t && systemctl reload` that would silently skip the reload (and still print a success message) if the config test failed. Fixed by splitting into sequential statements or explicit `if`-checks.
- [x] **Real-Ubuntu execution — DONE via CI** — `tests.yml` runs the full stub suite on `ubuntu-latest` (real GNU/bash-5), and `install-smoke`'s inspect job runs the CLIs + suite INSIDE the shipped image userland (overlay+chroot). The mode-mechanism harness also runs the shipped `distro-modectl` in the real image. So the scripts are exercised on the actual target userland, not just macOS homebrew bash.
- [x] CI now EXECUTES scripts, not just lints: `.github/workflows/tests.yml` runs `tests/run.sh` on `ubuntu-latest` — a stub-based suite (10 `test_*.sh` files, ~190 assertions) for the pure-logic scripts (modectl, gaming-compat, creative-scratch, ai-ask, cloud-toggle, detect-tier, ai-model, ai-setup, apply-mode-selection) + a compat-db schema validator. The CI run does what a macOS box can't: e.g. asserts the `df -l --output` form works on real GNU coreutils. See `tests/README.md`.
- [x] **Two behavioral CI workflows added (2026-07-04)** that exercise real integration surfaces on the runner (itself a real Ubuntu systemd VM), not just stubs: `server-ssh-survival.yml` (installs real gdm+sshd, proves `switch server` doesn't drop a live SSH session — see §6 line 82) and `ai-serve-smoke.yml` (the `ollama-serve-contract` job: the pinned Ollama tarball installs headless, `ollama serve` comes up on :11434, a tiny model serves `/api/tags` + `/v1/chat/completions`, and `distro-ai-ask` gets a real answer — proving both the Ollama install and the OpenAI serve/thin-client contract — see §3 lines 44/46). Both dispatch-only.
- [x] Final full-repo sweep after this session's additions: shellcheck + `bash -n` across all 45 bash scripts (clean), shellcheck + `sh -n` across both POSIX-sh casper hooks (clean), every JSON/YAML/Calamares config re-validated (all parse), the `distro-modectl status` smoke test re-run (exit 0), `show.qml`'s brace/paren balance re-checked, and all 3 `branding.desc`-referenced image/QML files confirmed to actually exist on disk. Also found and removed real local debris this sweep would have missed otherwise: a stray `iso/cloud-image/noble/` directory left by an early (buggy) stub during this session's own testing, and leftover gitignored `includes.chroot/{opt,usr,etc}` content from earlier strain-switch tests — neither was ever committed, but both were cleaned off disk per the disk-as-cache rule.

## 11. Open questions (carried over from DESIGN.md) — resolved or defaulted

- ~~Distro name~~ — **resolved**: Refract OS (see §0).
- ~~Is the AI gateway Claude-only or local-model-first?~~ — **resolved**:
  local-first by design (Ollama + ComfyUI, Crucible12-derived), Claude-cloud
  is an explicit opt-in toggle only (`distro-ai-cloud-toggle`), never silently
  substituted in. See §3 and `modes/ai/README.md`.
- Target hardware scope beyond your own rig — **resolved by your own
  answer** ("every single kind of machine that you can think of that might
  even remotely run linux") into the Tier 1/2/3 breakdown in DESIGN.md
  §5b: Tier 1 (x86_64, same build pipeline, 6 strains scaffolded) is the
  actual buildable scope; Tier 2 (ARM64/Apple Silicon/RISC-V — different
  arch, different bootloader, a separate engineering effort) and Tier 3
  (embedded/Buildroot — not a fit for what this project is) are explicitly
  deferred, not silently dropped.
- Solo project or structured for eventual contributors? — **never
  explicitly answered; defaulted to "structured as if for contributors"**
  as the practical choice, since the repo already has a public GitHub
  remote, a top-level README/LICENSE/NOTICE, a README in nearly every
  subdirectory, and public CI (`.github/workflows/`) — all low-cost to do
  up front and either neutral or beneficial even if this stays solo. If
  you'd rather not take outside contributions, nothing here forces that;
  it's just kept the door open rather than closed by default.

## 12. Adversarial audit pass (2026-06-30, ahead of first hardware)

A multi-agent audit ahead of the 5090 arriving: web-verified every external
dependency + an adversarial code review where each candidate bug was
independently verified before acceptance (3 false positives correctly
rejected). 19 confirmed-real bugs fixed across 5 commits.

- [x] **5090/Blackwell driver blocker** — RTX 5090 needs the `-open` kernel
  module (closed module → "No devices found") AND driver branch ≥570 (550
  example was wrong). `drivers/install-nvidia.sh` defaults to `-open`,
  installs `nvidia-driver-<v>-open`, documents the 570+/graphics-drivers-PPA
  fallback. Also fixed: Secure-Boot MOK false "no signing needed" when mokutil
  absent/unknown.
- [x] **HIGH bugs** — `df -lP --output` mutually exclusive (creative-scratch
  NVMe detection silently always fell back to /var/tmp); `--yes` dropped on
  modectl's sudo re-exec (broke non-interactive server switch); cloud-image
  loop device missing `--partscan` (mkfs would abort the build).
- [x] **MEDIUM/LOW bugs** — microcode grep dead on kernel 6.8; opencode Node
  guard never fired for pre-existing Node; systemd unit missing
  `LimitMEMLOCK=infinity`; gaming-compat KeyError traceback; steam multiverse
  DEB822-blind; sshd validate-after-apply; proton-ge pre-creating ~/.steam/root;
  davinci `dpkg -s nvidia-driver-*` glob; modectl usage() separator + AI-start
  abort-before-state-write; base.list HWE linux-tools mismatch; branding crop
  band + dead pre-clean rm.
- [x] **External deps confirmed correct** (no change needed) — all llama.cpp
  build/runtime flags, the `Qwen3-Coder-Next` model + all 3 HF repos/quants,
  WineHQ noble repo, Lutris PPA, GE-Proton/BtbN asset naming, all Flatpak IDs,
  Netdata/Docker/live-build/Calamares/casper. The OpenCode `{env:VAR}` syntax
  previously flagged as a guess is now confirmed documented (caveat removed).
- [x] `preflight.sh` — build-host readiness check (env/static/network/apt),
  whose network section live-reconfirmed all 16 external endpoints (200 OK).
- [x] `docs/blackwell-readiness.md` — consolidated, web-verified 5090 reference.
- [x] `docs/first-hardware-runbook.md` — ordered 6-stage test plan (OVH server
  track + 5090 track).
- [ ] **(needs hardware)** Everything above is web-verified or static/stub
  tested, NOT run on the real 5090 — the runbook + readiness checklist are what
  close that gap when the card arrives (~early August 2026).

### 12b. Hardening pass (test suite + security review)

- [x] **Stub-based test suite + CI execution** (`tests/`, `.github/workflows/tests.yml`)
  — 10 files / ~190 assertions, runs on `ubuntu-latest` so scripts actually
  execute on the target OS (real GNU coreutils), not just lint. Plus
  `tests/validate-compat-db.py` (the schema check the audit recommended) wired
  into CI to prevent the gaming-compat KeyError-regression class as the DB grows.
- [x] **Adversarial security review** (root/sudo, GPG keys, curl|sh, temp files,
  injection, file perms) — 12 candidates, **1 confirmed real** (most correctly
  rejected: npm-as-root is the expected operator; unpinned llama.cpp master has
  the same trust root as any source build). Fixed: `01-install-whitesur-theme.sh`
  cloned **unpinned upstream HEAD** of third-party theme repos and ran their
  `install.sh` (supply-chain RCE surface) — now pins both repos to verified
  commit SHAs with fetch-by-SHA + verify-abort. This also fixed a real
  functional bug the review surfaced: the script cloned a **nonexistent**
  `WhiteSur-gnome-shell-theme` repo (404), which under `set -e` aborted the
  whole script so even the GTK/icon themes never installed; the GTK repo's own
  install.sh installs the shell theme anyway.

### 12c. Hardware-free completion pass (2026-06-30)

"Fix everything doable without hardware." An 8-agent research workflow verified
every remaining factual unknown, then built/corrected against it:

- [x] DXVK + VKD3D-Proton standalone installer (§5) — checksum-verified.
- [x] Checksum verification added to GE-Proton (`.sha512sum`) and BtbN ffmpeg
  (`checksums.sha256`) downloads — addresses the security-review note on
  unverified "latest" binaries. Both also tightened to pin the right asset
  (GE-Proton x86-64 not aarch64; ffmpeg static-master not -shared/numbered).
- [x] `PINNED_APPS` `.desktop` IDs verified + `lutris.desktop` fixed (§4/§5).
- [x] GPU performance-state pinning wired into modectl (§4).
- [x] Color-managed display profile scaffolded (`distro-creative-color`, §7).
- [x] macOS-shell question resolved by research, not built (§8) — no stable
  global-menu extension exists; stock Activities = Mission Control.
- [x] WhiteSur theme names confirmed correct (§8).
- [x] `iso/calamares/modules/partition.conf` schema-corrected against upstream
  (real errors fixed: `efi.systemPartition`, mis-nested `userSwapChoices`).
- [x] compat-db expanded 11 → 25 entries, all schema-valid in CI (§5).
- [x] `CONTRIBUTING.md` (working norms) + `verify-all.sh` (post-install
  orchestrator) added.
- [x] Balanced power defaults reviewed; all governor/PPD values sane (§4).
- [ ] **(needs hardware/host/live-desktop)** Everything still genuinely gated:
  the first real `lb build` + boot + install, the GPU work (driver/AI/NVENC/
  game launches), and live-desktop theme/extension/color rendering. These are
  the *only* remaining open items — see `docs/first-hardware-runbook.md`.

### 12d. Second read-only review pass (2026-07-22)

A fresh full-codebase review on top of 12a–c (commit `9558bad`), read-only on the
laptop by request — nothing built/run locally; validated by `bash -n`, shellcheck,
and YAML/JSON parse, then proven on GitHub CI. ~50 objective issues cataloged and
every confirmed one fixed (`f160364`, 44 files; `3e20125` closed the CI gap below):

- [x] **SECURITY (HIGH): passwordless-root no longer persists onto installed
  systems.** The installer polkit grant (`49-refract-installer.rules`) was baked
  into `config/includes.chroot` → shipped in the squashfs → landed on every
  installed desktop, where any local+active user could `pkexec bash` to root with
  no password. Moved to the casper-bottom hook (LIVE overlay only); `build.sh`
  purges any stale copy. **CI-proven on the built workstation ISO** (`3e20125`):
  `verify-boot-fixes` now asserts the rule is ABSENT from the installed squashfs
  while the casper-bottom generator still ships + writes it — all three PASS.
- [x] **CI false-greens closed.** boot-smoke/install-smoke/uefi-boot require a
  LATE marker (graphical.target / display-manager / login) instead of a bare
  "reached target" (fires for Swap) + a casper RUNTIME marker instead of the
  `boot=casper` cmdline echo; install-smoke/publish surface a loud failure + exit
  1 despite `continue-on-error`; uefi-boot resolves the ISO by exact name (not a
  `refract-os-*` glob that could boot a `-noai`/DANGER image); build-iso's
  omitted-mode absence assertion now also covers the Calamares checkbox/slide/
  screenshot surfaces. `tests/mode-mechanism.sh` asserts the command the switcher
  actually emits (`disable gdm`, not `disable --now gdm`).
- [x] **Installer/boot correctness.** Wayland-disable scoped to Intel at runtime
  (AMD/NVIDIA keep Wayland); `openssh-server` out of the universal base list into
  server/cloud only; welcome.conf floor 20/4 → 8/2 GiB (was locking out lowspec);
  partition default erase → none (dual-boot footgun); shellprocess@modes ordered
  after users; bootfix asserts the renamed kernel exists; `lb --version` glob
  `3.0*` → `*3.0*`; REFRACT_TESTING drops the splash on the live UEFI entry;
  omitting ALL optional modes drops the now-empty packagechooser page.
- [x] **AI/modectl runtime.** `modes enable gaming|creative` runs setup as the
  normal user (sudo made `usermod -aG` target root); 02-preload honors the power
  PROFILE (efficiency was preloading the heavier tag → re-download); default tier
  max → entry; cloud-toggle backs up an existing `opencode.json`; creative-scratch
  gained a root guard; verify-drivers SKIPs (not FAILs) on non-Nvidia/non-AMD;
  ComfyUI `is_running` probes `/system_stats` (not `/`) so a random :8188 listener
  can't false-positive; dead `YARU_ACCENT` dropped from 4 profiles; icon-theme
  `WhiteSur` → `WhiteSur-dark` for parity.
- [x] **Docs & naming sweep.** Last Crucible12/LM-Studio/llama.cpp stragglers →
  "Ollama + ComfyUI (Crucible12-derived)"; mode-selection-design.md marked
  SHIPPED; misleading "omit arg = ALL ~150GB" preload text corrected (pulls ONE
  model); non-tier `models.catalog.json` refs → per-tier; GNU-only `dd` split by
  OS; test counts 9 → 10; blackwell section-4 gap; typo.
- **Deliberately skipped:** BIOS/`isolinux.cfg` live-menu parity (that file's edit
  was declined earlier — the UEFI-side no-splash/serial equivalent is in
  `build.sh`) and a couple of pure-taste items (keyd opt-out advertising, full
  `-h/--help` uniformity).
- [~] **install-smoke `install` job** stays the known best-effort CI limitation
  (the VNC-driven Calamares GUI drive isn't reliably automatable — timed out again
  this pass, unchanged by these edits). The deterministic `inspect` job passes;
  the real end-to-end install proof is a human clicking through Calamares once
  (`docs/utm-guide.md`).

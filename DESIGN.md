# Refract OS — Architecture Plan

## Goal (restated, with realistic framing)

A desktop Linux distro, built on a popular upstream base, that:
- Maximizes Windows app/game compatibility out of the box (not "100%" — that's not achievable by anyone, including Valve/CodeWeavers; framed as "broadest practical compatibility, pre-tuned, zero setup")
- Ships Nvidia GPU + AMD CPU drivers/microcode preinstalled and working day one
- Has 5 switchable system **modes**: Gaming, AI, Server, Creative, Normal (macOS-style)
- Has a local-first AI layer baked into the OS, not a cloud assistant bolted onto a browser

This doc is the architecture only — no build steps executed yet.

---

## 1. Base distro choice

**Recommendation: Ubuntu LTS (24.04) as upstream base**, not Debian, not "Mint/Pop directly."

Reasoning:
- Mint and Pop!_OS are themselves Ubuntu derivatives — basing on them just adds an extra layer of someone else's patches you'd have to track and possibly fight.
- Ubuntu LTS has the widest driver support, the largest binary package availability (PPAs, .debs), and is what Valve, Nvidia, and most ISVs test against first. This matters directly for the "max Windows app compatibility" goal — Proton/Wine, Nvidia driver installers, and most ISV Linux builds assume Ubuntu/Debian-family `apt`.
- 5-year LTS support means you're not rebasing the whole distro every 9 months.

Alternative considered: **Arch-based** (like Pop's old base flirtations, or CachyOS, which is Arch-based and already gaming/performance-tuned). Pros: bleeding-edge kernel/Mesa/driver versions matter a lot for Wine/Proton/GPU compat. Cons: rolling release is a worse fit for "polished, install-and-forget" Normal mode, and packaging/support burden is higher for a solo or small-team project.

**Pragmatic middle ground**: Ubuntu LTS base + HWE (Hardware Enablement) kernel stack + Mesa/kernel backports via the same PPAs CachyOS/Pop pull from. This gets Arch-tier freshness for the gaming-critical bits (kernel, GPU drivers, Mesa, Wine/Proton builds) without inheriting rolling-release instability everywhere else.

**Pinned, as of 2026-06-25**: base point release is whatever the current Ubuntu 24.04.x is at build time — `iso/build.sh` doesn't hard-pin a specific `.x` release number, it targets `--distribution noble` and `--linux-flavours generic-hwe-24.04`, and that HWE metapackage always pulls the *current* HWE kernel/Mesa stack automatically. As of this writing that's **Ubuntu 24.04.4 LTS** (released 2026-02-12), shipping **Linux kernel 6.17** and **Mesa 25.2.7** via the HWE stack — current enough that no separate Mesa/kernel backport PPA is needed on top of it. Canonical's own roadmap has one more HWE bump landing ~August 2026 (kernel 6.20/7.0, Ubuntu 26.04's Mesa stack, shipping as 24.04.5) — `generic-hwe-24.04` will pick that up automatically on any build run after that lands, no config change required here.

## 2. "Run every Windows app" — what's actually true and what to build

Be explicit with users about this from install screen onward: **"broad compatibility, not universal."** Overpromising here is the single biggest reputation risk for the project — it's the exact same promise SteamOS/Proton/CrossOver have spent a decade carefully NOT making.

What to actually ship:
- **Proton-GE** (community Proton build, broader compat than vanilla Proton) preinstalled, not just vanilla Wine
- **Wine (staging branch)** for non-Steam/non-game apps
- **Bottles** as the GUI front-end — most users should never see a raw `wine` prefix
- **DXVK + VKD3D-Proton** preinstalled so DirectX 9-12 → Vulkan translation works out of the box
- **winetricks** bundled for the inevitable "this one app needs .NET 4.8 and a specific font" case
- A **compatibility database/launcher** (similar in spirit to Lutris' install scripts) curated for your distro specifically, so common known-troublesome apps get auto-applied workarounds on install

What will never work, regardless of tuning: kernel-anticheat games (Valorant, some Battlefield/EA titles), apps requiring TPM-backed DRM, anything requiring a literal Windows kernel driver (some VPNs, some enterprise security software, some HID/peripheral software).

---

## 3. Driver strategy (Nvidia GPU + AMD CPU)

- Nvidia: ship the proprietary driver (not nouveau) on the ISO itself, with secure-boot signing handled at build time (`mokutil`/`shim` signing) so Nvidia + secure boot isn't a day-one support nightmare like it is on stock Ubuntu.
- AMD CPU: microcode package (`amd64-microcode`) preinstalled, `amdgpu` driver if there's also an AMD GPU present (note: your phrasing was "Nvidia GPU and AMD CPU" specifically — that's the most common enthusiast pairing, worth optimizing for explicitly rather than assuming AMD GPU too).
- Kernel: HWE/backports kernel so newer CPU silicon and GPUs are recognized without the user manually grabbing a newer kernel.
- `nvidia-prime`/equivalent power-state handling tuned per mode (see below — Gaming mode forces max performance state, Normal mode allows power-saving).

---

## 4. The 5 modes — this is the actually novel/buildable centerpiece

Not 5 separate OS images. One base system + a **mode-switcher daemon** (`distro-modectl`, systemd-integrated) that atomically swaps a coherent bundle of: CPU governor, GPU power profile, compositor settings, running services, default-pinned apps, and DE theme/shell layout.

| Mode | CPU/GPU | Services | DE/Shell | Notes |
|---|---|---|---|---|
| **Gaming** | performance governor, GameMode active, GPU max-perf state | Steam/Lutris/Bottles auto-launch-ready, background services trimmed | minimal/no compositor, low-latency input path | MangoHud overlay available |
| **AI** | GPU prioritized for inference (CUDA/ROCm reserved), CPU balanced | local model runtime running as systemd service (Ollama-style), exposes local API | AI assistant overlay/launcher pinned, system-wide hotkey | this is where your OpenClaw-style local-gateway pattern plugs in — see §5 |
| **Server** | balanced/power-save CPU, GPU idle unless doing GPU-compute | SSH, Docker/Podman, monitoring stack (e.g. Netdata) enabled; DE optionally unloaded entirely | headless-capable, DE is optional not mandatory | this mode should be usable with zero display attached |
| **Creative** | GPU prioritized for CAD viewport/render + video encode/decode (NVENC/NVDEC reserved), color-managed display profile loaded | CAD + video editing suite pinned (see below) | wide-gamut color profile auto-applied | |
| **Normal** | balanced, power-saving defaults | standard desktop services only | macOS-style shell: dock, top menu bar, Mission-Control-style overview | built on GNOME + extensions (Dash to Dock, top bar tweaks) or Pop's COSMIC shell themed accordingly; WhiteSur-style theme as starting point rather than building a shell from scratch |

Mechanically: each mode is a profile = a set of systemd unit enable/disable calls + a `tuned`/`power-profiles-daemon` profile + a DE config swap (GNOME profile switching, or separate lightweight session files) + a default-app pin list. Switching modes should not require logout for most things, but DE/shell changes (Normal's dock/bar) likely need a session restart — be upfront about that rather than faking a seamless switch.

**Status: built**, see `modes/modectl/`. `distro-modectl switch <mode>` implements the CPU governor, power profile, and service enable/disable parts, and wires into AI mode's preset switcher. DE/shell switching (Normal's dock, Creative's color profiles) is explicitly stubbed, not faked — those need a real desktop session to build against, which doesn't exist yet either. Not run on real hardware yet, but unlike AI mode this part doesn't need the specific GPU server — any Ubuntu box/VM would do once one's available to test on.

### Creative mode, detailed: CAD + video editing focus

**CAD**: the honest compatibility split matters here more than anywhere else in the plan.
- **Native Linux CAD that's genuinely good**: FreeCAD (full parametric CAD, native, actively developed), Blender (modeling/CAD-adjacent + full render pipeline, native, excellent GPU support).
- **Windows-only CAD under Wine — here's where "every app" breaks down hardest**: SolidWorks, AutoCAD, Fusion 360 are notoriously bad-to-broken under Wine/Proton — they lean on Windows-specific licensing DRM, .NET dependencies, and GPU driver paths Wine doesn't fully cover. CodeWeavers (makers of CrossOver) have spent years on AutoCAD support specifically and it's still partial. Set the expectation: Creative mode ships FreeCAD/Blender as the native, fully-working defaults, and treats Windows CAD-under-Wine as "may work with tinkering, not guaranteed" rather than promising it.
- Fusion 360 is the one with the best realistic path since Autodesk ships a browser/cloud-rendered tier — that sidesteps Wine entirely if the user's fine with cloud compute for that one app.

**Video editing**: much better news than CAD.
- **DaVinci Resolve has an official native Linux build** (free + Studio tiers) — this is the headline app for Creative mode, not a Wine workaround. Needs the proprietary Nvidia driver (already in §3) and benefits directly from NVENC/NVDEC hardware encode/decode on your GPU.
- **Kdenlive** and **Blender's VSE** as native, fully-open-source options for lighter editing.
- **Premiere Pro / After Effects**: no native Linux build, Wine support is poor (same DRM/plugin-architecture problems as the CAD case) — don't promise these, point users to Resolve as the real answer instead of a fragile Wine attempt.
- Mode-level config: `ffmpeg` built with NVENC/NVDEC support preinstalled, GPU power state pinned high during encode/render jobs (mirrors AI mode's "reserve the GPU" pattern from §5, just for render queues instead of `llama-server`), scratch-disk/cache paths defaulting to the fastest local NVMe.

Net effect: Creative mode's pitch should be "Resolve + FreeCAD + Blender work great, fully native, hardware-accelerated out of the box" — a true and strong claim — rather than "runs SolidWorks/Premiere," which would repeat the same overpromise risk flagged in §2.

---

## 5. Local AI layer — Ollama + ComfyUI (was Crucible12)

**Runtime change (2026-06-30):** AI mode now runs on **Ollama** (text +
vision LLMs) + **ComfyUI** (image generation) instead of the original
Crucible12/llama.cpp stack. Ollama is turnkey for a desktop distro — one pinned
install, a model registry, a built-in OpenAI-compatible server — and supports
the broader model menu (coding / CAD / day-to-day / know-it-all / uncensored /
assistant / vision / image). It's still **local-first** (the server is
127.0.0.1, no cloud, no keys) — the "not Copilot slop" bar still holds.
Crucially, Ollama is **MIT-licensed**, so Refract can vendor, pin, and ship it
inside the ISO — the reason it replaced LM Studio, whose proprietary terms forbid
redistribution (a distro cannot legally bundle it). Both wrap the same llama.cpp
core, so this is a licensing + footprint win (a native systemd daemon, no
Electron), not a speed one. The original Crucible12 port is preserved, not
deleted, in `modes/ai/legacy-crucible12/` (and the standalone Crucible12 project
is unaffected). The implementation, the exact model catalog, and the key caveats
live in `modes/ai/README.md`.

Key verified facts that shaped the build (researched, not guessed):
- **Ollama** installs from a pinned tarball via `sudo ./setup/01-install-ollama.sh`,
  which creates the dedicated `ollama` system user and a Refract-owned systemd
  unit. The daemon serves an OpenAI-compatible endpoint at
  `http://127.0.0.1:11434/v1` (api_key is the literal string "ollama") plus a
  native REST API at `/api/*`, so `distro-ai-ask`/overlay/nautilus work unchanged.
- Models are pulled with `ollama pull <tag>` (exact ollama.com tags) and loaded
  via the API; `ollama ps` shows what's resident. `distro-ai-model` switches by
  use-case on top of that.
- **Hardware tiers (2026-07-01):** every build preloads local models sized to
  its hardware. `distro-ai-detect-tier` auto-detects VRAM (Nvidia `nvidia-smi`,
  AMD/APU sysfs), RAM, and laptop-vs-desktop, and maps VRAM → one of six tiers
  — `cpu` (≤4B, CPU-only) / `entry` (5–11GB) / `mid` (11–20GB) / `high`
  (20–30GB) / `max` (30–45GB, the 5090) / `ultra` (≥45GB). Each has its own
  quantized-GGUF catalog `config/models.catalog.<tier>.json`. On laptops the
  user also picks a power profile (efficiency/balance/power) selecting which
  variant loads by default; image generation is opt-in at detect time.
  IDs/quants are web-verified.
- **Enterprise/workstation GPUs (2026-07-01):** the `ultra` tier covers 48–96GB
  workstation cards (RTX PRO 6000 96GB, RTX 6000 Ada / A6000 48GB, Radeon PRO
  W7900 48GB, or 2× homogeneous cards pooled) — its win over `max` is running
  70B/72B **fully in VRAM** (no CPU offload) at 48GB, plus 104B/123B dense and
  gpt-oss-120B MoE resident at 96GB. Detection **sums** VRAM across homogeneous
  same-model cards (Ollama splits a model across them by layer), never across mixed
  vendors. True **datacenter** silicon (A100/H100/H200/B200/GB200, MI300X/MI325X,
  Gaudi, Grace-ARM) is deliberately NOT a desktop tier — the detector routes it
  to **Server mode** (headless Ollama/vLLM) instead of a desktop AI-mode GUI,
  the honest product line for a local-first desktop distro. Backed by a verified
  6-dimension GPU-landscape study.
- **Intel Arc laptops:** with no dGPU, the detector finds a real Arc iGPU via
  `vulkaninfo` (not Mesa `llvmpipe`) and turns on **Ollama's Vulkan backend**
  (`OLLAMA_VULKAN=1` drop-in), which needs the laptop strain's Vulkan userspace.
  The Arc NPU is not usable by Ollama and is not part of this path.
- **Llama-3.3-70B** (~43GB Q4) exceeds the 32GB 5090 → Ollama offloads the
  overflow layers to system RAM, ~6–12 tok/s; everything else fits fully in VRAM.
- **Vision uses Qwen2.5-VL** (`qwen2.5vl`), which Ollama runs natively — it pulls
  the vision projector automatically, no separate mmproj step.
- **Image generation is ComfyUI, not Ollama** (Ollama has no Linux diffusion).
  FLUX.1-dev is gated → default to the no-token FLUX.1-schnell + SDXL.

The original rationale for a local-first coding stack (below) still applies; it
just runs on Ollama's engine now instead of a hand-built llama.cpp service.

**HISTORICAL — superseded, kept for the porting rationale only.** The plan
below (`llama-server` run as a systemd `crucible12-server.service`, a
`distro-ai-preset` switcher, hand-built llama.cpp) was the *original* port
design. **What actually shipped is the Ollama + ComfyUI build described above**
— read the rest of this section as the historical reasoning for why AI mode
exists, not as the current implementation.

Currently Crucible12 is Windows-11/PowerShell-native (`01-install-llamacpp.ps1`, `02-download-models.ps1`, `run-refract.ps1`, etc., targeting CUDA + `nvidia-smi`). Porting work for AI mode:

- **Linux port of the setup scripts**: bash equivalents of the four `setup/*.ps1` scripts — `llama.cpp` has Linux CUDA build targets already (this is the easy part), model download/quant logic is OS-agnostic, `benchmark.ps1`'s GPU-utilization check becomes `nvidia-smi`-on-Linux (same tool, already works)
- **systemd-ified `llama-server`**: instead of "leave a PowerShell window open running `run-refract.ps1`," AI mode starts/stops `llama-server` as a systemd unit (`crucible12-server.service`) with the preset baked into the unit's `ExecStart` flags — no terminal window babysitting
- **Preset switching = the mode's actual control surface**: `refract` / `max` / `fast` / `reasoning` already map cleanly onto something like `distro-ai-preset switch max` — restart the systemd unit with different flags, swap the matching `opencode.*.json`. This reuses your existing preset design verbatim rather than inventing a new one.
- **OpenCode as the AI-mode default app**: pinned/auto-launched in AI mode's app bundle, already pointed at `localhost`'s `llama-server`
- **Mode-level resource ownership**: AI mode is what reserves GPU/VRAM and RAM-bandwidth headroom for `llama-server` (per §4's table) — this is literally what `--n-cpu-moe` tuning already assumes (DDR5 EXPO on, ~30GB VRAM headroom target), so the mode-switcher's job is just "make sure nothing else is competing for that headroom while AI mode is active," not new tuning logic
- **System-level hooks beyond the terminal**: a global hotkey assistant overlay and file-manager context-menu action ("ask local AI about this file") both just become OpenAI-compatible HTTP calls to the already-running `llama-server` — thin clients on top of infrastructure Crucible12 already provides
- **Known limitation to carry over, not silently fix**: the `reasoning` preset (gpt-oss-120b)'s flaky tool-calling via Harmony format ([OpenCode #7185](https://github.com/anomalyco/opencode/issues/7185)) is upstream, not yours to fix — AI mode should default to `refract`/`max` and treat `reasoning` as a manual one-shot fallback, matching what the README already recommends

Optional, explicit opt-in only: a toggle to also route through Claude (cloud) when the user wants a stronger model and has connectivity — same principle as OpenClaw's gateway, but secondary to the local-first default, never silently substituted in.

This is the part of the project most worth prototyping first — you already have a working stack, the task is porting + systemd-wrapping it, not inventing it.

**Status: built (Ollama + ComfyUI)**, see `modes/ai/`. Install scripts
(pinned Ollama tarball, tier-aware model preload, ComfyUI, image-model download,
optional Alpaca GUI), the `distro-ai-model` use-case switcher + the six per-tier
`models.catalog.<tier>.json`, `distro-ai-detect-tier` hardware auto-detect,
`distro-ai-image`, the `ollama.service` system unit, and the thin clients
(unchanged, on :11434). The switcher + tier detection are execution-tested with a
**stubbed `ollama`** and fully injected hardware inputs (`tests/test_ai_model.sh` +
`tests/test_detect_tier.sh`) — never a real Ollama daemon or GPU. **Not yet
run on the real card — the RTX 5090 arrives ~late July 2026, full build ~early
August 2026.** Install method, exact model tags/quants, vision-support, and
ComfyUI/FLUX facts are all web-verified — see `modes/ai/README.md` and
`docs/blackwell-readiness.md`.

---

## 5b. Hardware strains — build-time profiles, separate from runtime modes

Modes (§4) are a runtime switch on one install. **Strains** are a
build-time decision: what desktop environment (if any) and what packages
ship by default, chosen for a class of hardware. Every strain still gets
all 5 modes — a low-spec machine can still run AI mode, a server strain
can still (in principle) run Creative mode, the strain just picks a
sensible starting point rather than gatekeeping what's possible.

This distinction exists because "make a version for every kind of
computer" isn't one engineering task — it's several different ones at
wildly different scales:

**Tier 1 — same CPU architecture (x86_64), same build pipeline
(live-build + Calamares), genuinely just a different package-list
overlay.** This is what "strain" means here, see `iso/strains/`:
- `workstation` (default) — full GNOME desktop, no special tuning
- `laptop` — same desktop + `power-profiles-daemon` (NOT tlp — it conflicts with p-p-d on 24.04 and fights the mode-switcher) + `thermald`, `fprintd`, Intel VAAPI, and firmware bits
- `lowspec` — LXQt (`lubuntu-desktop`) instead of GNOME, skips
  gamemode/mangohud/winetricks by default (installed on-demand via
  `modes/gaming/setup/` if actually needed on that hardware)
- `server` — no DE at all, relies on `modes/server/setup/*.sh` post-boot
- `handheld` — Steam-Deck-class x86_64 devices; same packages as
  workstation for now, touch/gamepad-first UI tuning not yet built
- `cloud` — `cloud-init`, no DE; its delivery format should eventually be
  a qcow2/raw cloud image rather than an installer ISO — not built, this
  strain currently only covers the package-selection half

**Tier 2 — different CPU architecture. A categorically separate
engineering effort, not "one more strain":** ARM64 (Raspberry Pi-class),
Apple Silicon, RISC-V. Each needs its own kernel config, its own
bootloader (u-boot, not GRUB), often cross-compilation, and a different
image format. Apple Silicon specifically would mean depending on the Asahi
Linux project's out-of-tree kernel work rather than anything live-build
provides — adopting someone else's multi-year reverse-engineering effort,
not a package list. Deliberately deferred, not silently dropped.

**Tier 3 — not actually a fit for what Refract OS is at all:**
microcontroller-class embedded Linux (Buildroot/Yocto territory — no
desktop, often no apt, no installer). A fundamentally different kind of
project than a desktop/server distro with a Calamares installer.

---

## 6. Build tooling

- **live-build** (Debian/Ubuntu native ISO remaster tool) for the actual ISO pipeline — more scriptable/reproducible than Cubic (which is GUI-driven and better for one-off experiments, not a maintained pipeline)
- Custom Calamares installer config (what Mint/Manjaro/EndeavourOS all use) for the install screen — supports a custom slideshow/branding and is the standard choice rather than rolling your own installer
- CI: once the live-build config stabilizes, this should run in a pipeline (GitHub Actions or similar) to produce nightly/release ISOs automatically rather than manual remasters

---

## 7. Suggested build order (when you're ready to move past design)

1. Local AI gateway prototype, running on stock Ubuntu (proves §5, reuses OpenClaw pattern)
2. Mode-switcher daemon + just 2 modes (Gaming, Normal) on stock Ubuntu in a VM (proves §4 mechanics)
3. Driver/compatibility layer bundling (§2, §3) — scripted install, not yet baked into an ISO
4. First live-build ISO that bundles 1–3 together
5. Remaining 3 modes (AI, Server, Creative) added incrementally
6. Calamares installer branding + slideshow pass last — cosmetic, lowest risk, do it after the system itself works

---

## Open questions — resolved or defaulted (see TODO.md §11 for the full writeup)

- ~~Distro name~~ — resolved: Refract OS.
- ~~AI gateway Claude-only vs. local-first?~~ — resolved: local-first
  (Ollama + ComfyUI, Crucible12-derived), Claude-cloud is an explicit
  opt-in toggle only, never silently substituted in.
- Target hardware scope — resolved by your own answer into the Tier 1/2/3
  breakdown in §5b: Tier 1 (x86_64, 6 strains) is the real buildable scope;
  Tier 2 (different CPU architecture)/Tier 3 (embedded) explicitly deferred.
- Solo vs. structured-for-contributors — never explicitly answered;
  defaulted to "structured as if for contributors" (public repo,
  README/LICENSE everywhere, public CI) as the low-cost, either-neutral-
  or-beneficial choice rather than leaving it undecided indefinitely.

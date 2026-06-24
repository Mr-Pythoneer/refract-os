# Custom Linux Distro — Architecture Plan

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

---

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

## 5. Local AI layer — built around Crucible12

You've already built the actual stack this mode runs: **[Crucible12](https://github.com/Mr-Pythoneer/Crucible12)** — `llama-server` (llama.cpp, CUDA build) hybrid-serving **Qwen3-Coder-Next** (80B/3B-active MoE) across your specific hardware (RTX 5090 32GB + Ryzen 9 9950X3D + 64GB DDR5-6400), fronted by **OpenCode** as the terminal agent, OpenAI-compatible API in between. This is real local-first AI — no API keys, no cloud, no telemetry — which is exactly the "not Copilot slop" bar you set. AI mode's job is to make this the OS's native state, not to build something new alongside it.

Currently Crucible12 is Windows-11/PowerShell-native (`01-install-llamacpp.ps1`, `02-download-models.ps1`, `run-crucible.ps1`, etc., targeting CUDA + `nvidia-smi`). Porting work for AI mode:

- **Linux port of the setup scripts**: bash equivalents of the four `setup/*.ps1` scripts — `llama.cpp` has Linux CUDA build targets already (this is the easy part), model download/quant logic is OS-agnostic, `benchmark.ps1`'s GPU-utilization check becomes `nvidia-smi`-on-Linux (same tool, already works)
- **systemd-ified `llama-server`**: instead of "leave a PowerShell window open running `run-crucible.ps1`," AI mode starts/stops `llama-server` as a systemd unit (`crucible12-server.service`) with the preset baked into the unit's `ExecStart` flags — no terminal window babysitting
- **Preset switching = the mode's actual control surface**: `crucible` / `max` / `fast` / `reasoning` already map cleanly onto something like `distro-ai-preset switch max` — restart the systemd unit with different flags, swap the matching `opencode.*.json`. This reuses your existing preset design verbatim rather than inventing a new one.
- **OpenCode as the AI-mode default app**: pinned/auto-launched in AI mode's app bundle, already pointed at `localhost`'s `llama-server`
- **Mode-level resource ownership**: AI mode is what reserves GPU/VRAM and RAM-bandwidth headroom for `llama-server` (per §4's table) — this is literally what `--n-cpu-moe` tuning already assumes (DDR5 EXPO on, ~30GB VRAM headroom target), so the mode-switcher's job is just "make sure nothing else is competing for that headroom while AI mode is active," not new tuning logic
- **System-level hooks beyond the terminal**: a global hotkey assistant overlay and file-manager context-menu action ("ask local AI about this file") both just become OpenAI-compatible HTTP calls to the already-running `llama-server` — thin clients on top of infrastructure Crucible12 already provides
- **Known limitation to carry over, not silently fix**: the `reasoning` preset (gpt-oss-120b)'s flaky tool-calling via Harmony format ([OpenCode #7185](https://github.com/anomalyco/opencode/issues/7185)) is upstream, not yours to fix — AI mode should default to `crucible`/`max` and treat `reasoning` as a manual one-shot fallback, matching what the README already recommends

Optional, explicit opt-in only: a toggle to also route through Claude (cloud) when the user wants a stronger model and has connectivity — same principle as OpenClaw's gateway, but secondary to the local-first default, never silently substituted in.

This is the part of the project most worth prototyping first — you already have a working stack, the task is porting + systemd-wrapping it, not inventing it.

**Status: built**, see `modes/ai/`. Bash ports of all setup/run/benchmark scripts, systemd unit template, and `distro-ai-preset` control script. **Not yet run end-to-end — the target GPU hardware (RTX 5090 + 9950X3D box) doesn't exist yet; ETA ~3 months (~September 2026).** This is a known, expected gap, not something blocking the rest of the project.

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

## Open questions to settle before building

- Target hardware scope: are you building/testing this on your own current rig (Nvidia GPU + AMD CPU desktop?) or aiming for broader hardware support from day one? Narrower target = much faster to a working v1.
- Solo project or do you want this structured so others could eventually contribute (affects whether you set up public CI/repo structure now vs later)?
- Is the AI gateway meant to be Claude-only (using your existing Claude subscription pattern), or genuinely local-model-first with Claude as an optional add-on?

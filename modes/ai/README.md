# AI mode

Local-first AI, built on **Ollama** (text + vision LLMs) and **ComfyUI**
(image generation). This replaced the original Crucible12/llama.cpp runtime on
2026-06-30 — that port is preserved in `legacy-crucible12/`. See DESIGN.md §5.

Everything runs **on your own machine** — Ollama's server is local
(127.0.0.1:11434), no cloud, no API keys (an optional Claude-cloud toggle exists
for when you explicitly want it). Ollama is **MIT-licensed**, so Refract can
vendor, pin, and ship it inside the ISO (was LM Studio, whose proprietary terms
forbid redistribution — a distro legally cannot bundle it). It wraps the same
llama.cpp core, so tokens/sec are ~identical; the win is licensing + footprint
(a native systemd daemon, no Electron).

> **All of this is built against web-verified facts (install method, exact
> model tags/quants, ComfyUI/FLUX) but has NOT been run on the real 5090 yet.**
> This is the 5090/9950X3D/64GB build. See `docs/blackwell-readiness.md` and
> `docs/first-hardware-runbook.md`.

## Install (run on the real GPU box, as your normal user — NOT root)

**The one-command front door** — detects the tier and installs + preloads the
models that fit your hardware:

```bash
distro-ai-setup --install     # detect tier -> install Ollama + ComfyUI -> preload fitting models
distro-ai-setup               # (no --install) just detect + print the plan, download nothing
```

`distro-modectl switch ai` also auto-detects the tier on first entry, so a fresh
install picks the right models without any manual step. The individual steps
below are what `distro-ai-setup` runs, if you'd rather do them by hand:

```bash
# 0) Detect the hardware tier (VRAM/RAM/laptop/Arc iGPU), pick laptop profile + image model
distro-ai-detect-tier                 # writes ~/.config/refract-ai/{tier,profile,image,vram_mib}
                                      # (--yes = defaults, --print = preview, --tier X = force)

# Text + vision LLMs (Ollama) — 02 auto-reads the detected tier
sudo ./setup/01-install-ollama.sh     # pinned Ollama tarball; creates the 'ollama' system user + systemd unit
./setup/02-preload-models.sh          # pull the *tier's* catalog (prints a size warning)
./setup/05-install-opencode.sh        # optional: OpenCode coding agent on top of Ollama
./setup/06-install-alpaca.sh          # optional: Alpaca, a GNOME-native point-and-click Ollama chat GUI (Flatpak)

# Image generation (ComfyUI — separate runtime, Ollama has no Linux diffusion)
./setup/03-install-comfyui.sh         # ComfyUI + PyTorch cu130 (Blackwell)
./setup/04-download-image-models.sh --from-config   # only the image model you picked

# The Ollama server runs as a SYSTEM service, installed + enabled by 01-install-ollama.sh (port 11434):
sudo systemctl status ollama          # check it
sudo systemctl restart ollama         # restart after a config/drop-in change
```

### Hardware tiers (so every machine preloads models that fit it)

`distro-ai-detect-tier` reads VRAM (Nvidia via `nvidia-smi`, AMD/APU via sysfs),
RAM, and laptop-vs-desktop, then maps VRAM → a tier. Each tier has its own
`config/models.catalog.<tier>.json` of **quantized** GGUF models sized to fit:

| Tier | VRAM (GiB) | Example cards | LLM ceiling | Image |
|---|---|---|---|---|
| `cpu` | none / iGPU | APUs, no dGPU | ≤3B (CPU) | none |
| `entry` | 5–11 | GTX 1660, RTX 3050/3060 | 7–8B | SDXL |
| `mid` | 11–20 | RTX 3060 12G, 4060 Ti 16G, 4070 | 14B (+16B MoE) | SDXL / FLUX.1-schnell |
| `high` | 20–30 | RTX 3090/4090, 7900 XTX | 32B | FLUX.1-dev |
| `max` | 30–45 | RTX 5090 (32GB) | 70B (partial CPU offload) | FLUX.1-dev |
| `ultra` | ≥45 | RTX PRO 6000 96G, RTX 6000 Ada 48G, W7900 48G, 2× pooled | 70B **fully in VRAM**; 96G → 104B/123B + gpt-oss-120B | FLUX.1-dev |

On a **laptop** you also pick a power **profile** — `efficiency` (fast/small
models, least battery) / `balance` / `power` (same as a desktop). The profile
decides which variant `distro-ai-model use <case>` loads by default; desktops
default to `power`. Override anything: `REFRACT_AI_TIER=mid`,
`REFRACT_AI_PROFILE=efficiency`, or `distro-ai-detect-tier --tier high`.

**Intel Arc laptops (the X1 Carbon target):** when there's no discrete GPU,
`distro-ai-detect-tier` looks for an Intel Arc **iGPU** via `vulkaninfo --summary`
(ignoring Mesa's `llvmpipe` software rasterizer). If it finds a *real* Arc device,
it enables **Ollama's Vulkan backend** (drops `Environment="OLLAMA_VULKAN=1"` into
the `ollama` service) so the iGPU actually does the offload — this needs the
Vulkan userspace the laptop strain ships (`mesa-vulkan-drivers` etc.). An iGPU has
no dedicated VRAM, so it's tiered by system RAM (→ `entry`/`mid`). The Arc **NPU
is not usable** by Ollama and is never part of this path.

**Multi-GPU:** `distro-ai-detect-tier` **sums** VRAM across *homogeneous
same-model* cards (Ollama splits a model across them by layer), so 2×48GB → a
96GB `ultra`. Mixed vendors are **not** pooled. The `ultra` tier's 96GB-class
models (gpt-oss-120B, Mistral-Large-123B, Command-R+ 104B) carry a `min_vram_gb`,
so on a 48GB card `use <case>` auto-falls-back to a fitting variant; an explicit
`use <case> <variant>` that won't fit still loads but warns.

**Datacenter GPUs are Server-mode, not a desktop tier.** On an
A100/H100/H200/B200/GB200/MI300X/Gaudi/Grace card, `distro-ai-detect-tier` stops
and points you to `distro-modectl switch server` (headless Ollama/vLLM) rather
than a desktop AI-mode GUI — the honest shape for that hardware. An H100/H200
**NVL** card in a workstation is allowed-with-warning. Force the desktop path
with `--tier ultra` or `REFRACT_ALLOW_DATACENTER=1`.

Then load a model and use it:

```bash
distro-ai-model use coding      # ollama pull/loads Qwen2.5-Coder-32B; API on :11434
distro-ai-ask "explain this regex"
distro-ai-image                 # opens ComfyUI for image gen (port 8188)
```

## The model menu (config/models.catalog.<tier>.json)

The OpenAI-compatible server runs on **port 11434** (Ollama's system service,
also serving a native REST API at `/api/*`), so the existing thin clients keep
working unchanged. Switch by use-case. The table below is the **`max`** tier (the
5090 build); the other four tiers (`cpu`/`entry`/`mid`/`high`) mirror this menu
with smaller models that fit their VRAM — `distro-ai-model list` prints the
active tier's actual menu.

| Use-case (max tier) | Best | Fast/alt |
|---|---|---|
| `coding` | Qwen2.5-Coder-32B (`qwen2.5-coder:32b`) | Qwen2.5-Coder-7B (`qwen2.5-coder:7b`) |
| `cad` | Qwen2.5-Coder-32B | Qwen2.5-Coder-7B |
| `day-to-day` | Qwen3-32B | Qwen2.5-14B / Gemma3-4B / Llama-3.3-70B¹ |
| `know-it-all` | DeepSeek-R1-32B | Qwen3-8B |
| `uncensored` | Dolphin 2.9 Mixtral 8x7B | Dolphin3 8B |
| `assistant` | Qwen3-30B-A3B | Llama-3.2-3B |
| `vision` | Qwen2.5-VL-32B (`qwen2.5vl:32b`) | Qwen2.5-VL-7B (`qwen2.5vl:7b`)² |
| `image` (ComfyUI) | FLUX.1-dev³ | SDXL |

Model ids are exact **ollama.com tags** (e.g. `qwen2.5-coder:7b`,
`qwen2.5vl:7b`), pinned per tier in `config/models.catalog.<tier>.json`.

`distro-ai-model list | use <case> [variant] | load <ollama-tag> | server
start|stop|status | status | unload`. It resolves the active tier from
`REFRACT_AI_TIER` → `~/.config/refract-ai/tier` → `max`, and the default variant
from the profile. `distro-ai-model status` runs `ollama ps` to show what's loaded.

**Verified caveats (the reason this was researched, not guessed):**
- ¹ **Llama-3.3-70B** at Q4_K_M is ~43GB — it does NOT fit the 32GB 5090, so
  Ollama offloads the overflow layers to the 64GB RAM. Realistic **~6–12 tok/s**
  (the often-cited 15–20 needs a smaller quant). Everything else fits fully in VRAM.
- ² **Vision runs on `qwen2.5vl` (Qwen2.5-VL), which Ollama supports natively** —
  `vision` loads `qwen2.5vl:7b` by default and `qwen2.5vl:32b` on bigger tiers;
  Ollama pulls the model's vision projector for you, so there's no separate
  mmproj step.
- ³ **FLUX.1-dev is gated** (HF license + token). The installer defaults to the
  Apache-2.0 **FLUX.1-schnell** (no token); pass `HF_TOKEN=… --flux-dev` for dev.
- **Image generation runs in ComfyUI, not Ollama** (Ollama has no Linux
  diffusion). It has its own web UI/API on port 8188 — `distro-ai-image` launches it.
- Full preload of everything (LLMs + image models) is **~190–210GB** on disk.

## Thin clients (unchanged — they hit :11434)

- `bin/distro-ai-ask` — shared OpenAI-compatible backend (one curl call).
- `bin/distro-ai-overlay` + `bin/distro-ai-bind-hotkey` — zenity prompt bound to
  `<Super>space`.
- `integrations/nautilus-ask-ai` — "ask AI about this file" Nautilus script.
- These need a model loaded first (`distro-ai-model use <case>`) and a live
  GNOME session to render — execution-tested against a stub server, not a real
  desktop.

**Prefer a window over a terminal?** `setup/06-install-alpaca.sh` installs
**Alpaca** (`com.jeffser.Alpaca`), a GNOME-native Ollama chat client, as a
Flatpak and points it at the system Ollama on `localhost:11434` — a
noob-friendly, point-and-click front end. Purely additive; nothing else depends
on it.

## Optional cloud fallback (explicit opt-in)

`bin/distro-ai-cloud-toggle enable` swaps the project's OpenCode config to route
through Claude (cloud) — for when you want a stronger model and have
connectivity. Requires your own `ANTHROPIC_API_KEY`. `config/opencode.ollama.json`
is the local (Ollama :11434) counterpart. Per DESIGN.md §5, cloud is never the
silent default.

## Status — needs the 5090

- [ ] `sudo setup/01-install-ollama.sh` installs the pinned Ollama tarball + the
      `ollama` system user/unit on the box
- [ ] `02-preload-models.sh` pulls the catalog; each model loads with the right
      GPU/CPU layer split (the 70B partially offloaded to RAM)
- [ ] `distro-ai-model use <case>` pulls/loads + serves on :11434; thin clients answer
- [ ] vision: `qwen2.5vl:32b` loads and accepts an image
- [ ] ComfyUI: PyTorch sees the 5090 (`torch.cuda.is_available()`), FLUX/SDXL render
- [ ] `ollama.service` system unit auto-starts the server on boot
- [ ] laptop/Arc: `distro-ai-detect-tier` confirms a real Arc via `vulkaninfo` and
      enables Ollama's Vulkan backend (`OLLAMA_VULKAN=1`)

The `distro-ai-model` switcher + catalog are execution-tested with a **stubbed
`ollama`** (30+ assertions, `tests/test_ai_model.sh`) — never against a real
Ollama daemon or GPU.

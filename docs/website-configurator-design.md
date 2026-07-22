# Website download configurator — design note (BUILT 2026-07-01)

**Status: shipped.** The "pick your GPU → see your tier + preloaded models" flow
is live in `docs/index.html` (the `#configure` section) — an interactive,
static, client-side widget. It maps a chosen GPU → effective VRAM → tier using
the same thresholds as `distro-ai-detect-tier`, shows the headline models per
use-case, and routes datacenter GPUs to Server mode. The prerequisites this note
called out are all done: the six per-tier catalogs, the `--tier` flag, the
`distro-ai-detect-tier` detector (multi-GPU pooling + datacenter guard), and the
`distro-ai-setup` front door. The original design note follows.

## The idea

On the website's download page, the user picks:
- **GPU** — every GPU ever made, including integrated graphics, plus a "no GPU"
  option.
- **CPU**, **RAM**, **SSD** (size/speed).

The download is then tailored: it **preloads a set of local AI models sized to
that hardware** (and tunes mode defaults). A 5090 box gets the big models; a
no-GPU laptop gets only tiny CPU-runnable ones.

## How this maps to what already exists

This is a new dimension layered on the existing concepts, not a rewrite:

- **Hardware strains** (`iso/strains/`) already pick the desktop environment /
  base packages per hardware *class* (workstation/laptop/lowspec/…). The
  configurator adds an **AI-model tier** dimension on top — what models to
  preload — keyed primarily on **VRAM** (the binding constraint for local LLMs).
- The per-tier model catalogs (`modes/ai/config/models.catalog.<tier>.json`, one
  per hardware tier — e.g. `.max.json` for the 5090) are the data the
  configurator would scale across. Each model already
  carries an approximate size + VRAM need, so a tier is just "the subset that
  fits in N GB of VRAM (plus CPU-offload candidates up to system RAM)."

## Proposed model tiers (VRAM-keyed) — to flesh out later

| Tier | VRAM | Example preload set |
|---|---|---|
| `cpu-only` | none / iGPU | only the tiny ones: `llama3.2:3b`, `qwen2.5:7b` (CPU inference, slow but works) |
| `entry` | ~6–8 GB | 7–8B models: `qwen2.5-coder:7b`, `llama3.1:8b`, `dolphin-llama3:8b`; SDXL for images |
| `mid` | ~12–16 GB | + 14B (`qwen2.5:14b`), 16B MoE (`deepseek-coder-v2:16b`) |
| `high` | ~24 GB | + 32B (`qwen2.5-coder:32b`, `qwen2.5-vl:32b`), `dolphin-mixtral:8x7b`, FLUX |
| `max` (the 5090 build) | 32 GB+ | everything, incl. `llama3.3:70b` with CPU offload + FLUX.1-dev |

The picker just resolves the user's GPU → its VRAM → the tier (CPU-offload to
system RAM extends what's reachable, so RAM is a secondary input).

## Why it's deferred

- It needs a **GPU→VRAM database** ("every GPU ever made") — a real data-curation
  task (PCI IDs / model names → VRAM), best done once the single build proves the
  model stack actually works on real hardware.
- The per-tier model sets should be **validated on representative hardware**
  before being offered as a one-click download — shipping a "this fits your
  card" promise that doesn't is worse than not offering it.
- The website is currently a static GitHub Pages site; a configurator that emits
  a tailored manifest is a bigger build (it can stay static — emit a per-tier
  install manifest the post-boot setup reads — but still more than a page).

## Smallest first step when we pick this up

Don't build the full GPU database first. Start with a **manual tier selector**
(5 buttons: cpu-only/entry/mid/high/max) that each map to a model-catalog subset,
and have `modes/ai/setup/` accept a `--tier` so the preload pulls only that
subset. The "detect/select your exact GPU" UX is a polish layer on top of that.

# Raspberry Pi test runbook — arm64 low-RAM validation box

A cheap Pi (listed as a "Pi 5 1GB" — note: the Pi 5's smallest variant is
actually 2GB, so a 1GB board is likely a Pi 4; this runbook applies to either)
is a genuinely useful second test machine. It is a **real Linux** — real bash 5,
real GNU coreutils, real systemd, real `/proc` — which the macOS dev box is not,
and it validates a set of TODO items that explicitly do **not** need the 5090
build (`TODO.md` §4: "verify cpupower/powerprofilesctl calls on a real
(non-Mac) Linux box — this part doesn't need the GPU server specifically").

## What this box CAN validate

| Check | Command | Expected |
|---|---|---|
| Full hermetic test suite on real Linux | `bash tests/run.sh` | 10/10 files, ~190 assertions pass |
| Repo static health | `./preflight.sh` | static checks pass; env section will flag live-build/amd64 items — expected, this box doesn't build ISOs |
| Tier detection on GPU-less, DMI-less, low-RAM hardware | `modes/ai/bin/distro-ai-detect-tier --print` | tier `cpu`; "no dedicated GPU"; the **<4GB RAM warning fires for real**; form factor `desktop` — Pis have **no `/sys/class/dmi`** (ARM uses device-tree), so this exercises the chassis-read fallback → battery check → desktop path on real hardware |
| modectl on a real non-Mac Linux | `sudo ./modes/modectl/distro-modectl switch normal --yes` then `status` | governor/power-profile calls run for real (`cpupower` / `powerprofilesctl` exist on arm64 Ubuntu); service enable/disable doesn't fight stock defaults — **this closes a live TODO item** |
| Server-mode services on arm64 | server bundle pieces (sshd key-only config, Docker, Netdata all ship arm64 builds) | `verify-all.sh` server section |
| systemd unit syntax | `systemd-analyze verify modes/ai/systemd/*.service` | parses clean (the units won't *run* here — no Ollama — but syntax/lint is real) |

## What this box CANNOT do (don't try)

- **Boot or install Refract OS.** The ISO is `--architectures amd64` (x86_64);
  a Pi is arm64 and doesn't boot standard ISOs anyway (Pi firmware boot chain,
  not UEFI ISO). Porting the distro to Pi is a separate project, not a test.
- **Build the ISO.** Wrong architecture and nowhere near enough RAM/disk.
- **Run local AI models.** Ollama's arm64 build exists, but the tier catalogs + models target x86_64/GPU (—
  re-verify when the Pi arrives, but true as of 2026-07), and 1–2GB RAM can't
  hold even a 1B Q4 model plus the OS without swap-thrashing. The AI-mode value
  here is exercising the *detection/selection logic*, not inference.
- **Anything needing a desktop session.** Run it headless; 1GB + a DE is misery.

## Setup (once, headless)

1. Flash **Ubuntu Server 24.04 LTS (arm64)** with Raspberry Pi Imager — same
   noble userland as the distro target, which is the point. Preconfigure SSH +
   Wi-Fi in the imager.
2. On low RAM, add zram before doing anything else:
   `sudo apt-get install -y zram-tools && sudo systemctl enable --now zramswap`
3. Deps for the test matrix:
   `sudo apt-get install -y git shellcheck python3 jq curl`
4. `git clone https://github.com/Mr-Pythoneer/refract-os && cd refract-os`
5. Run the table above top to bottom; file anything that differs from
   "Expected" as an issue with the raw output.

## Optional extras

- **Self-hosted CI runner:** a GitHub Actions runner fits (barely) in 1GB and
  would run `tests/run.sh` on real arm64 per push. Marginal — `ubuntu-latest`
  already covers x64 Linux — but it's a fun always-on canary.
- **Let Claude drive:** SSH from the dev Mac (`ssh user@pi`) and let a Claude
  Code session run the matrix and file results, same as the plan for the 5090
  box in `first-hardware-runbook.md`.

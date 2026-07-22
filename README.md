# Refract OS

**[Landing page →](https://mr-pythoneer.github.io/refract-os/)**

An Ubuntu-based Linux distro that switches its whole personality on command — Gaming, AI, Server, Creative, or a polished macOS-style Normal mode — built around a local-first AI stack (Ollama + ComfyUI, [Crucible12](https://github.com/Mr-Pythoneer/Crucible12)-derived; the original port is preserved under `modes/ai/legacy-crucible12/`), not a cloud assistant bolted onto a browser.

**Status: scaffolded, audited, awaiting first hardware.** Every piece below has a first implementation and every external dependency has been web-verified, but nothing has run on real target hardware yet. The first real test is imminent: an OVH server (CPU build host) now, and the **RTX 5090 + 9950X3D build ~early August 2026**. See [TODO.md](TODO.md) for the live build checklist, [DESIGN.md](DESIGN.md) for the architecture (including what's deliberately *not* promised — no distro runs "every Windows app"), [`docs/first-hardware-runbook.md`](docs/first-hardware-runbook.md) for the ordered test plan, and [`docs/blackwell-readiness.md`](docs/blackwell-readiness.md) for the 5090-specific pre-flight. Run [`./preflight.sh`](preflight.sh) on any build host first.

## Layout

```
DESIGN.md          full architecture plan
TODO.md             live build checklist — the actual source of truth on progress
drivers/             Nvidia + AMD driver/microcode install scripts
modes/
  ai/                Ollama + ComfyUI local-AI stack (Crucible12-derived; legacy port under legacy-crucible12/)
  modectl/           the 5-mode switcher (distro-modectl)
  gaming/            Steam, Lutris, Proton-GE, Bottles, GameMode, MangoHud
  server/            SSH, Docker, Netdata
  creative/          FreeCAD, Blender, DaVinci Resolve, NVENC ffmpeg
  normal/            macOS-style theme + dock
iso/
  build.sh           live-build ISO pipeline, parameterized by hardware strain
  strains/           workstation / laptop / lowspec / server / handheld / cloud
  calamares/         installer config
  cloud-image/       qcow2 build path for the cloud strain
preflight.sh         build-host readiness check (run before iso/build.sh)
docs/                landing page + first-hardware-runbook.md + blackwell-readiness.md
```

## One system, five modes, six strains

- **Modes** (`modes/modectl/`) are a runtime switch — `distro-modectl switch gaming` — on one install. Every mode is available regardless of strain.
- **Strains** (`iso/strains/`) are a build-time hardware-class profile — what desktop environment (if any) and what packages ship by default. See `DESIGN.md` §5b for why this is bounded to x86_64 package/DE variants, not "every computer that might exist."

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the working norms — chiefly: verify external facts against primary sources, flag what's unverified, and add a `tests/` case for new pure-logic scripts. Run `./tests/run.sh` and `shellcheck` before pushing. After an install, `./verify-all.sh` runs every mode's sanity check in one pass.

## License

MIT — see [LICENSE](LICENSE). [NOTICE](NOTICE) credits the upstream projects this distro builds on without vendoring or forking.

# Crucible OS

**[Landing page →](https://mr-pythoneer.github.io/crucible-os/)**

An Ubuntu-based Linux distro that switches its whole personality on command — Gaming, AI, Server, Creative, or a polished macOS-style Normal mode — built around local-first AI (via [Crucible12](https://github.com/Mr-Pythoneer/Crucible12)), not a cloud assistant bolted onto a browser.

**Status: early design/scaffolding stage.** Every piece below has a first implementation, but nothing has run on real target hardware yet — see [TODO.md](TODO.md) for the live, itemized build checklist and [DESIGN.md](DESIGN.md) for the full architecture plan, including what's deliberately *not* promised (no distro claims to run "every Windows app" — that's not a real promise anywhere, including SteamOS or CrossOver).

## Layout

```
DESIGN.md          full architecture plan
TODO.md             live build checklist — the actual source of truth on progress
drivers/             Nvidia + AMD driver/microcode install scripts
modes/
  ai/                Crucible12 ported to Linux/systemd (local LLM coding agent)
  modectl/           the 5-mode switcher (distro-modectl)
  gaming/            Steam, Lutris, Proton-GE, Bottles, GameMode, MangoHud
  server/            SSH, Docker, Netdata
  creative/          FreeCAD, Blender, DaVinci Resolve, NVENC ffmpeg
  normal/            macOS-style theme + dock
iso/
  build.sh           live-build ISO pipeline, parameterized by hardware strain
  strains/           workstation / laptop / lowspec / server / handheld / cloud
  calamares/         installer config
docs/                this repo's landing page (GitHub Pages)
```

## One system, five modes, six strains

- **Modes** (`modes/modectl/`) are a runtime switch — `distro-modectl switch gaming` — on one install. Every mode is available regardless of strain.
- **Strains** (`iso/strains/`) are a build-time hardware-class profile — what desktop environment (if any) and what packages ship by default. See `DESIGN.md` §5b for why this is bounded to x86_64 package/DE variants, not "every computer that might exist."

## License

MIT — see [LICENSE](LICENSE). [NOTICE](NOTICE) credits the upstream projects this distro builds on without vendoring or forking.

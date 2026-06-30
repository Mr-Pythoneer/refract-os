# AI mode

Linux/systemd port of [Crucible12](https://github.com/Mr-Pythoneer/Crucible12) — see `DESIGN.md` §5 for the full rationale. Same model, same presets, same hardware-specific tuning (RTX 5090 + Ryzen 9 9950X3D + 64GB DDR5-6400) as the original Windows/PowerShell project. This directory just makes it the OS's native AI mode instead of something the user manually starts in a PowerShell window.

## What changed vs. the original

- `setup/*.ps1` → `setup/*.sh` (bash), same flags/defaults, same preset table
- `01-install-llamacpp`: **builds from source** instead of downloading a prebuilt release. Upstream llama.cpp only ships a prebuilt CUDA binary for Windows — Linux CUDA builds aren't distributed generically because they're coupled to the host's exact toolkit/driver version. This isn't a fallback, it's the correct Linux path.
- `llama-server` runs as a systemd unit (`systemd/crucible12@.service`, instantiated per preset) instead of a foreground PowerShell process
- `bin/distro-ai-preset` is the new control surface: `switch <preset>` stops whatever's running and starts the requested preset's unit
- `config/opencode.*.json` are unchanged — they only point at `localhost:8080`, which is OS-agnostic

## Install (run on the actual GPU machine — NOT this Mac, see DESIGN.md operating constraints)

```bash
sudo mkdir -p /opt/crucible12 && sudo chown "$USER" /opt/crucible12
cp -r modes/ai/* /opt/crucible12/
cd /opt/crucible12

./setup/01-install-llamacpp.sh
./setup/02-download-models.sh crucible      # or max | fast | reasoning | all
./setup/03-install-opencode.sh

sudo useradd -r -s /usr/sbin/nologin crucible12 || true
sudo chown -R crucible12:crucible12 /opt/crucible12
sudo cp systemd/crucible12@.service /etc/systemd/system/
sudo systemctl daemon-reload

sudo cp bin/distro-ai-preset /usr/local/bin/
sudo chmod +x /usr/local/bin/distro-ai-preset

sudo cp bin/distro-ai-ask bin/distro-ai-overlay bin/distro-ai-bind-hotkey /usr/local/bin/
sudo chmod +x /usr/local/bin/distro-ai-ask /usr/local/bin/distro-ai-overlay /usr/local/bin/distro-ai-bind-hotkey
distro-ai-bind-hotkey                       # binds <Super>space, run as the desktop user (not sudo)
/opt/crucible12/integrations/install.sh     # installs the Nautilus "ask AI about this file" script

distro-ai-preset switch crucible
distro-ai-preset status
```

Then, per-project:
```bash
cp /opt/crucible12/config/opencode.crucible.json ./opencode.json
opencode
```

## Hotkey overlay + file-manager integration

Both are thin clients on top of whatever preset is already running on
`localhost:8080` — `bin/distro-ai-ask` is the shared backend (one `curl`
call, OpenAI-compatible chat-completions shape), execution-tested against a
stub server covering the happy path, empty-prompt rejection, unreachable-server,
and malformed-response-shape cases.

- `bin/distro-ai-overlay` — `zenity`-based prompt/reply dialog, meant to be
  bound to a global keyboard shortcut. `bin/distro-ai-bind-hotkey [binding]`
  wires it to `<Super>space` by default via the documented GNOME
  `org.gnome.settings-daemon.plugins.media-keys` custom-keybinding
  relocatable-schema mechanism — same best-effort-but-undocumented-on-real-hardware
  caveat as `modes/modectl`'s `PINNED_APPS` dock pinning. Run it as the
  desktop user in their session, not via sudo.
- `integrations/nautilus-ask-ai` + `integrations/install.sh` — a real
  Nautilus (GNOME Files) "Scripts" entry, not a fabricated context-menu
  config. Nautilus's actual mechanism: any executable dropped into
  `~/.local/share/nautilus/scripts/` shows up under right-click → Scripts
  automatically, with the selected file's path passed via
  `NAUTILUS_SCRIPT_SELECTED_FILE_PATHS`. Reads the first 4KB of the selected
  file, asks the local model to describe it. `install.sh` does the one-line
  copy-and-chmod into place.

Both **need a live GNOME session to verify the dialogs/menu entry actually
render** — that part is unverified, consistent with every other live-desktop
caveat in this repo. The request/response plumbing itself (`distro-ai-ask`,
and `nautilus-ask-ai`'s file-reading/error-handling control flow) has been
execution-tested with bash 5 against a stub HTTP server and a stubbed
`zenity`, not just syntax-checked.

## Optional cloud fallback (explicit opt-in only)

`bin/distro-ai-cloud-toggle enable` switches the current project's OpenCode
config to route through Claude (cloud) instead of a local preset — for when
you want a stronger model and have connectivity, per DESIGN.md §5's
"explicit opt-in, never silently substituted in" stance (same principle as
OpenClaw's gateway). Requires you to set `ANTHROPIC_API_KEY` yourself; the
script refuses to proceed without it rather than failing silently later.

`config/opencode.claude-cloud.json`'s env-var interpolation syntax
(`"{env:ANTHROPIC_API_KEY}"`) is **OpenCode's documented mechanism** —
[OpenCode's config docs](https://opencode.ai/docs/config/) state "Use
`{env:VARIABLE_NAME}` to substitute environment variables," with
`"apiKey": "{env:ANTHROPIC_API_KEY}"` given as an example, and
`"npm": "@ai-sdk/anthropic"` is the correct provider package per the
models.dev registry OpenCode reads. (This was previously flagged as an
unverified guess; a web-verification pass confirmed it, so the caveat is
removed.) The one genuinely unverified part left is whether the literal
model id `claude-sonnet-4-6` is currently served — OpenCode accepts any
string as a model key, so it only matters at request time, not config-parse
time.

## Status

Ported but **not yet run end-to-end** — built without access to the target GPU hardware. **The RTX 5090 is arriving ~late July 2026, with the full build (5090 + 9950X3D) ready ~early August 2026** — so this is weeks from being testable, not months. Every external dependency here has been web-verified (driver branch, CUDA version, llama.cpp flags, HF model repos — see [Blackwell readiness](../../docs/blackwell-readiness.md)), but nothing has run on the real card. Needs verification once it's built:
- [ ] `01-install-llamacpp.sh` actually builds successfully against CUDA 12.8+ for sm_120
- [ ] Each preset's `run-*.sh` starts cleanly and `nvidia-smi` shows expected GPU utilization (use `benchmark.sh`)
- [ ] systemd unit (`crucible12@<preset>.service`) starts/stops correctly under the `crucible12` service user, with correct file permissions on `/opt/crucible12/models` and `/opt/crucible12/bin`
- [ ] `distro-ai-preset switch` correctly tears down the old preset before starting the new one (watch for port 8080 conflicts if the stop doesn't fully release before the start)

Do this verification on the GPU server, not a laptop — don't leave downloaded model weights or build artifacts sitting on local disk anywhere they don't need to be.

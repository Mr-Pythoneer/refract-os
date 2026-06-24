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

distro-ai-preset switch crucible
distro-ai-preset status
```

Then, per-project:
```bash
cp /opt/crucible12/config/opencode.crucible.json ./opencode.json
opencode
```

## Status

Ported but **not yet run end-to-end** — same caveat the original Crucible12 README carries: built without access to the target GPU hardware. **The hardware itself doesn't exist yet — target build is ~3 months out (ETA ~September 2026).** This is a known, expected gap, not a blocker on other work; everything below stays unchecked until that box is built. Needs verification once it exists:
- [ ] `01-install-llamacpp.sh` actually builds successfully against CUDA 12.8+ for sm_120
- [ ] Each preset's `run-*.sh` starts cleanly and `nvidia-smi` shows expected GPU utilization (use `benchmark.sh`)
- [ ] systemd unit (`crucible12@<preset>.service`) starts/stops correctly under the `crucible12` service user, with correct file permissions on `/opt/crucible12/models` and `/opt/crucible12/bin`
- [ ] `distro-ai-preset switch` correctly tears down the old preset before starting the new one (watch for port 8080 conflicts if the stop doesn't fully release before the start)

Do this verification on the GPU server, not a laptop — don't leave downloaded model weights or build artifacts sitting on local disk anywhere they don't need to be.

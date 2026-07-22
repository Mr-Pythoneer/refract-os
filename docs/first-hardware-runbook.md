# First-hardware test runbook

The ordered plan for the first real test sessions, so they're methodical
instead of improvised. Two tracks, because the hardware arrives in two pieces:

- **Track A — the OVH server (CPU-only, available first):** ISO builds + the
  installer + everything that does NOT need a GPU. This is where the entire
  `iso/` pipeline runs for the very first time.
- **Track B — the 5090 build (~early August 2026):** everything GPU-dependent —
  AI mode (Ollama + ComfyUI), real driver/NVENC, real Proton-GE game launches.

Both follow the project's **6-stage OS testing methodology**: (1) build
succeeds → (2) ISO boots → (3) installer works → (4) installed system boots
standalone → (5) our scripts function → (6) repeat across strains.

> **Disk-as-cache rule still applies to the OVH server.** It has more disk
> than the Mac, but still: once you've captured an ISO/log you care about,
> `rm -rf` the live-build working dirs (`chroot/ binary/ cache/ .build/`)
> rather than letting them pile up between runs. GitHub is the source of truth.

---

## Stage 0 — Pre-flight (on whichever host you're about to build on)

```bash
git clone https://github.com/Mr-Pythoneer/refract-os.git
cd refract-os
./preflight.sh                 # build-host readiness: tools, static checks, network, apt
```
**Pass:** "No blocking failures." Investigate any `[FAIL]` before going further;
`[WARN]`s on network/apt are usually fine (transient, or a repo not added yet).

---

## Track A — OVH server (CPU-only build host)

### Stage 1 — Build succeeds (the first-ever real `lb build`)

```bash
sudo apt-get update && sudo apt-get install -y live-build
cd iso
sudo ./build.sh workstation
```
**Pass:** `refract-os-workstation.iso` is produced.
**Expect to hit at least one real bug on this first pass** — nothing in `iso/`
has ever run `lb build`. Common first-run failure points: a package name not in
the enabled components (check `--archive-areas`), `lb config` flag drift vs the
installed live-build version, the casper-bottom hook + `update-initramfs`. Fix,
commit, re-run.

### Stage 2 — ISO boots (in a VM on the same server)

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils
qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 \
  -cdrom refract-os-workstation.iso -vnc :0
# connect a VNC viewer to <server-ip>:5900 (tunnel over SSH), or add -serial mon:stdio
```
**Pass:** GRUB → live session reaches a desktop (or login). **Check the
"Install Refract OS" icon is on the live desktop** (the casper-bottom hook).

### Stage 3 — Installer works

Launch Calamares from the live session (the desktop icon, or `sudo calamares`).
**Pass:** welcome → partition → user → install completes without a Python/QML
traceback. **`partition.conf` is the lowest-confidence config** (flagged in
`iso/calamares/README.md`) — diff it against Calamares' own
`partition/examples/` on the host if partitioning misbehaves. Confirm the
slideshow (`show.qml`) renders.

### Stage 4 — Installed system boots standalone

Reboot the VM off the virtual disk (remove the `-cdrom`).
**Pass:** the installed system boots to a desktop on its own; the user created
during install can log in.

### Stage 5 — Our scripts function (the non-GPU parts)

On the installed VM:
```bash
# Mode switcher (CPU/power/services — no GPU needed)
distro-modectl status
sudo distro-modectl switch server --yes      # verify --yes works non-interactively
distro-modectl status                         # must report "server"

# Server mode bundle
modes/server/setup/01-install-ssh.sh          # validates sshd -t BEFORE applying
modes/server/setup/02-install-docker.sh
modes/server/setup/03-install-netdata.sh
modes/server/setup/verify-server.sh

# Gaming/Creative SOFTWARE INSTALL ONLY (no GPU here — can't launch a game or
# test NVENC on the server; just confirm the installers run cleanly)
modes/gaming/setup/01-install-steam.sh        # multiverse detection now DEB822-aware
modes/gaming/setup/02-install-lutris.sh
modes/gaming/setup/03-install-wine-staging.sh
modes/creative/setup/01-install-freecad.sh    # Flatpak
```
**Pass:** each script completes; `verify-server.sh` is all green; `distro-modectl
switch server --yes` reports "server" and didn't prompt. **Known limits on a
CPU-only box:** `cpupower`/`powerprofilesctl` may warn if the VM doesn't expose
them; theme/dock (`modes/normal`) and the AI overlay need a real desktop, not a
headless VM — defer those to a box with a GPU + monitor.

### Stage 6 — Repeat across strains

```bash
sudo ./build.sh laptop && sudo ./build.sh lowspec && sudo ./build.sh server
# cloud strain uses a different delivery path:
sudo ./cloud-image/build-cloud-image.sh        # qcow2, not an ISO
```
**Pass:** each strain builds; `lowspec` boots LXQt not GNOME; `server`/`cloud`
are headless; the cloud qcow2 boots under QEMU with a cloud-init seed.

---

## Track B — 5090 build (GPU-dependent, ~early August 2026)

Do this on the real 5090 + 9950X3D box. **Start with
[`docs/blackwell-readiness.md`](blackwell-readiness.md)** — it has the full
verified pre-flight (open module, 570+ driver, CUDA, VRAM math) and its own
live checklist. The steps below are the ordered driver-of-record.

### B1 — Driver + microcode (the gate for everything else)

```bash
cd drivers
./install-nvidia.sh 580          # nvidia-driver-580-open (open module is MANDATORY for Blackwell)
./install-amd-microcode.sh
sudo reboot
./verify-drivers.sh
nvidia-smi                        # MUST list the RTX 5090
```
**Pass:** `nvidia-smi` shows the 5090. **If it says "No devices were found":**
the driver is either too old (<570) or not the `-open` variant — add the
graphics-drivers PPA and reinstall (see the readiness doc). Confirm Secure Boot
MOK enrollment if SB is on.

### B2 — AI mode (Ollama + ComfyUI — the biggest unverified piece)

Ollama installs as a system service; run distro-ai-setup as your normal user (config is per-user). See `modes/ai/README.md`.

```bash
cd ../modes/ai
sudo ./setup/01-install-ollama.sh     # Ollama runtime + system service
./setup/02-preload-models.sh coding   # pulls ONE model — the arg is the use-case (omitting it defaults to 'coding'; it does NOT pull everything)
distro-ai-model use coding            # loads qwen2.5-coder:32b, server on :11434
distro-ai-ask "write a bubble sort in rust"   # confirm the thin client answers
```
**Pass / tuning:** `nvidia-smi` shows VRAM in use; `distro-ai-ask` returns a
reply on `localhost:11434`. For a **70B** model (exceeds 32 GB) tune the offload
ratio: Ollama auto-offloads to CPU when a model exceeds VRAM; check the split with `ollama ps`
--estimate-only` first to preview the fit, expect ~6–12 tok/s. Then the rest:
```bash
distro-ai-model use vision            # qwen2.5vl:32b — attach an image, confirm it sees it
# auto-start the server on login:
sudo cp systemd/ollama.service /etc/systemd/system/   # (01-install-ollama.sh does this for you)
sudo systemctl daemon-reload && sudo systemctl enable --now ollama.service
# image generation (separate runtime):
./setup/03-install-comfyui.sh && ./setup/04-download-image-models.sh
distro-ai-image                       # ComfyUI web UI on :8188 — render a test image with FLUX.1-schnell / SDXL
```

### B3 — Gaming (real launches)

```bash
cd ../gaming
./setup/01-install-steam.sh
steam        # LAUNCH ONCE and let it finish first-run BEFORE step 04 (creates ~/.steam symlinks)
./setup/04-install-proton-ge.sh    # now refuses to run if Steam hasn't bootstrapped
./setup/06-install-gamemode-mangohud.sh
./setup/verify-gaming.sh
```
**Pass:** a real Proton-GE game launches; `gamemoderun`/`mangohud` overlay works;
`distro-modectl switch gaming` sets the performance governor + GPU perf state.

### B4 — Creative (NVENC + Resolve)

```bash
cd ../creative
./setup/05-install-ffmpeg-nvenc.sh
ffmpeg -hide_banner -encoders | grep nvenc        # h264/hevc/av1_nvenc present
# a real encode:
ffmpeg -f lavfi -i testsrc=size=1920x1080:rate=30 -t 5 -c:v hevc_nvenc out.mp4
./bin/distro-creative-scratch setup               # NVMe detection now works (df -l fix)
# DaVinci Resolve 21.x: download the .run from BMD (manual), then:
./setup/04-install-davinci-resolve.sh /path/to/downloaded.zip
```
**Pass:** the NVENC encode succeeds; `distro-creative-scratch` picks the real
NVMe (not `/var/tmp`); Resolve launches and sees the GPU.

### B5 — Live desktop bits (need the real GNOME session)

On the 5090 box's actual desktop (not SSH):
```bash
modes/normal/setup/03-apply-theme.sh
modes/ai/bin/distro-ai-bind-hotkey        # Super+Space overlay
modes/ai/integrations/install.sh          # Nautilus "ask AI about this file"
```
**Pass:** WhiteSur theme applies; the hotkey overlay queries `localhost:11434`
and shows a reply; the Nautilus action appears.

---

## What the OVH server canNOT do (so don't try)

The Game-2 server is **CPU-only** — no GPU. So Track B's items (AI inference,
NVENC, real game launches, GPU power-state pinning) cannot run there at all;
they're gated on the 5090 box. The server is for the build pipeline + installer
+ the CPU/service/software-install half of each mode. (See the memory note on
the GPU split: persistent CPU dev box + the 5090 for GPU work.)

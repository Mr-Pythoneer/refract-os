# RTX 5090 / Blackwell readiness

Everything 5090-specific that has to be right for AI mode, Creative mode, and
the driver layer, consolidated in one place. **The facts here were verified by
web research (mid-2026) against primary sources — Nvidia docs/forums, the
CUDA repo index, the llama.cpp server README, Hugging Face — but NONE of it has
been run on a real 5090 yet.** This is the pre-flight reference for when the
card arrives; the live checklist at the bottom is what actually closes that gap.

The 5090 is **Blackwell GB202, compute capability sm_120 (12.0)**.

## 1. Driver — two hard requirements

| Requirement | Why | Where it's handled |
|---|---|---|
| **Open kernel module** (`nvidia-driver-<v>-open`) | The closed proprietary module does **not** support Blackwell at all — `nvidia-smi` returns "No devices were found". | `drivers/install-nvidia.sh` defaults to `-open` packages |
| **Driver branch ≥ 570** | The 550 branch and older don't recognize the 5090. Production branch in mid-2026 is ~595; 570 is the floor. | explicit `./install-nvidia.sh 580` → `nvidia-driver-580-open` |

The open module also supports Turing (RTX 20) and newer, so defaulting to it is
correct for this project's target hardware, not a Blackwell-only hack.

If `ubuntu-drivers install nvidia` (the auto path) doesn't pull a new-enough
`-open` driver from the enabled repos, add the PPA and pin explicitly:

```bash
sudo add-apt-repository -y ppa:graphics-drivers/ppa
sudo apt-get update
./install-nvidia.sh 580
sudo reboot
nvidia-smi          # MUST list the RTX 5090 — if it says "No devices were found", the driver is too old or not -open
```

**Secure Boot:** `install-nvidia.sh` installs `mokutil` up front, reads the
real state, and only declares "no signing needed" on a definitive *disabled*.
If enabled, enroll the DKMS MOK (`/var/lib/shim-signed/mok/MOK.der`) — DKMS
then auto-signs `nvidia.ko` on every kernel update.

## 2. CUDA toolkit (for AI mode's llama.cpp build)

- **12.8 is the FIRST toolkit with sm_120 support** — so 12.8+ is mandatory for
  the 5090. (12.6 and earlier have no Blackwell support; claims that 12.4/12.5
  work are wrong.)
- **CUDA 13.x is current in 2026** and keeps sm_120 — use whichever is current;
  `cuda-toolkit-12-8` is a known-good floor.
- Install (verified URLs/names):
  ```bash
  wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i cuda-keyring_1.1-1_all.deb
  sudo apt-get update
  sudo apt-get install -y cuda-toolkit-12-8      # or a current cuda-toolkit-13-x
  ```

## 3. llama.cpp build + runtime (all flags verified current)

- Repo: `github.com/ggml-org/llama.cpp` (transferred from ggerganov Feb 2025).
- Build: `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 -DBUILD_SHARED_LIBS=OFF`
  — `GGML_CUDA` is the current option name (not the old `LLAMA_CUBLAS`/`LLAMA_CUDA`),
  and `120` is the correct compute capability for Blackwell.
- All `llama-server` flags the run scripts use are confirmed current:
  `-ngl 99`, `--n-cpu-moe N` (real, current — keeps the first N layers' MoE
  experts on CPU), `--flash-attn on` (tri-state on/off/auto is the current form),
  `--cache-type-k/-v q8_0`, `--jinja`, `--chat-template-kwargs`, `--ctx-size`,
  `--mlock`, sampling flags.
- The systemd unit now sets `LimitMEMLOCK=infinity` so `--mlock` actually pins
  the model under the unprivileged service user (otherwise it silently no-ops).

## 4. Models (Crucible12 presets) — all confirmed to exist

`Qwen3-Coder-Next` is a **real** public model (Qwen3-Next-80B-A3B coder finetune,
~80B total / 3B active) — this was flagged as a possible hallucination and
verified to be genuine.

| Preset | HF repo | Quant | Size | Notes |
|---|---|---|---|---|
| `crucible` | `unsloth/Qwen3-Coder-Next-GGUF` | `UD-Q4_K_XL` | ~49.6 GB (single top-level file) | default |
| `max` | `unsloth/Qwen3-Coder-Next-GGUF` | `UD-Q6_K_XL` | ~73 GB (in `UD-Q6_K_XL/` subfolder, split 3 parts) | downloader's recursive `siblings` list handles the subfolder |
| `fast` | `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF` | `UD-Q4_K_XL` | ~17.7 GB (single file) | fits fully in 32 GB VRAM |
| `reasoning` | `ggml-org/gpt-oss-120b-GGUF` | `mxfp4` | ~63 GB (split 3 parts) | secondary; Harmony tool-calling is flaky in OpenCode |

### VRAM math on the 32 GB 5090 (starting points, tune empirically)

The 5090 has **32 GB VRAM**. The hybrid presets put dense/attention/shared-expert
weights on the GPU and offload the *first N MoE layers' experts* to the 64 GB
system RAM via `--n-cpu-moe N`:

- `crucible` Q4: `--n-cpu-moe 16` default. Watch `nvidia-smi`; **raise** N if you
  hit CUDA OOM (more goes to RAM), **lower** N if you have spare VRAM headroom.
  Leave a few GB for the KV cache.
- `max` Q6: `--n-cpu-moe 26` (Q6 is ~23 GB larger than Q4, so more must offload).
- `reasoning` gpt-oss-120b: `--n-cpu-moe 20`.
- `fast` 30B: no offload (`-ngl 99` only) — fits fully on-GPU.

These N values are **unmeasured starting points** — the single most important
real-hardware tuning task. Generation on the hybrid presets is RAM-bandwidth
bound, so **DDR5 EXPO/XMP must be ON in BIOS** or throughput drops ~3×.

## 5. NVENC on Blackwell (Creative mode)

- The 5090 supports hardware NVENC encode for **H.264, HEVC, and AV1**.
- Blackwell-only features: **4:2:2 chroma** encode (H.264/HEVC/AV1), H.264 10-bit
  (High10), AV1 10-bit, and an **AV1 UHQ** mode.
- Full Blackwell feature support needs driver **R570+** and an ffmpeg built
  against **nv-codec-headers / Video Codec SDK 13.x** — the BtbN static GPL build
  `modes/creative/setup/05-install-ffmpeg-nvenc.sh` fetches is current enough.
  An older ffmpeg still runs nvenc but won't expose 4:2:2 / UHQ.

## 6. Live checklist — close these on the real card

- [ ] `nvidia-smi` lists the 5090 after installing `nvidia-driver-<v>-open` (v ≥ 570) + reboot
- [ ] `./verify-drivers.sh` passes (driver + microcode + Secure Boot state)
- [ ] `01-install-llamacpp.sh` compiles against CUDA 12.8+/13.x for sm_120, produces `llama-server`
- [ ] each preset's `run-*.sh` starts and `nvidia-smi` shows expected VRAM use (`benchmark.sh`)
- [ ] tune `--n-cpu-moe` per preset to fit 32 GB with KV-cache headroom (no CUDA OOM)
- [ ] confirm DDR5 EXPO/XMP is on; compare hybrid-preset tok/s with it on vs off
- [ ] `crucible12@<preset>.service` starts under the service user with `--mlock` actually pinning (check journal for mlock warnings)
- [ ] `distro-ai-preset switch` tears down the old preset cleanly (no port 8080 / VRAM contention)
- [ ] `ffmpeg -hide_banner -encoders | grep nvenc` lists h264/hevc/av1_nvenc; a real NVENC encode succeeds
- [ ] DaVinci Resolve 21.x launches and sees the GPU

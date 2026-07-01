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

## 2. CUDA — who needs it, and which version

The AI runtime is now **LM Studio** (bundles its own CUDA llama.cpp engine —
just keep its runtime updated in the app/Runtimes panel) + **ComfyUI** (needs a
CUDA PyTorch wheel you install). So you don't build llama.cpp yourself anymore.
What still matters:

- **ComfyUI's PyTorch must be a CUDA 12.8+ build for Blackwell** — install the
  stable **cu130** wheel (`--extra-index-url https://download.pytorch.org/whl/cu130`);
  cu128 is the floor, cu126/older produce black images / "no kernel" on a 5090.
  `03-install-comfyui.sh` does this.
- A standalone CUDA toolkit is optional (only if you compile CUDA code yourself).
  If you want it: 12.8 is the first toolkit with sm_120; 13.x is current.
  ```bash
  wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i cuda-keyring_1.1-1_all.deb && sudo apt-get update
  sudo apt-get install -y cuda-toolkit-12-8      # or a current cuda-toolkit-13-x
  ```
- The legacy Crucible12/llama.cpp build (which DID need the toolkit + these
  flags: `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120`) is preserved in
  `modes/ai/legacy-crucible12/` if you ever go back to it.

## 3. Models — LM Studio (LLMs) + ComfyUI (images)

Full catalog + exact repos/quants: `modes/ai/config/models.catalog.json` and
`modes/ai/README.md`. Highlights for the 32 GB card:

| Use-case | Model | Repo | Fit on 32 GB |
|---|---|---|---|
| coding / cad | Qwen2.5-Coder-32B | `lmstudio-community/Qwen2.5-Coder-32B-Instruct-GGUF` Q4_K_M ~20 GB | fully |
| day-to-day / know-it-all | Llama-3.3-70B | `lmstudio-community/Llama-3.3-70B-Instruct-GGUF` Q4_K_M ~42.5 GB | **partial CPU offload** (`--gpu 0.8`, ~6-12 tok/s) |
| vision | Qwen2.5-VL-32B (+mmproj) | `lmstudio-community/Qwen2.5-VL-32B-Instruct-GGUF` ~21 GB | fully |
| uncensored | Dolphin 2.7 Mixtral 8x7B | `TheBloke/dolphin-2.7-mixtral-8x7b-GGUF` ~26 GB | tight |
| image (ComfyUI) | FLUX.1-schnell / SDXL | `Comfy-Org/flux1-schnell` / `stabilityai/stable-diffusion-xl-base-1.0` | fully (FLUX fp8 ~12 GB) |

Note: `llama3.2-vision:11b` does **not** work in LM Studio (no `mllama` support)
→ the catalog substitutes Qwen2.5-VL-7B. FLUX.1-dev is gated → default is the
no-token FLUX.1-schnell.

### VRAM math on the 32 GB 5090 (starting points, tune empirically)

The 5090 has **32 GB VRAM**. In LM Studio, GPU offload is per-model via
`lms load <model> --gpu max|<ratio>`:

- Models ≤ ~26 GB (everything except the 70B) load fully on GPU: `--gpu max`.
- **Llama-3.3-70B** (~42.5 GB Q4) does NOT fit — load with a partial ratio
  (`--gpu 0.8`) so the overflow spills to the 64 GB DDR5. Use
  `lms load … --gpu 0.8 --estimate-only` FIRST to preview the fit, then tune the
  ratio down if it OOMs. Realistic ~6-12 tok/s once layers are on CPU.
- Leave a few GB of VRAM for the KV cache (grows with context length).

The 70B ratio is the single biggest real-hardware tuning task. DDR5 EXPO/XMP
should be ON in BIOS for the offloaded layers' bandwidth.

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
- [ ] `01-install-lmstudio.sh` installs LM Studio (llmster + lms CLI); `02-preload-models.sh` pulls the catalog
- [ ] each catalog model loads (`distro-ai-model use <case>`) and `nvidia-smi` shows expected VRAM use
- [ ] tune the Llama-3.3-70B offload ratio (`lms load … --gpu 0.8 --estimate-only`) so it fits 32 GB without OOM
- [ ] confirm DDR5 EXPO/XMP is on (helps the 70B's CPU-offloaded layers)
- [ ] `lmstudio.service` (user unit) auto-starts the OpenAI server on :8080; ComfyUI sees the 5090 (`torch.cuda.is_available()`)
- [ ] `distro-ai-model use <case>` loads + serves on :8080; the 70B loads with `--gpu` partial offload without OOM
- [ ] `ffmpeg -hide_banner -encoders | grep nvenc` lists h264/hevc/av1_nvenc; a real NVENC encode succeeds
- [ ] DaVinci Resolve 21.x launches and sees the GPU

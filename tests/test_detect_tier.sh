#!/usr/bin/env bash
# Tests for modes/ai/bin/distro-ai-detect-tier (hardware -> AI tier/profile/image)
# and the --from-config path of setup/04-download-image-models.sh.
#
# Fully hermetic: every hardware input is injected via env (REFRACT_VRAM_MIB,
# REFRACT_IS_LAPTOP, REFRACT_RAM_MB) and the GPU probes are neutralised
# (NVIDIA_SMI -> nonexistent, SYS_DRM_ROOT -> empty dir). Config is written into
# a throwaway XDG_CONFIG_HOME, so a real GPU / ~/.config is never touched.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DET="$REPO_ROOT/modes/ai/bin/distro-ai-detect-tier"
DL="$REPO_ROOT/modes/ai/setup/04-download-image-models.sh"

if ! command -v python3 >/dev/null 2>&1; then note "skipping (need python3)"; finish; exit $?; fi

empty="$(new_stubdir)"   # empty SYS_DRM_ROOT (no card*/mem_info_vram_total)

# run detect-tier with neutralised probes; caller sets REFRACT_* + XDG_CONFIG_HOME.
det() { NVIDIA_SMI=/nonexistent-smi SYS_DRM_ROOT="$empty" "$DET" "$@"; }

# --- VRAM -> tier mapping (write to a fresh config dir, read back the tier) ---
check_tier() {  # desc  vram_mib  expected_tier
  local cfg; cfg="$(new_stubdir)"
  XDG_CONFIG_HOME="$cfg" REFRACT_VRAM_MIB="$2" REFRACT_IS_LAPTOP=0 REFRACT_RAM_MB=32768 \
    det --yes >/dev/null 2>&1
  assert_eq "$1" "$3" "$(cat "$cfg/refract-ai/tier" 2>/dev/null || echo MISSING)"
  rm -rf "$cfg"
}
check_tier "vram 0 -> cpu"          0      cpu
check_tier "vram 4095 -> cpu"       4095   cpu
check_tier "vram 5120 (8GB-ish) -> entry" 5120  entry
check_tier "vram 8192 -> entry"     8192   entry
check_tier "vram 11263 -> entry"    11263  entry
check_tier "vram 11264 -> mid"      11264  mid
check_tier "vram 16384 -> mid"      16384  mid
check_tier "vram 20479 -> mid"      20479  mid
check_tier "vram 20480 (24GB) -> high" 20480 high
check_tier "vram 24564 (RTX4090) -> high" 24564 high
check_tier "vram 30719 -> high"     30719  high
check_tier "vram 30720 -> max"      30720  max
check_tier "vram 32607 (RTX5090) -> max" 32607 max

# --- profile: desktop -> power, laptop -> balance, forced overrides ---
check_profile() {  # desc  is_laptop  expected_profile  [extra det args...]
  local desc="$1" lap="$2" exp="$3"; shift 3
  local cfg; cfg="$(new_stubdir)"
  XDG_CONFIG_HOME="$cfg" REFRACT_VRAM_MIB=24564 REFRACT_IS_LAPTOP="$lap" REFRACT_RAM_MB=32768 \
    det --yes "$@" >/dev/null 2>&1
  assert_eq "$desc" "$exp" "$(cat "$cfg/refract-ai/profile" 2>/dev/null || echo MISSING)"
  rm -rf "$cfg"
}
check_profile "desktop defaults to power"        0 power
check_profile "laptop defaults to balance"       1 balance
check_profile "laptop --profile efficiency"      1 efficiency --profile efficiency
check_profile "laptop --profile power"           1 power      --profile power
check_profile "desktop --profile balance forced" 0 balance    --profile balance

# --- image default per tier (best -> download token) ---
check_image() {  # desc  vram_mib  expected_image  [extra det args...]
  local desc="$1" vram="$2" exp="$3"; shift 3
  local cfg; cfg="$(new_stubdir)"
  XDG_CONFIG_HOME="$cfg" REFRACT_VRAM_MIB="$vram" REFRACT_IS_LAPTOP=0 REFRACT_RAM_MB=32768 \
    det --yes "$@" >/dev/null 2>&1
  assert_eq "$desc" "$exp" "$(cat "$cfg/refract-ai/image" 2>/dev/null || echo MISSING)"
  rm -rf "$cfg"
}
check_image "cpu tier -> image none"        0      none
check_image "entry tier -> sdxl"            8192   sdxl
check_image "mid tier -> sdxl (best)"       12288  sdxl
check_image "high tier -> flux-dev (best)"  24564  flux-dev
check_image "max tier -> flux-dev (best)"   32607  flux-dev
check_image "force --image sdxl on max"     32607  sdxl --image sdxl

# --- forced --tier overrides detected VRAM ---
cfg="$(new_stubdir)"
XDG_CONFIG_HOME="$cfg" REFRACT_VRAM_MIB=0 REFRACT_IS_LAPTOP=0 REFRACT_RAM_MB=32768 \
  det --yes --tier high >/dev/null 2>&1
assert_eq "--tier high overrides 0 VRAM" "high" "$(cat "$cfg/refract-ai/tier" 2>/dev/null || echo MISSING)"
rm -rf "$cfg"

# --- invalid --tier is rejected ---
XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_VRAM_MIB=0 REFRACT_IS_LAPTOP=0 REFRACT_RAM_MB=32768 \
  det --yes --tier bogus >/dev/null 2>&1
assert_eq "invalid --tier exits non-zero" "1" "$?"

# --- --print writes nothing ---
cfg="$(new_stubdir)"
out="$(XDG_CONFIG_HOME="$cfg" REFRACT_VRAM_MIB=32607 REFRACT_IS_LAPTOP=0 REFRACT_RAM_MB=32768 det --print 2>&1)"
assert_eq "--print exits 0" "0" "$?"
assert_contains "--print reports the tier" "$out" "max"
if [ -f "$cfg/refract-ai/tier" ]; then fail "--print must not write config"; else pass "--print writes no config"; fi
rm -rf "$cfg"

# --- low-RAM warning ---
out="$(XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_VRAM_MIB=0 REFRACT_IS_LAPTOP=0 REFRACT_RAM_MB=2048 det --print 2>&1)"
assert_contains "warns on <4GB RAM" "$out" "WARNING"

# --- 04-download-image-models.sh --from-config honours image=none (no downloads) ---
cfg="$(new_stubdir)"; mkdir -p "$cfg/refract-ai"; printf 'none\n' > "$cfg/refract-ai/image"
home="$(new_stubdir)"   # no ComfyUI here; image=none must exit before that check
out="$(XDG_CONFIG_HOME="$cfg" HOME="$home" "$DL" --from-config 2>&1)"; rc=$?
assert_eq "04 --from-config none exits 0" "0" "$rc"
assert_contains "04 --from-config none downloads nothing" "$out" "Nothing to download"
rm -rf "$cfg" "$home"

# --- 04 --from-config flux-dev parses the choice (then fails: no ComfyUI here) ---
cfg="$(new_stubdir)"; mkdir -p "$cfg/refract-ai"; printf 'flux-dev\n' > "$cfg/refract-ai/image"
home="$(new_stubdir)"
out="$(XDG_CONFIG_HOME="$cfg" HOME="$home" "$DL" --from-config 2>&1)"; rc=$?
assert_contains "04 reads image=flux-dev from config" "$out" "image=flux-dev"
assert_eq "04 fails cleanly when ComfyUI is absent" "1" "$rc"
rm -rf "$cfg" "$home"

# --- ultra tier threshold + image default ---
check_tier "vram 46079 -> max"        46079  max
check_tier "vram 46080 -> ultra"      46080  ultra
check_tier "vram 49140 (48GB) -> ultra" 49140 ultra
check_tier "vram 98304 (96GB) -> ultra" 98304 ultra
check_image "ultra tier -> flux-dev"  49140  flux-dev

# --- multi-GPU homogeneous pooling (sum same-name group, not max) ---
gpu_case() {  # desc  gpu_list  ram_mb  expect_tier  expect_vram_mib
  local cfg; cfg="$(new_stubdir)"
  XDG_CONFIG_HOME="$cfg" REFRACT_GPU_LIST="$2" REFRACT_IS_LAPTOP=0 REFRACT_RAM_MB="$3" \
    NVIDIA_SMI=/nonexistent-smi SYS_DRM_ROOT="$empty" "$DET" --yes >/dev/null 2>&1
  assert_eq "$1 (tier)" "$4" "$(cat "$cfg/refract-ai/tier" 2>/dev/null || echo MISSING)"
  [ -n "$5" ] && assert_eq "$1 (vram_mib)" "$5" "$(cat "$cfg/refract-ai/vram_mib" 2>/dev/null || echo MISSING)"
  rm -rf "$cfg"
}
gpu_case "single 48GB workstation -> ultra"      "49140:NVIDIA RTX 6000 Ada Generation" 131072 ultra 49140
# The reported GPU name must be the group compute_vram actually POOLED, not the
# first card probed: on an APU + dGPU box the iGPU carveout is probed first, so a
# positional name printed the iGPU's name next to the dGPU's VRAM.
cfg="$(new_stubdir)"
XDG_CONFIG_HOME="$cfg" REFRACT_GPU_LIST="2048:AMD GPU 0x15bf;24560:AMD GPU 0x744c" \
  REFRACT_IS_LAPTOP=0 REFRACT_RAM_MB=65536 NVIDIA_SMI=/nonexistent-smi SYS_DRM_ROOT="$empty" \
  "$DET" --yes >/dev/null 2>&1
assert_contains "APU+dGPU names the dGPU that set the tier" \
  "$(grep '^gpu=' "$cfg/refract-ai/detected" 2>/dev/null || echo MISSING)" "0x744c"
assert_not_contains "APU+dGPU does not name the iGPU carveout" \
  "$(grep '^gpu=' "$cfg/refract-ai/detected" 2>/dev/null || echo MISSING)" "0x15bf"
assert_eq "APU+dGPU tiers on the dGPU's VRAM" "high" "$(cat "$cfg/refract-ai/tier" 2>/dev/null || echo MISSING)"
rm -rf "$cfg"
gpu_case "2x48GB same model pooled -> 96GB ultra" "49140:NVIDIA RTX 6000 Ada Generation;49140:NVIDIA RTX 6000 Ada Generation" 262144 ultra 98280
gpu_case "2x RTX 5090 pooled 64GB -> ultra"      "32607:NVIDIA GeForce RTX 5090;32607:NVIDIA GeForce RTX 5090" 131072 ultra 65214
gpu_case "single RTX 5090 -> stays max"          "32607:NVIDIA GeForce RTX 5090" 65536 max 32607
# mixed-vendor: the tier assert alone is non-distinguishing (a broken cross-group
# sum -> 73700 MiB would ALSO be ultra); the vram_mib assert (49140, not 73700) is
# the real guard that homogeneous grouping did not pool across vendors.
gpu_case "mixed vendor NOT pooled (largest group)" "49140:NVIDIA RTX 6000 Ada;24560:AMD Radeon RX 7900 XTX" 131072 ultra 49140

# --- datacenter guard -> Server mode ---
out="$(XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_GPU_LIST="81559:NVIDIA H100 80GB HBM3" NVIDIA_SMI=/nonexistent-smi SYS_DRM_ROOT="$empty" "$DET" --print 2>&1)"; rc=$?
assert_eq "H100 datacenter guard exits 3" "3" "$rc"
assert_contains "H100 guard names Server mode" "$out" "Server mode"
assert_contains "H100 guard names distro-modectl" "$out" "distro-modectl switch server"

out="$(XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_GPU_LIST="196608:AMD Instinct MI300X" NVIDIA_SMI=/nonexistent-smi SYS_DRM_ROOT="$empty" "$DET" --print 2>&1)"; rc=$?
assert_eq "MI300X datacenter guard exits 3" "3" "$rc"

# regression (review #1): a datacenter card with "NVL" in the name must NOT bypass
# the guard just because of the NVL substring. Only H100/H200 NVL are downgraded.
out="$(XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_GPU_LIST="81920:NVIDIA A100 NVL" NVIDIA_SMI=/nonexistent-smi SYS_DRM_ROOT="$empty" "$DET" --print 2>&1)"; rc=$?
assert_eq "A100 NVL still hits datacenter guard (exit 3)" "3" "$rc"
out="$(XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_GPU_LIST="196608:NVIDIA HGX B200 NVL72" NVIDIA_SMI=/nonexistent-smi SYS_DRM_ROOT="$empty" "$DET" --print 2>&1)"; rc=$?
assert_eq "HGX B200 NVL72 still hits datacenter guard (exit 3)" "3" "$rc"

# non-numeric REFRACT_VRAM_MIB is rejected cleanly (review #6), not a py traceback
out="$(XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_VRAM_MIB=lots "$DET" --print 2>&1)"; rc=$?
assert_eq "non-numeric REFRACT_VRAM_MIB exits 1" "1" "$rc"
assert_contains "non-numeric REFRACT_VRAM_MIB explains" "$out" "must be an integer"
assert_not_contains "non-numeric REFRACT_VRAM_MIB: no py traceback" "$out" "Traceback"

# --tier override bypasses the guard (user's explicit call)
cfg="$(new_stubdir)"
XDG_CONFIG_HOME="$cfg" REFRACT_GPU_LIST="81559:NVIDIA H100 80GB HBM3" REFRACT_RAM_MB=524288 \
  NVIDIA_SMI=/nonexistent-smi SYS_DRM_ROOT="$empty" "$DET" --yes --tier ultra >/dev/null 2>&1
assert_eq "H100 + --tier ultra bypasses guard" "ultra" "$(cat "$cfg/refract-ai/tier" 2>/dev/null || echo MISSING)"
rm -rf "$cfg"

# REFRACT_ALLOW_DATACENTER=1 bypasses the guard, tiers by VRAM
cfg="$(new_stubdir)"
XDG_CONFIG_HOME="$cfg" REFRACT_GPU_LIST="81559:NVIDIA H100 80GB HBM3" REFRACT_ALLOW_DATACENTER=1 REFRACT_RAM_MB=524288 \
  NVIDIA_SMI=/nonexistent-smi SYS_DRM_ROOT="$empty" "$DET" --yes >/dev/null 2>&1
assert_eq "ALLOW_DATACENTER bypasses guard -> ultra" "ultra" "$(cat "$cfg/refract-ai/tier" 2>/dev/null || echo MISSING)"
rm -rf "$cfg"

# NVL datacenter-in-workstation is allowed-with-warning (continues, does not exit 3)
cfg="$(new_stubdir)"
out="$(XDG_CONFIG_HOME="$cfg" REFRACT_GPU_LIST="143771:NVIDIA H200 NVL" REFRACT_RAM_MB=262144 \
  NVIDIA_SMI=/nonexistent-smi SYS_DRM_ROOT="$empty" "$DET" --yes 2>&1)"; rc=$?
assert_eq "H200 NVL allowed (exit 0)" "0" "$rc"
assert_eq "H200 NVL -> ultra tier" "ultra" "$(cat "$cfg/refract-ai/tier" 2>/dev/null || echo MISSING)"
assert_contains "H200 NVL warns about NVL" "$out" "NVL"
rm -rf "$cfg"

# --- Intel Arc: integrated (tiered by shared RAM, floored at cpu) vs discrete --
# Both probes are injected: REFRACT_LSPCI (lspci -nn text) and
# REFRACT_VULKAN_SUMMARY (vulkaninfo --summary text), so no Intel hardware, no
# lspci and no Vulkan userspace are needed. NOTE both fixtures are branded "Arc" —
# Meteor Lake's iGPU really is called "Intel Arc Graphics" — so the ONLY thing
# separating them is the PCI address (an iGPU is always at 00:02.x). A name match
# would call the iGPU discrete.
LSPCI_IGPU='00:02.0 VGA compatible controller [0300]: Intel Corporation Meteor Lake-P [Intel Arc Graphics] [8086:7d55] (rev 08)'
LSPCI_DGPU='00:02.0 VGA compatible controller [0300]: Intel Corporation Raptor Lake-S GT1 [UHD Graphics 770] [8086:a780] (rev 04)
03:00.0 VGA compatible controller [0300]: Intel Corporation DG2 [Arc A770] [8086:56a0] (rev 08)'
VK_ARC='	GPU0:
		apiVersion         = 1.3.267
		driverVersion      = 23.2.1
		deviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
		deviceName         = Intel(R) Arc(tm) Graphics (MTL)'
# The iGPU+dGPU box as vulkaninfo really shows it: the iGPU is listed FIRST, so
# the Vulkan name is the wrong device to describe the discrete card with.
VK_DGPU='	GPU0:
		deviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
		deviceName         = Intel(R) UHD Graphics 770
	GPU1:
		deviceType         = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
		deviceName         = Intel(R) Arc(tm) A770 Graphics (DG2)'

# arc_tier: desc  lspci_text  ram_mb  expected_tier
arc_tier() {
  local cfg; cfg="$(new_stubdir)"
  XDG_CONFIG_HOME="$cfg" REFRACT_VRAM_MIB=0 REFRACT_IS_LAPTOP=1 REFRACT_RAM_MB="$3" \
    REFRACT_LSPCI="$2" REFRACT_VULKAN_SUMMARY="$VK_ARC" det --yes >/dev/null 2>&1
  assert_eq "$1" "$4" "$(cat "$cfg/refract-ai/tier" 2>/dev/null || echo MISSING)"
  rm -rf "$cfg"
}
# usable = RAM - 6 GiB headroom. The cpu floor is the regression guard: without
# it a 4-8GB Intel laptop tiered 'entry' (7-8B models) while the SAME box with no
# iGPU correctly tiered 'cpu' — an iGPU shares that RAM, it does not add any.
arc_tier "Arc iGPU, 4GB RAM (0 usable) -> cpu"    "$LSPCI_IGPU" 4096  cpu
arc_tier "Arc iGPU, 8GB RAM (2 usable) -> cpu"    "$LSPCI_IGPU" 8192  cpu
arc_tier "Arc iGPU, 12GB RAM (6 usable) -> entry" "$LSPCI_IGPU" 12288 entry
arc_tier "Arc iGPU, 16GB RAM (10 usable) -> entry" "$LSPCI_IGPU" 16384 entry
arc_tier "Arc iGPU, 32GB RAM (26 usable) -> mid"  "$LSPCI_IGPU" 32768 mid

# A DISCRETE Arc must NOT be tiered by system RAM: it has its own VRAM, which
# nothing can probe (mem_info_vram_total is amdgpu-only). 64GB of RAM would give
# an iGPU 'mid'; the A770 must land on the honest 'entry' floor instead.
arc_tier "discrete Arc, 64GB RAM -> entry floor (not RAM-tiered)" "$LSPCI_DGPU" 65536 entry
arc_tier "discrete Arc, 8GB RAM -> entry floor (not RAM-tiered)"  "$LSPCI_DGPU" 8192  entry

# ...and it must say so rather than reporting the iGPU story.
out="$(XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_VRAM_MIB=0 REFRACT_IS_LAPTOP=0 REFRACT_RAM_MB=65536 \
  REFRACT_LSPCI="$LSPCI_DGPU" REFRACT_VULKAN_SUMMARY="$VK_DGPU" det --print 2>&1)"
assert_contains "discrete Arc report calls it discrete" "$out" "discrete Intel GPU"
assert_not_contains "discrete Arc is not reported as sharing system RAM" "$out" "shares system RAM"
assert_contains "discrete Arc report admits VRAM is not probeable" "$out" "not probeable"
assert_contains "discrete Arc report points at the --tier override" "$out" "--tier mid"
# The card is named from the lspci line that proved it discrete. vulkaninfo lists
# the iGPU first on this box, so naming it from there would describe the wrong
# device — the same defect as reporting a pooled group by its first-probed card.
assert_contains "discrete Arc names the discrete card" "$out" "Arc A770"
assert_not_contains "discrete Arc does not name the iGPU beside it" "$out" "UHD Graphics 770"

# The iGPU story is still told for a real iGPU.
out="$(XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_VRAM_MIB=0 REFRACT_IS_LAPTOP=1 REFRACT_RAM_MB=32768 \
  REFRACT_LSPCI="$LSPCI_IGPU" REFRACT_VULKAN_SUMMARY="$VK_ARC" det --print 2>&1)"
assert_contains "Arc iGPU reports shared system RAM" "$out" "shares system RAM"
assert_not_contains "Arc iGPU is not called discrete" "$out" "discrete Intel GPU"

# At the cpu floor the iGPU is still used, so the report must not claim there is
# no usable GPU — the tier is a RAM verdict, not a "we found nothing" verdict.
out="$(XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_VRAM_MIB=0 REFRACT_IS_LAPTOP=1 REFRACT_RAM_MB=8192 \
  REFRACT_LSPCI="$LSPCI_IGPU" REFRACT_VULKAN_SUMMARY="$VK_ARC" det --print 2>&1)"
assert_contains "cpu-floored iGPU says the iGPU is still used" "$out" "The Arc iGPU is still used"
assert_not_contains "cpu-floored iGPU does not claim no GPU was detected" "$out" "No usable dedicated VRAM detected"

# Mesa's llvmpipe is a software rasterizer, not a usable Arc: still cpu, with a
# warning — an Intel VGA line alone must never be enough.
out="$(XDG_CONFIG_HOME="$(new_stubdir)" REFRACT_VRAM_MIB=0 REFRACT_IS_LAPTOP=1 REFRACT_RAM_MB=32768 \
  REFRACT_LSPCI="$LSPCI_IGPU" REFRACT_VULKAN_SUMMARY='	GPU0:
		deviceName         = llvmpipe (LLVM 15.0.7, 256 bits)' det --print 2>&1)"
assert_contains "llvmpipe-only warns it is not a usable Arc" "$out" "WARNING"
assert_not_contains "llvmpipe-only does not claim an Arc iGPU" "$out" "Arc iGPU"

rm -rf "$empty"
finish

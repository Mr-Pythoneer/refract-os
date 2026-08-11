# Refract OS — partial deep-audit results (run wf_01240341-758)

Captured 2026-08-11. The workflow was stopped early at the user's request:
120 agents started, 107 returned. **48 raw findings** from 11 of 12 domain
finders, and 96 adversarial verdicts had landed before the stop.

IMPORTANT: these are RAW finder output. The verify phase pairs two skeptics
per finding and had not completed for every one of them, so this list is NOT a
confirmed fix list. Re-verify before acting on any single item.

Of the 96 verdicts that did land, 11 were REFUTED (11%) — a lower refute rate than expected, but the phase was cut off mid-flight, so
coverage is uneven: some findings below carry two verdicts, some carry one, and
some carry none at all. The synthesis, dedup and completeness-critic phases never
ran, so expect duplicates across domains and no cross-checking against the fixes
already landed this session.

---

## 1. [HIGH] 02-preload-models.sh still defaults to the 'max' tier and pulls a 20GB model on an undetected box
- **Where:** `modes/ai/setup/02-preload-models.sh`:35
- **Category:** dangerous-default
- **Trigger:** Any run of ./setup/02-preload-models.sh with no ~/.config/refract-ai/tier — i.e. detect-tier was never run, or it exited 3 on the datacenter guard (distro-ai-detect-tier:397), or the user followed 01-install-ollama.sh's 'Next:' list out of order. TIER becomes 'max' -> CLASS_ORDER=(high low cpu) (line 92); vram_mib is also absent so VRAM_MIB=0 and fits() ungates everything (line 130), so the 'high' class is taken unconditionally.
- **Consequence:** An 8GB-VRAM laptop runs `ollama pull qwen2.5-coder:32b` — a 20GB download that cannot fit its GPU. Worse, the two tools then disagree in exactly the case 02-preload's own comment (lines 155-162) says the VRAM gate exists to prevent: distro-ai-model with no recorded tier deliberately falls back to 'entry' (distro-ai-model:44-46, `TIER="entry"` … "no tier recorded"), so the very next `distro-ai-model use coding` resolves qwen2.5-coder:7b and starts a SECOND download. 20GB of bandwidth and disk wasted. The fix for this exact bug was applied to distro-ai-model (commit f160364) but not to its documented mirror, which is the script that actually downloads.
- **Proposed fix:** Mirror distro-ai-model exactly: when neither $REFRACT_AI_TIER nor $CONFIG_HOME/tier yields a value, set TIER="entry" and print the same stderr nudge ("no tier recorded — assuming 'entry'. Run 'distro-ai-detect-tier'"), and update the header comment on line 13 ("else 'max'") to match.

```
[ -n "$TIER" ] || TIER="${REFRACT_AI_TIER:-$(cat "$CONFIG_HOME/tier" 2>/dev/null || echo max)}"   # line 35
# line 45: VRAM_MIB="${REFRACT_VRAM_MIB:-$(cat "$CONFIG_HOME/vram_mib" 2>/dev/null || echo 0)}"
# line 130 (fits): [ "$VRAM_MIB" -gt 0 ] || return 0          # unknown -> don't gate
```

## 2. [HIGH] 03-install-comfyui.sh installs a CUDA-only PyTorch on every machine, including the Intel Arc flagship target and all AMD boxes
- **Where:** `modes/ai/setup/03-install-comfyui.sh`:52
- **Category:** hardware-mismatch
- **Trigger:** Any non-Nvidia machine whose tier maps to an image model, running `distro-ai-setup --install` (which calls this unconditionally at distro-ai-setup:94 whenever IMAGE != none) or `distro-modectl modes enable ai` -> run_mode_setup -> `distro-ai-setup --install --yes`. Concretely: the stated first flash target, an Intel Arc X1 Carbon with 32GB RAM (detect-tier tiers it 'mid' via tier_for_igpu_ram, and default_image_token('mid') returns 'sdxl', so IMAGE != none); or any AMD Radeon detected through /sys/class/drm/card*/device/mem_info_vram_total (e.g. a 24GB card -> tier 'high' -> IMAGE=flux-dev).
- **Consequence:** ~3GB of CUDA wheels are installed on a machine with no CUDA device; torch.cuda.is_available() is False, so ComfyUI silently falls back to CPU and SDXL/FLUX take minutes per image (effectively unusable). The script's own closing diagnostic (lines 68-69) then misdirects the user — "your Nvidia driver/CUDA is too old for Blackwell — see drivers/install-nvidia.sh" — on a box that has no Nvidia GPU at all. This is the same multi-GB dead-weight mistake 01-install-ollama.sh:38-40 explicitly avoided for the ROCm runner bundle.
- **Proposed fix:** Pick the wheel index by detected vendor rather than hardcoding cu130: read ~/.config/refract-ai/detected (gpu= / intel_arc= / intel_discrete=, written by distro-ai-detect-tier:580-593) or probe nvidia-smi / amdgpu sysfs — cu130 for Nvidia, https://download.pytorch.org/whl/rocm6.x for amdgpu, and for Intel either the XPU wheels or refuse with a clear message. distro-ai-setup should likewise skip steps 3/4 (and detect-tier should record image=none) when no supported diffusion backend exists.

```
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130
# no vendor branch anywhere in the file; header line 7: "Installs the PyTorch CUDA wheel for the RTX 5090"
```

## 3. [HIGH] 04-download-image-models.sh --from-config downloads three image models when the user picked one (~50GB instead of ~17GB)
- **Where:** `modes/ai/setup/04-download-image-models.sh`:48
- **Category:** unwanted-download
- **Trigger:** Any high/max/ultra tier box. models.catalog.{high,max,ultra}.json set image.best = "flux1-dev", so distro-ai-detect-tier:482 records IMAGE=flux-dev — both non-interactively (--yes) and as choice 1, the default, in the interactive menu that is captioned "Image generation (pick ONE to preload…)" (distro-ai-detect-tier:552). distro-ai-setup:95 then runs this script with --from-config.
- **Consequence:** Selecting one model downloads four artifacts by this script's own size labels: SDXL base ~7GB (line 77) + FLUX text encoders clip_l/t5xxl_fp16 ~10GB (line 82) + flux1-schnell-fp8 ~17GB (line 87) + flux1-dev-fp8 ~17GB (line 100) ≈ 50GB, with no size warning and no prompt — under `distro-modectl modes enable ai` this runs fully unattended. That is on top of the tier's ~20GB LLM, and it contradicts modes/ai/README.md:172 ("Nothing downloads ~200GB") and README.md's note ² that the installer defaults to FLUX.1-schnell, not dev.
- **Proposed fix:** Make --from-config exclusive: 'sdxl' -> SDXL only; 'flux-schnell' -> encoders + schnell + VAE only; 'flux-dev' -> encoders + dev + VAE only (no SDXL, no schnell). Keep the cumulative behaviour only for the flagless default invocation, and print the aggregate GB figure before the first download the way 02-preload-models.sh:191 does.

```
sdxl)         WANT_SDXL=true;  WANT_SCHNELL=false; WANT_DEV=false ;;
        flux-schnell) WANT_SDXL=true;  WANT_SCHNELL=true;  WANT_DEV=false ;;
        flux-dev)     WANT_SDXL=true;  WANT_SCHNELL=true;  WANT_DEV=true  ;;
# contradicting the header, lines 9-11: "--from-config reads the image choice … and downloads only that, so the setup wizard fetches exactly what the user picked."
```

## 4. [HIGH] The disk installer ships onto every installed system and is pinned to the new user's dock
- **Where:** `iso/build.sh`:204
- **Category:** strain-leak/installer-lifecycle
- **Trigger:** Any non-headless strain (workstation / laptop / lowspec / handheld). The `calamares` package list at :200 installs Calamares into the live chroot, and :204 writes the launcher into config/includes.chroot/usr/share/applications/ — i.e. both land in the squashfs. Calamares' own exec sequence (iso/calamares/settings.conf:29-46: partition, mount, unpackfs, machineid, fstab, locale, keyboard, localecfg, users, shellprocess@modes, displaymanager, networkcfg, hwclock, grubcfg, bootloader, umount) contains no `packages`/removal module, and shellprocess@modes runs modes/modectl/distro-apply-mode-selection, which only touches /etc/refract/enabled-modes. unpackfs copies the whole squashfs to the target, so the binary and the .desktop persist. The casper-bottom hook only ADDS a Desktop copy in the live overlay; nothing removes the /usr/share/applications entry from the target. install-smoke.yml:115,121 confirms both are in the squashfs. Nothing in the tree deletes them post-install.
- **Consequence:** Reboot after a real install and the GNOME dock's last pinned icon is "Install Refract OS" (dconf favorite-apps is compiled into the image by hooks/0200-refract-identity.chroot:116 `dconf update`), plus an "Install Refract OS" entry in the app grid. Clicking it on the already-installed machine raises a polkit password prompt and, on success, opens Calamares' partitioner against the disk the user is currently running from. Every desktop install ships a one-click path to repartitioning itself, and the dock of a freshly installed OS advertises the installer as a first-class app.
- **Proposed fix:** Remove the installer from the target, don't just hide it. Add a `packages` module to iso/calamares/settings.conf's exec sequence (after unpackfs, before umount) with `try_remove: [calamares]`, or extend the existing shellprocess@modes step to `rm -f /usr/share/applications/install-refract-os.desktop` in the target root. Separately, drop 'install-refract-os.desktop' from favorite-apps in iso/branding/dconf/local.d/00-refract — the live session already gets its launcher on the Desktop from casper-bottom/25-refract-install-icon, so the dock pin only ever benefits the installed system, where it must not exist.

```
build.sh:200  echo "calamares" > "$PACKAGE_LISTS/calamares.list.chroot"
build.sh:204  cat > "$INCLUDES/usr/share/applications/install-refract-os.desktop" <<EOF
              [Desktop Entry] ... Exec=pkexec calamares ... Categories=System;
build.sh:513  cp "$REPO_ROOT/iso/branding/dconf/local.d/00-refract" "$INCLUDES/etc/dconf/db/local.d/00-refract"
iso/branding/dconf/local.d/00-refract:  favorite-apps=['firefox_firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'org.gnome.Settings.desktop', 'install-refract-os.desktop']
```

## 5. [HIGH] Wayland re-enable probe treats hybrid Intel+dGPU laptops as "non-Intel", re-arming the exact modeset hang it exists to prevent
- **Where:** `iso/config/hooks/0400-polish.chroot`:119
- **Category:** correctness
- **Trigger:** Any laptop/workstation strain (0400 is only stripped for server/cloud/lowspec) on hybrid graphics — an Intel iGPU driving the internal panel plus a discrete NVIDIA or AMD card. lspci lists BOTH a "VGA compatible controller [0300]: Intel …" line and an NVIDIA/AMD line, so the grep matches on the discrete card and the oneshot comments out WaylandEnable=false before gdm starts. This is the default configuration of essentially every Optimus/muxless ThinkPad, Dell XPS, and gaming laptop.
- **Consequence:** GDM boots under Wayland on precisely the machines whose panel is driven by the Intel iGPU — the hardware class the workaround was written for. The user gets the splash→login hang that commits 0400 documents at lines 81-86 as "one of the most common real-hardware GDM-hang causes". The hook's own comment at lines 111-114 states the invariant it believes it upholds — "the failure mode is always safe: anything uncertain leaves Xorg on (the config the X1 needs), never Wayland on a machine that hangs" — and the code inverts it for the most common uncertain case. Nothing catches it: verify-boot-fixes.yml asserts WaylandEnable=false in the squashfs (lines 91-94) but never inspects /usr/libexec/refract-gdm-wayland-scope, and QEMU/virtio-gpu boot-smoke has no Intel iGPU at all.
- **Proposed fix:** Make the probe Intel-exclusionary rather than dGPU-inclusive: after building $gpus, bail out unconditionally if an Intel display controller is present, e.g. insert `printf '%s\n' "$gpus" | grep -qiE 'Intel|\[8086:' && exit 0` before the NVIDIA/AMD test. Only a machine with NO Intel display controller should get Wayland back, which is what the stated fail-safe requires.

```
gpus=$(lspci -nn 2>/dev/null | grep -Ei 'VGA compatible|3D controller|Display controller' || true)
if printf '%s\n' "$gpus" | grep -qiE 'NVIDIA|\[10de:|Advanced Micro Devices|\[1002:'; then
    for f in /etc/gdm3/custom.conf /etc/gdm3/daemon.conf; do
        [ -f "$f" ] && sed -i 's/^WaylandEnable=false/#WaylandEnable=false  # re-enabled: non-Intel GPU/' "$f" || true
    done
fi
```

## 6. [HIGH] uefi-boot.yml still carries the exact `\bgdm3?\b` / bare `login:` hole that was just removed from boot-smoke and install-smoke
- **Where:** `.github/workflows/uefi-boot.yml`:116
- **Category:** assertion-that-cannot-fail
- **Trigger:** Any ISO booted under OVMF whose display manager fails — the Wayland/Xorg/i915 class this repo repeatedly fixes. systemd writes `Failed to start gdm3.service - GNOME Display Manager.` (matches `\bgdm3?\b` under `-i`), `Dependency failed for graphical.target.` (matches `graphical\.target`), and `pam_unix(login:session):` (matches bare `login:`). Any one sets ok=1. The `-append`-free ISO path also means `casper` was deliberately dropped from this alternation but the two weaker markers were left in.
- **Consequence:** uefi-boot prints "PASS: Refract reached graphical userspace under real UEFI firmware (OVMF)" for an image that never reached a desktop. That green run is the sole evidence behind the public release-note claim in build-iso.yml:354 ("hybrid image, OVMF-verified in CI"), so users flash a UEFI ISO whose desktop never comes up on the strength of a check that could not have failed. Commits 99f5a78/1856fba fixed this alternation in boot-smoke.yml and install-smoke.yml but never propagated it here.
- **Proposed fix:** Replace line 116 with the hardened trio used in boot-smoke.yml:177-179 — GRAPHICAL='reached target graphical|started (gnome display manager|gdm)', CONSOLE='^[[:alnum:]_.-]+ login:', DM_FAIL='failed to start (gnome display manager|gdm)|gdm3?\.service: (main process exited|failed with result)|dependency failed for .*display manager' — dropping `graphical\.target`, `\bgdm3?\b` and bare `login:` entirely, and invalidate a pass when DM_FAIL matches.

```
if grep -qiE "reached target graphical|graphical\.target|started gnome display manager|\bgdm3?\b|login:" uefi-serial.log 2>/dev/null; then ok=1; fi
...
[ -n "$ok" ] || { echo "FAIL: no graphical-userspace signal ..." >&2; exit 1; }
echo "PASS: Refract reached graphical userspace under real UEFI firmware (OVMF)."
```

## 7. [HIGH] A gdm crash-loop still reports PASS: the DM_FAIL guard is overridden by the very marker a crash-loop emits
- **Where:** `.github/workflows/boot-smoke.yml`:205
- **Category:** false-pass
- **Trigger:** gdm starts and immediately dies (the WaylandEnable / ubuntu-xorg / intel_drv failure modes verify-boot-fixes.yml exists to catch). systemd logs `Started GNOME Display Manager.` on each restart attempt AND `gdm.service: Main process exited, status=1/FAILURE`. The `started (gnome display manager|gdm)` alternative alone sets ok_systemd=graphical even though `reached target graphical` never appears; DM_FAIL then matches, but the `[ "$ok_systemd" = graphical ]` branch demotes it to a NOTE.
- **Consequence:** boot-smoke prints "PASS: kernel booted, casper mounted the live system, systemd reached the graphical userspace target" for an image with no working desktop, and the NOTE asserts "graphical.target was still reached" on evidence that only proves gdm was launched. install-smoke.yml:477+489-496 is byte-identical and additionally writes "INSTALL VERIFY PASSED: installed disk reached the graphical target" to $GITHUB_STEP_SUMMARY — the loud marker added specifically so a broken install can't hide behind the green check now certifies one.
- **Proposed fix:** Distinguish the two alternatives: set ok_systemd=target only on `reached target graphical`, and ok_systemd=dm-only on `started (gnome display manager|gdm)`. In the DM_FAIL block, allow the NOTE-and-continue path only when ok_systemd=target; a dm-only match plus DM_FAIL must clear ok_systemd and fail. Apply the same change at install-smoke.yml:477-496.

```
GRAPHICAL='reached target graphical|started (gnome display manager|gdm)'
...
if grep -qiE "$DM_FAIL" serial.log 2>/dev/null; then
  if [ "$ok_systemd" = graphical ]; then
    echo "NOTE: a display-manager failure was logged but graphical.target was still reached (systemd restarted it) — see serial.log."
  else
    ...; ok_systemd=""
```

## 8. [HIGH] Cloud qcow2 ships the build host's /etc/resolv.conf — booted instances have no working DNS
- **Where:** `iso/cloud-image/build-cloud-image.sh`:88
- **Category:** correctness
- **Trigger:** Any real run of the script. The header (lines 12-15) requires "a real Debian/Ubuntu Linux host"; on Ubuntu 22.04/24.04 /etc/resolv.conf is the systemd-resolved stub symlink, so `cp` dereferences it and writes a *regular file* containing `nameserver 127.0.0.53` into the image. The guest is `debootstrap --variant=minbase noble` plus only linux-image-generic, grub-pc, cloud-init, cloud-guest-utils, openssh-server (line 102) with --no-install-recommends, so systemd-resolved is not installed and nothing is listening on 127.0.0.53. (On a build host with a plain LAN resolver the image instead ships e.g. `nameserver 192.168.1.1`, unreachable from any cloud.)
- **Consequence:** Every instance launched from refract-os-cloud.qcow2 boots with permanently broken name resolution: `apt-get update`, cloud-init's ssh-import-id, any user-data script fetching a URL, and NTP all fail with "Temporary failure in name resolution". Because /etc/resolv.conf is a real file rather than a symlink, later installing systemd-resolved does not fix it either — its postinst leaves an existing regular file alone. Ubuntu's default cloud.cfg does not run cloud-init's `resolv_conf` module, so cloud-init will not rewrite it. This is the one thing a headless cloud image must get right and it is silently wrong.
- **Proposed fix:** Treat the copied resolv.conf as chroot-build scaffolding, not image content: after the last chroot apt invocation and before the unmount at line 198, `rm -f "$MOUNT_DIR/etc/resolv.conf"` and re-create the distro-normal symlink (`ln -sfn ../run/systemd/resolve/stub-resolv.conf "$MOUNT_DIR/etc/resolv.conf"`) *and* add systemd-resolved to the chroot install list on line 102 so the stub actually exists. If you'd rather not pull in resolved, just delete the file and let netplan/cloud-init supply one — an absent resolv.conf is recoverable, a stale 127.0.0.53 one is not.

```
line 88:  cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"

…and nothing ever removes it. The next touch of that path is the unmount at line 198-199:
    umount "$MOUNT_DIR/dev" "$MOUNT_DIR/proc" "$MOUNT_DIR/sys"
    umount "$MOUNT_DIR"
followed by
    qemu-img convert -O qcow2 -c "$RAW_IMG" "$OUT_QCOW2"
```

## 9. [HIGH] install-nvidia.sh / verify-drivers.sh report "no Nvidia GPU" when pciutils is simply not installed
- **Where:** `drivers/install-nvidia.sh`:34
- **Category:** detection
- **Trigger:** Run either script on an image that does not ship pciutils, on a machine that does have an Nvidia GPU. `grep -rn pciutils` over the repo returns nothing — pciutils is in no package list (iso/config/package-lists/base.list.chroot, nor any iso/strains/*.list.chroot). The qcow2 cloud image is the concrete case: it is `debootstrap --variant=minbase` plus five packages (build-cloud-image.sh:102) and cloud.list.chroot's two, and build-cloud-image.sh:167 copies the whole drivers/ tree into it (`cp -a "$_repo_root/modes" "$_repo_root/drivers" "$MOUNT_DIR/opt/distro/"`). A GPU cloud instance booted from that image has an Nvidia card and no lspci. With `set -euo pipefail` the missing-command exit 127 is swallowed by the `if !`, so it is indistinguishable from a clean no-match.
- **Consequence:** On a GPU instance, /opt/distro/drivers/install-nvidia.sh exits 1 with a flatly false statement about the user's hardware ("No Nvidia GPU detected") and installs nothing — the user is told the machine has no GPU rather than that the probe tool is missing. Worse, verify-drivers.sh then prints a yellow [SKIP] "not applicable", counts zero failures, and exits 0 (line 59, `[ "$FAIL" -eq 0 ]`), so the documented verification step declares a machine with no Nvidia driver at all fully healthy.
- **Proposed fix:** Guard the probe the way distro-ai-detect-tier:220 already does: `command -v lspci >/dev/null 2>&1 || { echo "pciutils not installed — cannot probe for a GPU; apt-get install pciutils" >&2; exit 2; }` in install-nvidia.sh, and make verify-drivers.sh print a distinct "[SKIP] cannot probe (pciutils missing)" rather than asserting no GPU. A vendor-ID fallback works without pciutils: `grep -qil 0x10de /sys/bus/pci/devices/*/vendor`. Also add `pciutils` to iso/strains/cloud.list.chroot and to build-cloud-image.sh:102 so the cloud image can probe its own hardware.

```
drivers/install-nvidia.sh:34-37
    if ! lspci | grep -qi nvidia; then
        echo "No Nvidia GPU detected via lspci. Aborting — nothing to install." >&2
        exit 1
    fi

drivers/verify-drivers.sh:26-33
    if lspci 2>/dev/null | grep -qi nvidia; then
        …
    else
        echo -e "\033[33m[SKIP]\033[0m no Nvidia GPU detected via lspci — not applicable"
    fi

Contrast the repo's own convention, modes/ai/bin/distro-ai-detect-tier:220
        command -v lspci >/dev/null 2>&1 || return 0
```

## 10. [HIGH] Full 7.19 MiB wallpaper set staged into strains that can never display it (lowspec/LXQt, server, cloud)
- **Where:** `iso/build.sh`:432
- **Category:** dead-payload-size
- **Trigger:** `./iso/build.sh lowspec` (also `server` and `cloud`). lowspec installs lubuntu-desktop (iso/strains/lowspec.list.chroot:8) — LXQt/SDDM, which reads neither org.gnome.desktop.background nor the gdm dconf db; nothing in the repo writes an LXQt/pcmanfm-qt or SDDM background. server's own manifest opens with "Server/headless strain: no desktop environment package at all."
- **Consequence:** The lowspec ISO carries 7.19 MiB of desktop wallpapers no session on it can ever render. That is 7x the entire remaining release margin: the measured lowspec ISO is 2,143,289,344 B against the 2,145,386,496 B (2045 MiB) gate in .github/workflows/build-iso.yml:291, i.e. exactly 1 MiB of headroom. Any future 1 MiB of real content demotes lowspec from a raw .iso to the .iso.xz rung while 7.19 MiB of unusable PNG sits in the squashfs. Secondary user-visible effect on lowspec: `distro-modectl switch gaming` prints "Applied Gaming look: ... + wallpaper" (distro-modectl:437, and every gsettings call is `|| true`) while the LXQt desktop background never changes.
- **Proposed fix:** Wrap lines 429-445 in the existing strain guard, e.g. `if [[ ! " ${HEADLESS_STRAINS[*]} " == *" $STRAIN " * ]]` for the headless pair, and for lowspec either (a) skip the wallpaper staging entirely and drop the GNOME-only gschema/gdm dconf copies for NON_GNOME_STRAINS, or (b) if per-mode wallpapers are wanted on LXQt, stage a downscaled set (1366x768 is ample for the lowspec target) and teach distro-modectl's apply_theme to write pcmanfm-qt's wallpaper key when gsettings' GNOME schema is absent. Option (a) alone converts lowspec's 1 MiB margin into ~8.2 MiB.

```
429: mkdir -p "$INCLUDES/usr/share/backgrounds/refract" "$INCLUDES/usr/share/refract"
430: # The full per-mode wallpaper set (base/gaming/ai/server/creative/normal) —
431: # distro-modectl swaps between them on `switch <mode>`.
432: cp "$REPO_ROOT"/branding/out/wallpapers/*.png "$INCLUDES/usr/share/backgrounds/refract/"
...
445: ln -sf refract/base.png "$INCLUDES/usr/share/backgrounds/refract-os.png"

No $STRAIN guard anywhere in this block, and nothing removes them later (iso/config/hooks/0500-slim.chroot only clears apt/tmp). The ONLY consumers of these paths in the whole tree are GNOME-specific:
  iso/branding/glib/99_refract.gschema.override:2  picture-uri='file:///usr/share/backgrounds/
```

## 11. [HIGH] macOS flashing command uses GNU-only `status=progress`, so BSD `dd` aborts without writing the stick
- **Where:** `docs/thinkpad-x1-carbon.md`:28
- **Category:** wrong-command
- **Trigger:** Any user flashing the `laptop` ISO from a Mac by following docs/thinkpad-x1-carbon.md §1 — i.e. the documented path for Refract's own first real-hardware target (the X1 Carbon Gen 13 that booted 2026-07-16), on the same Apple-Silicon Mac this repo is developed on.
- **Consequence:** macOS `dd` is BSD, not GNU: `status=progress` is not a valid operand. The command exits immediately with `dd: unknown operand status` (or `unknown status progress`) and writes zero bytes. The user sees an error, has an unwritten USB, and no guidance — while the sibling doc docs/install.html:185 says the exact opposite in prose ("the macOS `dd` is BSD, not GNU, so `status=progress` / `oflag=` don't exist there") and docs/install.html:190-191 gives the correct form plus the Ctrl-T progress workaround. Two docs in one repo ship mutually incompatible macOS commands.
- **Proposed fix:** Replace line 28 with the form install.html already documents: `sudo dd if=refract-os-laptop.iso of=/dev/rdisk4 bs=1m` and add the same note that macOS dd prints nothing until done, press Ctrl-T for progress. Better still, link to docs/install.html step 3 rather than maintaining a second copy of the dd invocation that can drift again.

```
- **From macOS:** [balenaEtcher](https://etcher.balena.io/) is the no-footgun choice
  (pick the ISO, pick the USB, Flash). Or the CLI:
  ```sh
  diskutil list                      # find your USB, e.g. /dev/disk4
  diskutil unmountDisk /dev/disk4
  sudo dd if=refract-os-laptop.iso of=/dev/rdisk4 bs=4m status=progress
  ```
```

## 12. [HIGH] Installer walkthrough omits the Calamares "Modes" page, so following it verbatim leaves four of five modes disabled
- **Where:** `docs/utm-guide.md`:63
- **Category:** incomplete-instructions
- **Trigger:** Any install that follows this walkthrough — VM or real hardware. iso/calamares/settings.conf:19-27 shows the real page order as `welcome, locale, keyboard, partition, users, packagechooser@modes, summary`: a "Modes" page sits between Users and Summary and is never mentioned. docs/thinkpad-x1-carbon.md:64-67 redirects real-hardware users to this same section ("Welcome → Location → Keyboard → Partitions: Erase disk → Users → Install → Restart"), so the omission propagates to the hardware path too.
- **Consequence:** The user hits an unlisted page. Because iso/calamares/modules/packagechooser_modes.conf:28 is `mode: optionalmultiple`, clicking Next with nothing ticked is legal and yields an empty selection; modes/modectl/distro-apply-mode-selection then writes a header-only /etc/refract/enabled-modes ("an empty selection is a legitimate 'plain desktop = normal only' outcome"). On first boot, this very guide's §6 tells them to run `sudo distro-modectl switch normal|gaming|creative|server|ai` — and modes/modectl/distro-modectl:460-462 rejects four of those five with "Mode 'gaming' is not enabled on this system." The guide's own next step contradicts the install it just walked the user through.
- **Proposed fix:** Insert the missing page as step 6 in docs/utm-guide.md §5 — "**Modes** — tick which of Gaming / AI / Server / Creative this machine is for; Normal is always installed. Leaving all four unticked installs a plain desktop and `distro-modectl switch <mode>` will refuse those modes afterwards." — renumber Summary/Progress/Finish, and correct "~7-page" to 8. Add the same page name to the arrow list in docs/thinkpad-x1-carbon.md:66-67.

```
"It's a
~7-page wizard; here's each page and what to pick for a throwaway VM:

1. **Welcome** … 2. **Location** … 3. **Keyboard** … 4. **Partitions** … 5. **Users** … 6. **Summary** — review; nothing is written until you click **Install**. → **Install**."
```

## 13. [HIGH] Docker repo line uses VERSION_CODENAME, which Refract sets to "forge" — server mode's Docker install always fails and poisons apt
- **Where:** `modes/server/setup/02-install-docker.sh`:21
- **Category:** correctness
- **Trigger:** Any real Refract OS install or cloud qcow2 (every strain — the identity block is unconditional), running the documented step `modes/server/setup/02-install-docker.sh` (modes/server/README.md:7, docs/first-hardware-runbook.md:90). Sourcing /etc/os-release sets VERSION_CODENAME=forge, so the emitted suite is `forge`, not `noble`.
- **Consequence:** /etc/apt/sources.list.d/docker.list points at https://download.docker.com/linux/ubuntu dists/forge, which does not exist. The `sudo apt-get update` on the next line exits 100 ("does not have a Release file") and `set -euo pipefail` aborts the script — Docker never installs, so Server mode's headline component is missing and verify-server.sh:23-24 fails. Worse, the broken docker.list is left behind, so every later `apt-get update` on that machine errors too: 01-install-steam.sh:18, 06-install-gamemode-mangohud.sh:9, modes/normal/setup/03-apply-theme.sh:31 and the user's own updates all now fail on a box that was working before Server mode was set up. Note the sibling script already got this right: 03-install-wine-staging.sh:10 uses `CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"`.
- **Proposed fix:** Mirror 03-install-wine-staging.sh: after `. /etc/os-release`, set `CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"` and emit `$CODENAME stable` in the deb line. (UBUNTU_CODENAME=noble is already written by both builders precisely so downstream Ubuntu-repo logic keeps working.)

```
. /etc/os-release
...
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $VERSION_CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update

(iso/build.sh:389,402-403 writes into /etc/os-release AND /usr/lib/os-release:
  VERSION_CODENAME=forge
  UBUNTU_CODENAME=noble
iso/cloud-image/build-cloud-image.sh:129,138-139 writes the identical pair.)
```

## 14. [HIGH] Lutris PPA is added with add-apt-repository, which resolves the series from the Refract identity ("forge") — no such Launchpad suite
- **Where:** `modes/gaming/setup/02-install-lutris.sh`:11
- **Category:** correctness
- **Trigger:** Running the documented `./setup/02-install-lutris.sh` (modes/gaming/README.md:7, docs/first-hardware-runbook.md:97) on any installed Refract OS. add-apt-repository builds the PPA entry from `aptsources.distro.get_distro().codename`, which comes from /usr/lib/os-release VERSION_CODENAME (or /etc/lsb-release DISTRIB_CODENAME) — both are `forge` on every build, not `noble`.
- **Consequence:** Either add-apt-repository refuses outright (unknown distro template / series not published by the PPA), or — the more likely path — it writes a PPA source with `Suites: forge`, and the `sudo apt-get update` on the next line then 404s on ppa.launchpadcontent.net/lutris-team/lutris/ubuntu/dists/forge and exits nonzero, aborting the script under set -e. Lutris (a headline Gaming-mode component, README.md:32) never installs, verify-gaming.sh:22 fails, and in the second case a permanently-broken PPA entry is left in /etc/apt/sources.list.d/ that breaks every subsequent apt-get update on the box. Unlike 01-install-steam.sh:12-15, this call is unguarded and always runs.
- **Proposed fix:** Don't let add-apt-repository infer the series. Either write the DEB822/one-line PPA entry explicitly using `${UBUNTU_CODENAME:-$VERSION_CODENAME}` from /etc/os-release plus the PPA signing key, or pass the resolved Ubuntu codename to add-apt-repository (`add-apt-repository -y "deb https://ppa.launchpadcontent.net/lutris-team/lutris/ubuntu $CODENAME main"`). Same one-line codename resolution as 03-install-wine-staging.sh:10.

```
set -euo pipefail
...
sudo add-apt-repository -y ppa:lutris-team/lutris
sudo apt-get update

(Both identity sources add-apt-repository can read say "forge":
 iso/build.sh:402  VERSION_CODENAME=forge          -> lsb_release/os-release codename
 iso/build.sh:413-416  DISTRIB_ID=Refract / DISTRIB_CODENAME=forge)
```

## 15. [HIGH] Server mode disables gdm and no other mode ever re-enables it — the machine boots to a text console forever
- **Where:** `modes/modectl/profiles/server.conf`:6
- **Category:** state-inconsistency
- **Trigger:** Any desktop strain (workstation/laptop/lowspec/handheld). User runs `sudo distro-modectl switch server --yes` (or answers y to the CONFIRM_DISPLAY_MANAGER_STOP prompt), then later runs `sudo distro-modectl switch normal` — or any of gaming/ai/creative — and reboots.
- **Consequence:** `systemctl disable gdm` removes gdm's `[Install]` symlinks including the `display-manager.service` alias, so graphical.target has nothing to pull in. Switching back to Normal prints `Applied Normal look: ...` and `Now in: Normal mode` and writes `normal` to /run/distro-modectl/current-mode, but the box still boots to a bare text console on every subsequent boot. The mode round-trip is silently one-way. Nothing in modes/server/README.md, modes/modectl/README.md, the profile NOTES, or the confirm prompt tells the user that `sudo systemctl enable gdm` is the only way back, so a non-expert user sees a permanently broken desktop after using a documented, reversible-looking feature.
- **Proposed fix:** Make the display-manager toggle symmetric. Either add a `RESTORE_DISPLAY_MANAGER=true` key to gaming/ai/creative/normal.conf and have apply_services issue a deferred `systemctl enable <dm>` (no `--now`, mirroring the deferred disable) for whichever of gdm/gdm3/sddm/lightdm has an installed unit; or record the DM that was disabled into a sidecar state file next to STATE_FILE at disable time and re-enable exactly that unit on the next non-server switch. Also extend the confirm_or_abort prompt at distro-modectl:481 to state the undo command.

```
server.conf:6  `DISABLE_SERVICES=(gdm)`
normal.conf:5 / gaming.conf:5 / ai.conf:5 / creative.conf:5  `ENABLE_SERVICES=()`
distro-modectl:275-277
        if [[ "$svc" =~ ^(gdm|gdm3|sddm|lightdm)$ ]]; then
            systemctl disable "$svc" 2>/dev/null || true
distro-modectl:506  `apply_services ENABLE_SERVICES DISABLE_SERVICES`
apply_services only ever acts on the two arrays the CURRENT profile supplies. A grep for `enable gdm` / `systemctl enable.*gdm` across the whole repo returns nothing — no profile, no setup script, no hook, no systemd unit ever restores the display manager.
```

## 16. [HIGH] apply_pinned_apps overwrites the whole GNOME favorite-apps list and no mode ever restores it, permanently destroying the user's dock
- **Where:** `modes/modectl/distro-modectl`:344
- **Category:** data-loss
- **Trigger:** Fresh install (dock = Firefox, Files, Terminal, Settings) or any user who has customized their dock. Run `distro-modectl switch gaming` (or `switch creative`) once, then `distro-modectl switch normal`.
- **Consequence:** The dock is replaced by exactly `steam.desktop, net.lutris.Lutris.desktop, com.usebottles.bottles.desktop` — Firefox, Files, Terminal, Settings and every pin the user added are gone. Switching back to Normal/AI/Server does not restore them because those profiles' empty PINNED_APPS hits the early return, so the loss is permanent and silent; only a hand-typed `dconf reset /org/gnome/shell/favorite-apps` recovers it. This also breaks DESIGN.md §4's stated contract that a switch "atomically swaps a coherent bundle of: ... default-pinned apps" — the pins accumulate destructively instead of swapping.
- **Proposed fix:** Either (a) give normal/ai/server a baseline PINNED_APPS equal to the dconf default in iso/branding/dconf/local.d/00-refract:19 so every mode writes a complete, intentional list; or (b) treat an empty PINNED_APPS as "restore the system default" and issue `run_as_user dconf reset /org/gnome/shell/favorite-apps` instead of returning at line 331. Note that tests/mode-mechanism.sh:283-285 (`assert_no_pin` / `log_lacks ... favorite-apps`) currently codifies the broken behaviour and must be updated with the fix.

```
distro-modectl:331  `[ ${#apps[@]} -eq 0 ] && return 0`
distro-modectl:341-344
    joined=$(printf "'%s', " "${apps[@]}")
    joined="[${joined%, }]"
    ...
    run_as_user gsettings set org.gnome.shell favorite-apps "$joined" || echo "WARNING: gsettings call failed ..."
`gsettings set favorite-apps` REPLACES the list; there is no read-merge and no backup. The image ships a non-locked default in iso/branding/dconf/local.d/00-refract:19:
    favorite-apps=['firefox_firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'org.gnome.Settings.desktop', 'install-refract-os.desktop']
normal.conf:10, ai.conf:11 and server.conf:10 all have `PINNED_APPS=()`, so the line-331 ear
```

## 17. [HIGH] test_apply_mode_selection.sh runs the destructive APPLY_HARD_REMOVAL path against unredirectable absolute system paths
- **Where:** `tests/test_apply_mode_selection.sh`:59
- **Category:** hermeticity / destructive test
- **Trigger:** Any run of `tests/run.sh` (or `bash tests/test_apply_mode_selection.sh`) by a user who can unlink from /usr/local/bin on a machine where Refract is installed — i.e. `sudo bash tests/run.sh`, or the same overlay+chroot the CI already uses (.github/workflows/install-smoke.yml:239 copies tests/ into the shipped squashfs and runs the suite there; only the `setpriv --reuid 1000` on that line currently prevents the deletion). iso/build.sh:348-363 shows the image really does ship /usr/local/bin/distro-ai-{model,image,ask,overlay,cloud-toggle,bind-hotkey,detect-tier,setup} and distro-creative-{scratch,color}, and the wallpapers ship at /usr/share/backgrounds/refract/<mode>.png.
- **Consequence:** Running the test suite as root on an installed Refract system deletes all eight AI CLIs and both Creative CLIs from /usr/local/bin plus the ai/server/creative wallpapers — the very files the rest of the suite and the running desktop depend on. Conversely, in today's uid-1000 CI chroot the `rm -f /usr/local/bin/distro-ai-*` returns EACCES and distro-apply-mode-selection's `set -euo pipefail` aborts the loop at m=ai, so `server` and `creative` are never processed at all — yet all four assertions (which only inspect gaming and ai) still pass. The test therefore proves less than it claims while carrying a live destructive path.
- **Proposed fix:** Make the two remaining paths overridable in modes/modectl/distro-apply-mode-selection (e.g. BIN_DIR="${BIN_DIR:-/usr/local/bin}" and WALLPAPER_DIR="${WALLPAPER_DIR:-/usr/share/backgrounds/refract}"), point them at the fixture from tests/test_apply_mode_selection.sh:59, and add assertions that a fake $hd/bin/distro-ai-ask and $hd/backgrounds/ai.png are removed while the gaming ones survive. Also assert the helper's exit status is 0 so a mid-loop abort can no longer hide behind `>/dev/null 2>&1`.

```
tests/test_apply_mode_selection.sh:56-63
  hd="$(new_stubdir)"
  for m in gaming ai server creative; do mkdir -p "$hd/modes/$m"; done
  ENABLED_MODES_FILE="$hd/enabled-modes" DISTRO_ROOT="$hd" APPLY_HARD_REMOVAL=1 \
      "$APPLY" "gaming" >/dev/null 2>&1

but modes/modectl/distro-apply-mode-selection:108-116 only redirects TWO of its four deletion targets through DISTRO_ROOT:
      rm -rf "${DISTRO_ROOT:?}/modes/$m"
      rm -f  "${DISTRO_ROOT:?}/modes/modectl/profiles/$m.conf"
      rm -f  "/usr/local/bin/distro-$m-"*
      rm -f  "/usr/share/backgrounds/refract/$m.png"

The file's own header (tests/test_apply_mode_selection.sh:4-5) claims: "ENABLED_MODES_FILE + DISTRO_ROOT are env-overrid
```

## 18. [HIGH] Encrypted installs are offered but produce an unbootable system: exec sequence never rebuilds the target initramfs
- **Where:** `iso/calamares/settings.conf`:46
- **Category:** correctness
- **Trigger:** Any GUI strain (workstation/laptop/lowspec/handheld), any mode. User ticks "Encrypt system" on the Erase-disk page — which Calamares 3.3.5 offers by default (upstream partition.conf: "If nothing is specified, LUKS is enabled in automated modes", and this repo has no `enableLuksAutomatedPartitioning: false`) — or creates a LUKS volume by hand (`allowManualPartitioning: true`, partition.conf:39).
- **Consequence:** The install reports success; the machine never boots again. Three modules are missing from the exec list: `luksbootkeyfile` (creates /crypto_keyfile.bin and adds it as a LUKS key slot), `initramfscfg` (copies encrypt_hook / encrypt_hook_nokey into the target's /usr/share/initramfs-tools/hooks/), and `initramfs` (runs update-initramfs in the target). Nothing else in Calamares regenerates an initramfs, so the installed /boot/initrd.img-* is verbatim the casper initrd that live-build baked into the squashfs — it has never seen the new /etc/crypttab or the LUKS UUID. First boot of the installed disk drops to a busybox `(initramfs)` prompt ("ALERT! /dev/mapper/luks-<uuid> does not exist"). The Plymouth LUKS passphrase callback restored in b71fdb1 is dead code on installed systems for the same reason. Secondary: even unencrypted installs keep the live casper initrd forever, with no resume= and no target-specific module set, until some later package upgrade happens to trigger update-initramfs. Verified against Lubuntu's noble settings.conf (same Calamares 3.3.5, same /cdrom/casper unpackfs source), whose exec list reads `... localecfg / luksbootkeyfile / users / ... / hwclock / ... / initramfscfg / initramfs / grubcfg / ... / bootloader`. Note also that `cryptsetup-initramfs` appears in no package list under iso/ (grep for "crypt" hits only plymouth), so the hook has nothing to embed even if it were installed.
- **Proposed fix:** Add `luksbootkeyfile` after `- localecfg` (settings.conf:36) and `initramfscfg` + `initramfs` between `- hwclock` (45) and `- grubcfg` (46). Add `iso/calamares/modules/fstab.conf` with `crypttabOptions: luks,keyscript=/bin/cat` — that keyscript is what pairs the crypttab entry with the keyfile luksbootkeyfile writes on Debian/Ubuntu (Lubuntu ships exactly this). Add `cryptsetup-initramfs` to the shared package list.

```
settings.conf:44-48
  - networkcfg
  - hwclock
  - grubcfg
  - bootloader
  - umount

partition.conf:41-43
# Encryption generation (luks1|luks2). luks1 is the safe default — not all
# GRUB builds boot LUKS2/argon2id.
luksGeneration: luks1
```

## 19. [MEDIUM] distro-ai-setup --yes silently re-detects and overwrites an explicitly forced tier/profile/image with no backup
- **Where:** `modes/ai/bin/distro-ai-setup`:50
- **Category:** config-clobber
- **Trigger:** A user overrides a mis-detected tier the way the tool itself instructs — e.g. a discrete Arc A770, where detect-tier floors the tier and prints "Set it from the card's spec, e.g.: distro-ai-detect-tier --tier mid" (distro-ai-detect-tier:510) — and later anything runs distro-ai-setup non-interactively. `distro-modectl modes enable ai` does exactly that: modes_enable calls run_mode_setup (distro-modectl:673) even when it just printed "was already enabled", and run_mode_setup runs `distro-ai-setup --install --yes` (distro-modectl:613).
- **Consequence:** The forced values are silently replaced by auto-detected ones (A770 back to 'entry', a chosen image=none back to 'sdxl'), then --install acts on them: a different, smaller LLM is pulled and ~7GB of SDXL plus ComfyUI are installed on a box where the user had opted out. Nothing is backed up, so the user's explicit choice is unrecoverable. distro-modectl's own first-entry path deliberately guards against this ([ ! -f "$cfg_dir/refract-ai/tier" ], distro-modectl:315-316, with a comment saying "overwriting someone's explicit tier is not [recoverable]") — distro-ai-setup lacks the same guard.
- **Proposed fix:** In distro-ai-setup, skip step 1 when $CONFIG_HOME/tier already exists (print the recorded tier and say how to re-detect), and add an explicit --redetect flag for the override case; alternatively have distro-ai-detect-tier copy the previous tier/profile/image to *.bak before rewriting.

```
if [ "$YES" = true ]; then "$DETECT" --yes; else "$DETECT"; fi
# distro-ai-detect-tier: --yes only sets DO_ASK=0, DO_WRITE stays 1, so lines 574-593 rewrite
#   $CONFIG_HOME/{tier,profile,image,vram_mib,detected} unconditionally, with no .bak.
```

## 20. [MEDIUM] The Ollama Vulkan drop-in is never applied on any automated path, so the Intel Arc target runs CPU-only inference
- **Where:** `modes/ai/bin/distro-ai-detect-tier`:292
- **Category:** silent-noop
- **Trigger:** Any Intel Arc machine (the documented first flash target, iso/strains/laptop.list.chroot). Every path that runs detect-tier runs it as the unprivileged desktop user by construction: distro-ai-setup refuses root outright (distro-ai-setup:19-22) and distro-modectl invokes it through run_as_user (distro-modectl:317, with output sent to >/dev/null 2>&1), so the `id -u != 0` branch is always taken and /etc/systemd/system/ollama.service.d/10-refract-vulkan.conf is never written. No other file in the repo writes OLLAMA_VULKAN.
- **Consequence:** Ollama keeps the default of the shipped unit (Vulkan off, modes/ai/systemd/ollama.service) and runs the 7-8B model entirely on the CPU, while the same run prints "Intel Arc iGPU usable via Ollama's Vulkan backend (OLLAMA_VULKAN=1)" (line 512) and tiers the machine by shared RAM as though the GPU were in use. Under `distro-modectl switch ai` the remedial hint is discarded with the rest of stdout, so the user is never told. Doing the obvious thing instead — `sudo distro-ai-detect-tier` — writes the drop-in but sends CONFIG_HOME to /root/.config/refract-ai, so the user's own distro-ai-model finds no tier and falls back to 'entry'.
- **Proposed fix:** Have distro-ai-setup apply the drop-in via sudo (it already sudo's 01-install-ollama.sh), or have detect-tier record 'needs_vulkan=1' in $CONFIG_HOME/detected and let 01-install-ollama.sh (which runs as root) install the drop-in; when detect-tier itself is run as root, also refuse or resolve CONFIG_HOME from SUDO_USER so the tier does not land in /root.

```
enable_ollama_vulkan() {
    if [ "$(id -u)" != 0 ] || [ ! -d /run/systemd/system ] || ! command -v systemctl >/dev/null 2>&1; then
        echo "  (To use the Arc iGPU, enable Ollama's Vulkan backend as root:"
        echo "     sudo systemctl edit ollama   # add:  Environment=\"OLLAMA_VULKAN=1\")"
        return 0
```

## 21. [MEDIUM] HOOKS_DIR/TESTING_HOOK re-apply $(dirname $BASH_SOURCE) after the script already cd'd there, so the non-GNOME hook strip silently no-ops
- **Where:** `iso/build.sh`:172
- **Category:** path-resolution
- **Trigger:** Invoke as `sudo iso/build.sh lowspec` (or server/cloud) from the repo root — precisely the invocation the cd at :95 was added to make safe ("nothing enforced where this runs ... it did NOT fail loudly"). BASH_SOURCE[0] is "iso/build.sh", so dirname is "iso"; after `cd iso` the CWD is already .../iso, and HOOKS_DIR resolves to .../iso/iso/config/hooks, which does not exist. `rm -f` on a nonexistent path succeeds silently, so 0300-macos-look.chroot, 0400-polish.chroot and 0410-keyd.chroot are never removed, while their package lists (built from $PACKAGE_LISTS, which IS correctly relative) are. The `find ... || true` at :608 also swallows its own failure.
- **Consequence:** A lowspec/server/cloud ISO built that way runs the GNOME-only hooks anyway: 0300-macos-look.chroot only bails if git is missing (git is in base.list.chroot), so it clones and installs the WhiteSur GTK + icon themes and blur-my-shell system-wide into an LXQt or headless image, and 0410-keyd.chroot apt-installs gcc/make to build keyd. For lowspec that is fatal to the release shape — build.sh:441-443 records lowspec clearing GitHub's 2045 MiB single-asset limit by only ~1 MiB, so the WhiteSur icon tree pushes it over and it gets demoted to split .part files. Under REFRACT_TESTING=1 the same bug is loud instead: `cat > "$TESTING_HOOK"` at :532 fails with "No such file or directory" and set -e aborts the build.
- **Proposed fix:** Make these three consistent with INCLUDES/PACKAGE_LISTS, which are already plain post-cd relative paths: `HOOKS_DIR="config/hooks"` (:172), `TESTING_HOOK="config/hooks/0900-DANGER-testing-nologin.chroot"` (:529), and `find config/hooks -maxdepth 1 ...` (:608). Also drop the `|| true` on :608 (or at least the 2>/dev/null) so a missing hooks dir cannot be swallowed again.

```
build.sh:95   cd "$(dirname "${BASH_SOURCE[0]}")"
build.sh:96   INCLUDES="config/includes.chroot"          # correct: relative to the new CWD
build.sh:172  HOOKS_DIR="$(dirname "${BASH_SOURCE[0]}")/config/hooks"   # WRONG: dirname applied twice
build.sh:196      rm -f "${_stripped[@]}"
build.sh:529  TESTING_HOOK="$(dirname "${BASH_SOURCE[0]}")/config/hooks/0900-DANGER-testing-nologin.chroot"
build.sh:608  find "$(dirname "${BASH_SOURCE[0]}")/config/hooks" -maxdepth 1 -type f ... 2>/dev/null || true
```

## 22. [MEDIUM] WhiteSur-missing fallback repoints only 2 of 4 files naming WhiteSur-Dark; the first mode switch undoes it
- **Where:** `iso/config/hooks/0300-macos-look.chroot`:129
- **Category:** correctness
- **Trigger:** clone_pin fails for vinceliuice/WhiteSur-gtk-theme — the hook's own message names the likely cause: "fetch failed for $1@$2 (network?) — skipping it." (0300:43). /usr/share/themes/WhiteSur-Dark is then absent, the else-branch at 0300:121 fires and repoints the two build-time default files to Yaru-dark. But modes/modectl/distro-modectl:424-426 hard-codes the theme independently: `run_as_user gsettings set org.gnome.desktop.interface gtk-theme 'WhiteSur-Dark'` (plus `org.gnome.shell.extensions.user-theme name 'WhiteSur-Dark'`), and modes/normal/setup/03-apply-theme.sh:29 defaults THEME_NAME to WhiteSur-Dark. Neither is touched by the sed.
- **Consequence:** The image boots looking coherent (Yaru-dark), then the moment the user runs the one command the MOTD prints at every login — `distro-modectl switch <mode>` (written by 0200:58) — gsettings sets gtk-theme to a theme that does not exist and GTK silently falls back to light Adwaita, while WhiteSur icons (whose installer succeeds independently) stay. That is the exact 'config files insist it is macOS-styled while the desktop renders stock GNOME' failure the else-branch was added to eliminate, just deferred by one mode switch, and it is not recoverable by re-switching.
- **Proposed fix:** Have the fallback branch write the resolved name to a single source of truth the runtime reads — e.g. `printf 'REFRACT_GTK_THEME=%s\n' "$_fb" > /etc/refract/theme` — and change distro-modectl:424-426 and modes/normal/setup/03-apply-theme.sh:29 to source that with 'WhiteSur-Dark' as the default, instead of hard-coding the name in four places.

```
for _f in /usr/share/glib-2.0/schemas/99_refract.gschema.override \
          /etc/dconf/db/local.d/00-refract; do
    [ -f "$_f" ] && sed -i "s/'WhiteSur-Dark'/'$_fb'/g" "$_f" 2>/dev/null || true
done
```

## 23. [MEDIUM] Unscoped xorg.conf.d Device section forces Driver "modesetting" on whatever GPU Xorg picks, including a discrete NVIDIA card
- **Where:** `iso/config/hooks/0400-polish.chroot`:156
- **Category:** correctness
- **Trigger:** workstation or laptop strain, user runs the repo's own drivers/install-nvidia.sh (which installs nvidia-driver-NNN-open and its /usr/share/X11/xorg.conf.d/10-nvidia.conf OutputClass block), then boots under Xorg — which is the default this hook forces, and which persists whenever the wayland-scope unit is not reached (systemctl enable failed at 0400:137, or lspci/pciutils absent, so $gpus is empty). The Device section carries no BusID and no MatchDriver, so it is not scoped to Intel at all despite its Identifier; with no Screen/ServerLayout section present Xorg binds the first Device section to the primary GPU whatever that GPU is.
- **Consequence:** On an NVIDIA box the server binds the generic modesetting DDX to the NVIDIA card instead of the nvidia DDX that OutputClass asked for — the desktop comes up without the proprietary GL/Vulkan stack (software-rendered compositing) or fails to start X, on the strain explicitly sold for AI and gaming workloads. The name "Intel Graphics" makes the file read as scoped when nothing in it scopes anything, so this is invisible on inspection; verify-boot-fixes.yml:99-100 only greps the file for the string 'modesetting', which passes either way.
- **Proposed fix:** Use the canonical scoped form instead of a bare Device section: `Section "OutputClass" / Identifier "intel-modesetting" / MatchDriver "i915" / Driver "modesetting" / EndSection`. MatchDriver binds it to the i915 kernel driver only, so it cannot be applied to an NVIDIA or AMD GPU.

```
cat > /etc/X11/xorg.conf.d/20-intel-modesetting.conf <<'EOF'
Section "Device"
    Identifier "Intel Graphics"
    Driver "modesetting"
EndSection
EOF
```

## 24. [MEDIUM] keyd is cloned by mutable git tag and built as root without SHA verification, unlike every other third-party fetch in the tree
- **Where:** `iso/config/hooks/0410-keyd.chroot`:26
- **Category:** supply-chain
- **Trigger:** Every GNOME-strain build (workstation/laptop/handheld — build.sh:185 only strips 0410 for server/cloud/lowspec). KEYD_TAG="v2.5.0" is a git tag, which upstream can move with a force-push and which a repo compromise can repoint; the clone verifies nothing about what it received before compiling and `make install`-ing it as root into the shipped image.
- **Consequence:** A moved or hostile tag silently ships arbitrary root-installed code as a daemon that grabs every /dev/input device (keyd reads all keystrokes system-wide) into every desktop ISO, with the build log printing only the success line at 0410:52. It also makes the image non-reproducible: two builds of the same commit can ship different keyd binaries. The sibling hook 0300 does exactly the right thing 200 lines away (GTK_SHA/ICON_SHA/BMS_SHA plus `[ "$(git -C "$3" rev-parse HEAD)" = "$2" ] || { echo "sha mismatch — refusing."; return 1; }` at 0300:46), and modes/normal/README.md:16 records that SHA-pinning was added there specifically because a security review flagged download-and-execute of third-party code. 0410 was left out.
- **Proposed fix:** Replace KEYD_TAG with KEYD_SHA and reuse 0300's clone_pin pattern: git init + remote add + `fetch --depth 1 origin <sha>` + checkout FETCH_HEAD + `[ "$(git rev-parse HEAD)" = "$KEYD_SHA" ]` or refuse to build. Keep the existing failure-tolerant else-branch so a refusal still lets the ISO build with Ctrl-only shortcuts.

```
if git clone --depth 1 --branch "$KEYD_TAG" https://github.com/rvaiya/keyd.git "$WORK/keyd" >/dev/null 2>&1 \
   && make -C "$WORK/keyd" >/dev/null 2>&1 \
   && make -C "$WORK/keyd" install >/dev/null 2>&1; then
```

## 25. [MEDIUM] screenshot-tour has no -e and no assertion — the step's exit status is `ls || true`, so it is structurally incapable of failing
- **Where:** `.github/workflows/screenshot-tour.yml`:84
- **Category:** no-op-job
- **Trigger:** QEMU exits during startup (corrupt/truncated ISO artifact, or `-accel kvm` refused after line 81's `[ -e /dev/kvm ] && ... ACCEL=kvm`), or the guest simply hasn't reached GNOME by the fixed `sleep 210`. Without `-e`, the failed qemu launch does not stop the step; every subsequent `mon` socat call fails into `>/dev/null 2>&1`, every `vd` returns 0 via `|| true`, and `shot()` never verifies the ppm appeared — unlike the hardened `shot()` in boot-smoke.yml:121, which was fixed after run 28569864278 for exactly this class of silent loss.
- **Consequence:** The job that produces the published "what Refract OS looks like" screenshots exits 0 having captured nothing. `mkdir -p "$PWD/shots"` guarantees the directory exists, and upload-artifact uses `if-no-files-found: warn` (line 128), so the empty `refract-tour` artifact is a warning, not a failure. A green check is recorded as evidence the OS was toured; anyone downloading the artifact gets an empty folder, or a set of identical GRUB/blank frames with nothing flagging them.
- **Proposed fix:** Use `set -euo pipefail`, drop the `|| true` from `vd()`, make `shot()` assert the ppm appeared (copy boot-smoke.yml:121), verify `kill -0 "$(cat qemu.pid)"` after the boot wait, and end the step with a check that shots/ contains the expected count of non-trivial PNGs. Set `if-no-files-found: error` on the upload.

```
set -uo pipefail
...
mon() { printf '%s\n' "$1" | socat - "unix-connect:$PWD/mon.sock" >/dev/null 2>&1; }
shot() { mon "screendump $PWD/shots/$1.ppm"; sleep 1; }
vd() { vncdo -s localhost:0 "$@" 2>/dev/null || true; }
...
ls -lh shots/ || true
```

## 26. [MEDIUM] mode-test's "VISUAL PROOF" of per-mode wallpaper switching only checks that one PNG is larger than 2000 bytes
- **Where:** `.github/workflows/mode-test.yml`:318
- **Category:** evidence-does-not-support-claim
- **Trigger:** The live desktop is not up within the hard-coded `sleep 210` — guaranteed whenever /dev/kvm is absent and line 236 sets ACCEL=tcg ("falling back to TCG (slow)"), and also whenever gdm is broken. The `vd key super` / `vd type "Terminal"` keystrokes then land on a GRUB menu or a text console, `switch_and_shot gaming/ai/server` never runs a single `distro-modectl switch`, and all six screendumps are the same non-blank screen — comfortably over 2000 bytes as a PNG.
- **Consequence:** The step exits 0 and prints the workflow's headline claim — that the wallpaper visibly changed between 03-gaming, 04-ai and 05-server — when no mode switch occurred at all. Nothing anywhere compares the shots to each other or to 00-base-desktop; the only pixel-level routine, `distinct()` at lines 308-313, is defined and never called (dead code, and the comment at 315-316 admits PNGs were never decoded). Because the job is `continue-on-error: true` (line 163) with no $GITHUB_STEP_SUMMARY marker, even the exit-1 path is invisible, so the log's PASS text is the job's only output.
- **Proposed fix:** imagemagick is already installed (line 226). Decode the PNGs and assert 03-gaming, 04-ai and 05-server are pairwise different and each differs from 00-base-desktop (e.g. `compare -metric AE` above a threshold), and assert 02-terminal-open differs from 01-overview to prove the terminal actually opened. Delete the unused `distinct()` or use it. Mirror install-smoke.yml:514-518 and write a ⚠️ marker to $GITHUB_STEP_SUMMARY on failure so continue-on-error cannot swallow it.

```
finals = sorted(glob.glob("shots/06-final.png") + glob.glob("shots/05-server.png"))
import os
ok = any(os.path.getsize(p) > 2000 for p in finals) if finals else False
...
echo "VISUAL PROOF: the uploaded screenshots (03-gaming / 04-ai / 05-server)"
echo "show the SAME running GNOME desktop with the per-mode WALLPAPER changed"
```

## 27. [MEDIUM] server-ssh-survival prints PASS without ever verifying the display-manager teardown happened, and its one switch-status assertion is unreachable
- **Where:** `.github/workflows/server-ssh-survival.yml`:92
- **Category:** evidence-does-not-support-claim
- **Trigger:** The default outcome on ubuntu-latest: `sudo systemctl start gdm3 || true` (line 58, in a step named "Best-effort start gdm (headless runners may only reach enabled/idle)") leaves gdm inactive, so `gdm=active` never appears in ssh_out.txt and the else branch is taken on every run. `distro-modectl switch server --yes` then runs `systemctl disable --now gdm` against an already-inactive unit — no session is torn down, so the property under test is never exercised.
- **Consequence:** The job unconditionally reports "PASS: switch server is safe over SSH — no lockout", closing the TODO safety item, on a run where nothing was ever disabled. The else branch also states "'disable --now gdm' ran" as fact while asserting nothing about it, so a regression that makes `switch server` skip the DM teardown entirely (the CONFIRM_DISPLAY_MANAGER_STOP loop at distro-modectl:478-488 silently no-ops if `gdm` is dropped from DISABLE_SERVICES) still passes. Separately, the assertion at line 83-84, `grep -q "switch_rc=0" ... || fail "'switch server' returned non-zero inside the session"`, can never fire: the remote shell runs `set -e` (line 68), so `echo "switch_rc=$?"` on line 72 is reached only when the switch already succeeded, and a failing switch kills the remote shell so `ssh ... | tee` fails under pipefail before this step ever runs.
- **Proposed fix:** Make the gdm precondition an assertion, not narration: after line 58, fail the job if `systemctl is-active gdm` is not `active`, or start a dummy-seat gdm so the teardown is real. Capture the switch status properly with `rc=0; sudo distro-modectl switch server --yes || rc=$?; echo "switch_rc=$rc"` so line 83's check becomes reachable, and gate the final `PASS` echo on the VERIFIED branch rather than printing it unconditionally.

```
if grep -q "gdm=active" ssh_out.txt && grep -q "gdm_active=inactive" ssh_out.txt; then
  echo "VERIFIED: ..."
else
  echo "NOTE: could not confirm gdm reached inactive on this headless runner, but 'disable --now gdm' ran and neither the SSH session nor sshd was dropped."
fi
echo "PASS: switch server is safe over SSH — no lockout."
```

## 28. [MEDIUM] verify-drivers.sh FAILs the microcode check on a healthy AMD box when run as the README documents
- **Where:** `drivers/verify-drivers.sh`:42
- **Category:** correctness
- **Trigger:** AMD CPU, microcode correctly loaded, script run exactly as drivers/README.md:10 instructs — `./verify-drivers.sh`, no sudo. Ubuntu ships kernel.dmesg_restrict=1, so unprivileged `dmesg` returns EPERM and the `2>/dev/null` hides it. The journalctl fallback then needs read access to the system journal, which requires the `adm` or `systemd-journal` group — and iso/calamares/modules/users.conf defaultGroups is `sudo, audio, video, network, storage, plugdev, lpadmin`, with no `adm`. So a user created by Refract's own installer can read neither source.
- **Consequence:** The documented post-install verification prints a red [FAIL] and exits non-zero on a machine where the microcode is loaded and everything is correct, sending the user to debug a non-problem. It is also internally inconsistent: install-amd-microcode.sh:30-33 hits the identical unreadable-log case and correctly treats it as "could not confirm" (yellow), not a failure.
- **Proposed fix:** Distinguish "log says microcode did not load" from "cannot read the log". Probe readability first (e.g. `dmesg >/dev/null 2>&1 || [ -r /var/log/journal ]`) and emit a yellow [SKIP]/warn that does not increment FAIL when neither source is readable, mirroring install-amd-microcode.sh:31; or re-exec the whole script under sudo. Separately, adding `adm` to defaultGroups in iso/calamares/modules/users.conf matches what Ubuntu's own installer does and fixes journal access generally.

```
drivers/verify-drivers.sh:42-48
    if dmesg 2>/dev/null | grep -qiE 'microcode: (Updated early|Current revision|Reload completed)' || (command -v journalctl >/dev/null 2>&1 && journalctl -k -b 2>/dev/null | grep -qi microcode); then
        echo -e "\033[32m[PASS]\033[0m microcode loaded this boot"
    else
        echo -e "\033[31m[FAIL]\033[0m microcode not confirmed loaded this boot (check after a reboot)"
        FAIL=$((FAIL + 1))
    fi
…line 59:  [ "$FAIL" -eq 0 ]
```

## 29. [MEDIUM] Cloud image's version string and MOTD are hardcoded, so a version bump drifts inside the file that tells you to bump it
- **Where:** `iso/cloud-image/build-cloud-image.sh`:136
- **Category:** maintainability
- **Trigger:** A maintainer follows the instruction in the comment at line 125 and edits line 129 — say to VERSION_NUM="1.1"; VERSION_CODENAME="prism" — to stay in step with iso/build.sh:389. Line 136 still emits `VERSION="1.1 (Forge)"` while VERSION_CODENAME=prism two lines below, and the `<<'MOTD'` heredoc is single-quoted so no expansion happens at all: the login banner still says 1.0.
- **Consequence:** The shipped cloud image self-reports two different versions: /etc/os-release VERSION says the old codename while VERSION_ID/VERSION_CODENAME/PRETTY_NAME/lsb-release say the new one, and every SSH login banner announces the previous release. Anything keying on os-release (support triage, telemetry, docs) gets an inconsistent answer from the same file. Related gap in the same block: line 143 emits VARIANT="Cloud" but no VARIANT_ID, while iso/build.sh:408 emits `VARIANT_ID=${STRAIN}` — so tooling that keys on the machine-readable VARIANT_ID sees the six ISO strains and nothing for cloud.
- **Proposed fix:** Line 136 -> `VERSION="${VERSION_NUM} (${VERSION_CODENAME^})"` (identical to iso/build.sh:400). Change the MOTD heredoc from `<<'MOTD'` to an expanding one (or write the literal via printf with "$VERSION_NUM"). Add `VARIANT_ID=cloud` after line 143. Better still, since the comment already admits the duplication: extract the _osrelease body into a shared iso/lib-identity.sh sourced by both pipelines, which removes the drift class rather than re-documenting it.

```
line 125-129:
    # Keep VERSION_NUM/CODENAME in step with iso/build.sh — they are duplicated
    …
    VERSION_NUM="1.0"; VERSION_CODENAME="forge"
line 136:  VERSION="${VERSION_NUM} (Forge)"          <- codename hardcoded
line 186-190:
    cat > "$MOUNT_DIR/etc/update-motd.d/00-refract" <<'MOTD'
    #!/bin/sh
    printf '\n  Refract OS 1.0 (Cloud)  —  headless instance\n'   <- version hardcoded, quoted heredoc

iso/build.sh:400 does it correctly:  VERSION="${VERSION_NUM} (${VERSION_CODENAME^})"
```

## 30. [MEDIUM] branding/README.md still documents the logo and the mode-chip legend that were deliberately removed as defects
- **Where:** `branding/README.md`:20
- **Category:** generated-asset-spec-drift
- **Trigger:** Any maintainer regenerating branding from this README (the documented entry point, "## Building / ./build.sh") after the logo removal (f4dfa3e) and the mode-legend removal (b95bf25).
- **Consequence:** The README is the written spec for these generated assets, and it prescribes exactly the two states that were fixed as bugs. Acting on line 20-21 means restoring `cp "$OUT/logo.png" "$CALAMARES_DIR/logo.png"`, silently re-introducing the mark into the shipped installer of a deliberately logo-free OS. Acting on line 22-23 means re-adding the five mode chips to welcome.svg, which re-breaks the REFRACT_OMIT_MODES guarantee: a `REFRACT_OMIT_MODES=ai` image would once again open its installer on a banner advertising an AI chip the build provably does not contain. The README's own blockquote (lines 13-18) warns about precisely this drift class.
- **Proposed fix:** Rewrite lines 20-23 to match HEAD: `src/logo.svg` produces docs/logo.png + docs/favicon.png for the WEBSITE ONLY and is deliberately not shipped to the OS (branding/build.sh:133-137 substitutes blank.png); `src/welcome.svg` is a text-only banner with no mark, no legend and no mode count, and must stay mode-agnostic because it is a baked PNG against a build-time-variable mode set. Also correct lines 10-11 to drop "installer" from the list of surfaces carrying the five hexes, and note in the `## Wallpapers` section that make-wallpapers.py — not build.sh — is what writes iso/calamares/branding/refractos/{gaming,ai,server,creative}.png.

```
20: - `src/logo.svg` — circular badge, used as both Calamares' `productLogo`
21:   and `productIcon`
22: - `src/welcome.svg` — wide banner with the mark, wordmark and the 5 labelled
23:   mode colour chips, used as Calamares' `productWelcome`

Both claims are false in HEAD:
  branding/build.sh:137  cp "$OUT/blank.png" "$CALAMARES_DIR/logo.png"   # NOT out/logo.png
  iso/calamares/branding/refractos/logo.png is 1x1 RGBA (70 B), hash-identical to branding/out/blank.png
  branding/src/welcome.svg header: "LOGO-FREE by request... NO MODE LEGEND, AND NO MODE COUNT — deliberately, because this image is a BAKED PNG and the mode set is a BUILD-TIME VARIABLE."

The same README's line 10-11 also asser
```

## 31. [MEDIUM] README and utm-guide promise every release is a plain `.iso` flashable with `dd`; the pipeline can publish `.iso.xz`, which `dd` silently turns into an unbootable stick
- **Where:** `README.md`:9
- **Category:** contradictory-claim
- **Trigger:** Any strain whose finished ISO exceeds the 2045 MiB threshold in .github/workflows/build-iso.yml:292 (`limit=$((2045*1024*1024))`). That build takes the second rung and uploads `refract-os-<strain>.iso.xz` as the only image asset (build-iso.yml:305-310). A user who read README.md or docs/utm-guide.md:15-18 ("it is a single file … every strain now lands under it on its own, so the parts are gone") downloads it and runs `dd`.
- **Consequence:** `dd` does not decompress. `sudo dd if=refract-os-workstation.iso.xz of=/dev/sdX …` writes the xz container to the stick, reports success, and produces a USB with no bootable filesystem — the failure mode is a silent non-boot with no error to search for. docs/install.html:155 documents the correct rule ("Only Ventoy and the `dd` command need it unpacked first") and docs/install.html:156-157 gives the `xz -d` step, so three of the four download-facing docs contradict the one that is right. docs/index.html:510 repeats the same wrong absolute ("each a **single `.iso`**").
- **Proposed fix:** Make README.md:9-10, docs/index.html:510 and docs/utm-guide.md:15-18 state the actual contract instead of the best-case rung: "one file per strain — a `.iso`, or a `.iso.xz` if that strain crosses GitHub's 2 GiB asset cap. Etcher/Rufus/Pi Imager/GNOME Disks take either as-is; for `dd` or Ventoy, run `xz -d` first." Or simply point all three at docs/install.html step 1 rather than restating it three ways.

```
All six strains are published as a **single `.iso`** — no rejoining, flash it straight
with balenaEtcher, Rufus or `dd`:
```

## 32. [MEDIUM] Nonexistent `ollama ps --estimate-only` flag and a mangled sentence survive the llama.cpp→Ollama migration
- **Where:** `docs/first-hardware-runbook.md`:154
- **Category:** stale-migration-leftover
- **Trigger:** Track B / step B2 on the RTX 5090 box — the operator is told to tune the 70B offload ratio and runs the command as written: `ollama ps --estimate-only`.
- **Consequence:** `ollama ps` accepts no flags; the command fails with an unknown-flag error, and the operator has no way to "preview the fit" as instructed. `--estimate-only` appears nowhere else in the repo (grep confirms this line is its only occurrence), so it is a leftover from the pre-Ollama llama.cpp/Crucible12 tuning workflow, not a real Ollama capability. The stray unmatched backtick after `--estimate-only` also breaks the Markdown code span, so the rendered page shows a literal backtick mid-sentence — the whole clause is visibly a botched edit, which undermines trust in the rest of this runbook on the one day it matters (first real GPU session).
- **Proposed fix:** Delete the dead clause and keep the part that is true for Ollama: "…tune the offload ratio: Ollama auto-offloads to CPU when a model exceeds VRAM; check the actual GPU/CPU split with `ollama ps` and expect ~6–12 tok/s." This also brings it in line with docs/blackwell-readiness.md:84-85, which already words it correctly.

```
ratio: Ollama auto-offloads to CPU when a model exceeds VRAM; check the split with `ollama ps`
--estimate-only` first to preview the fit, expect ~6–12 tok/s. Then the rest:
```

## 33. [MEDIUM] DESIGN.md §5b says the cloud strain is not an ISO strain, contradicting build.sh, the CI matrix and index.html — and its own sentence
- **Where:** `DESIGN.md`:211
- **Category:** contradictory-claim
- **Trigger:** A contributor reading DESIGN.md §5b to decide how to build or test the cloud strain, or to reconcile it against the landing page.
- **Consequence:** The claim is false in both directions and self-refuting. iso/build.sh:19 lists `cloud` in `VALID_STRAINS`, .github/workflows/build-iso.yml:27 offers `cloud` in the build matrix, and build-iso.yml:159 explicitly branches `server|cloud` as headless ISO builds that publish to a `latest-cloud` release — so `./build.sh cloud` produces an ISO and CI does build it. docs/index.html:563 states the opposite of DESIGN.md ("cloud-init, no desktop. Ships as an ISO; the qcow2 delivery format is still unfinished"). And the sentence contradicts itself: if cloud's format is qcow2 "rather than an installer ISO", there are five ISO strains, not "the six ISO strains" it then appeals to. A contributor is left believing a supported, CI-covered build path does not exist.
- **Proposed fix:** Rewrite the bullet to separate the two delivery paths: cloud builds as a headless ISO like `server` (in `VALID_STRAINS` and the build-iso matrix), *and* has a second, qcow2 path in `iso/cloud-image/build-cloud-image.sh` that is written and control-flow tested but has no CI job and has never been built end to end. Drop "the six ISO strains" or change it to "the ISO path".

```
- `cloud` — `cloud-init`, no DE. Its delivery format is a qcow2 cloud image
  rather than an installer ISO: `iso/cloud-image/build-cloud-image.sh`
  (debootstrap + loop device + grub-install + `qemu-img convert`), which
  applies a headless Refract identity layer. Written and control-flow
  tested, but **no CI job runs it**, so unlike the six ISO strains it has
  never been built end to end
```

## 34. [MEDIUM] Netdata kickstart is downloaded to a predictable /tmp path and then executed — TOCTOU on a multi-user server
- **Where:** `modes/server/setup/03-install-netdata.sh`:13
- **Category:** security
- **Trigger:** Server mode on a box with more than one local account — i.e. exactly the multi-user case Server mode exists for. Any unprivileged local user pre-creates /tmp/netdata-kickstart.sh (a symlink, or a file they own with mode 0666) before the admin runs step 03. /tmp is world-writable and the filename is fixed and public.
- **Consequence:** With a pre-created attacker-owned file, `curl -o` truncates and writes through it but ownership stays with the attacker, so the attacker can rewrite the contents in the window between the curl and the `sh` on the next line — arbitrary code then runs as the admin, and Netdata's kickstart escalates itself with sudo, so the attacker's code inherits the admin's sudo session: local root. With a symlink, the same line clobbers whatever file it points at. There is also no integrity check on the fetched script, so nothing would detect the substitution. (The curl-to-shell aspect itself is documented as intentional in the header comment and in modes/server/README.md:25 — the fixed /tmp path is not.)
- **Proposed fix:** Download into a private temp dir instead of a fixed path: `TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; curl -fsSL https://get.netdata.cloud/kickstart.sh -o "$TMP/kickstart.sh"; sh "$TMP/kickstart.sh" --stable-channel --disable-telemetry --non-interactive`. mktemp -d gives a 0700 dir no other user can write into, and the trap also cleans up on the failure path (today's `rm -f` at line 15 is skipped whenever the install fails under set -e).

```
curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh
sh /tmp/netdata-kickstart.sh --stable-channel --disable-telemetry --non-interactive
rm -f /tmp/netdata-kickstart.sh
```

## 35. [MEDIUM] Scratch-disk detection treats snap squashfs loop mounts as SSDs, so an HDD-only machine gets a read-only /snap path instead of the documented /var/tmp fallback
- **Where:** `modes/creative/bin/distro-creative-scratch`:58
- **Category:** correctness
- **Trigger:** A Refract box whose only real storage is rotational (an older workstation/lowspec-class machine — the strain lineup explicitly targets these) with snapd installed, which ubuntu-desktop-minimal pulls in on every GNOME strain. Every snap is a squashfs mounted from /dev/loopN, which passes the `/dev/*` guard, and loop devices report ROTA=0, so they pass the rotational guard too. avail is 0, but best_avail starts at -1, so the first /snap/... mount wins; the real /dev/sdX root is skipped as rotational. Then `sudo ./bin/distro-creative-scratch setup` (modes/creative/README.md:13).
- **Consequence:** best_path becomes something like /snap/gnome-42-2204/141, so line 103 runs `mkdir -p /snap/gnome-42-2204/141/refract-creative-scratch` on a read-only squashfs; it fails with EROFS and set -e aborts, leaving no scratch dir, no REFRACT_SCRATCH_DIR and no /etc/profile.d file. The honest "falling back to /var/tmp" path documented in README.md:43-44 is unreachable on any machine with snaps, because best_path is never empty. `detect` alone silently prints a nonsense snap path.
- **Proposed fix:** Exclude non-disk backing devices before the ROTA test — skip mounts whose target starts with /snap/ (or, more robustly, skip sources where `lsblk -ndo TYPE "$source"` is `loop`, and/or require avail > 0). Then the HDD-only case correctly falls through to the /var/tmp branch. tests/test_creative_scratch.sh only stubs sda/nvme rows, so no existing test exercises a loop device.

```
case "$source" in
    /dev/*) ;;
    *) continue ;;  # skip tmpfs/overlay/etc. df -l should already exclude these, this is a second guard
esac
...
rota="$(lsblk -ndo ROTA "$source" 2>/dev/null | head -n1 | tr -d '[:space:]')"
[ "$rota" = "0" ] || continue   # rotational or unknown -- skip, only want SSD/NVMe
...
if [ -z "$best_path" ]; then
    echo "...no non-rotational local mount found -- falling back to /var/tmp..." >&2
    best_path="/var/tmp"
```

## 36. [MEDIUM] Per-user half of the switch is applied before the privilege check, so a failed sudo leaves the desktop in the new mode and the system in the old one
- **Where:** `modes/modectl/distro-modectl`:495
- **Category:** state-inconsistency
- **Trigger:** A standard (non-sudoer) account on a multi-user install, or an admin who cancels / mistypes the sudo password, runs `distro-modectl switch gaming` while currently in AI mode.
- **Consequence:** By the time sudo fails, apply_theme has already swapped the wallpaper, GTK accent (~/.config/gtk-{3,4}.0/gtk.css), color-scheme and blur, apply_pinned_apps has already rewritten the dock, and apply_ai_model has already run `distro-ai-model unload`, killing the loaded Ollama model out from under whatever was using it. Nothing privileged is applied, STATE_FILE is not written, and `distro-modectl status` keeps reporting the OLD mode — so the desktop looks like Gaming, the CPU governor / power profile / services are still AI's, and status disagrees with both. There is no rollback path; the user's AI session is destroyed for a switch that never happened.
- **Proposed fix:** Probe for privilege before mutating anything: at the top of do_switch, when `id -u` != 0, run `sudo -n true` (or `sudo -v`) and abort with a clear message if it fails, so the per-user block at line 495 is only reached once the root pass is guaranteed to be reachable. Alternatively invert the order — re-exec to root first, and have the root pass drive the per-user steps via run_as_user — so the whole switch is applied from a single already-privileged pass.

```
distro-modectl:495-509
    if [ -z "${_REFRACT_REEXEC:-}" ]; then
        apply_pinned_apps PINNED_APPS
        apply_theme
        apply_ai_model
    fi

    require_root_for switch "$mode"

    apply_cpu_governor "$CPU_GOVERNOR"
    ...
    echo "$mode" > "$STATE_FILE"
and distro-modectl:109-114
        if [ "$ASSUME_YES" = "true" ]; then
            sudo --preserve-env=_REFRACT_REEXEC "$0" "$@" --yes
        ...
        exit $?
There is no privilege probe before the per-user block and no rollback after a failed re-exec.
```

## 37. [MEDIUM] mode-mechanism.sh asserts the raw profile governor, contradicting distro-modectl's deliberate intel_pstate mapping
- **Where:** `tests/mode-mechanism.sh`:208
- **Category:** false proof / asserts behaviour the code deliberately lacks
- **Trigger:** Running tests/mode-mechanism.sh on any host whose cpufreq driver is intel_pstate or amd-pstate-epp — i.e. the ThinkPad X1 Carbon named as the first hardware target, or a self-hosted runner. .github/workflows/mode-test.yml:120 bind-mounts the host /sys into the chroot, so the harness sees the real scaling_available_governors. It passes today only because GitHub's Azure VMs expose no cpufreq node at all (avail="", mapping skipped).
- **Consequence:** On the primary hardware target the mechanism proof reports two FAILs — 'cpupower set governor schedutil' for ai and for normal — for behaviour that is correct and intentional. The obvious reading of a red mechanism job is to remove the intel_pstate mapping, which would reinstate the scary cpupower WARNING on the two default modes that the mapping was added to fix.
- **Proposed fix:** Pin the governor input the way test_modectl.sh already does: export GOV_AVAIL_FILE to a fixture from run_switch (tests/mode-mechanism.sh:186) listing 'conservative ondemand userspace powersave performance schedutil', so assert_common's expectation is deterministic. Optionally add a second pass with an intel_pstate fixture ('performance powersave') asserting ai/normal map to powersave, which is the behaviour that actually ships on the X1.

```
tests/mode-mechanism.sh:208 (inside assert_common)
    log_has "$mode" cpupower "frequency-set -g $gov" "cpupower set governor '$gov'"
called with the profile's *requested* governor:
  :303  assert_common ai     schedutil balanced "#4a9df0" auto
  :335  assert_common normal schedutil balanced "#ffa23d" auto

run_switch (tests/mode-mechanism.sh:186-191) sets PATH/HOME/XDG_CONFIG_HOME/DBUS/DISPLAY but never GOV_AVAIL_FILE, so distro-modectl reads the real sysfs node (modes/modectl/distro-modectl:58) and applies its mapping (:192-203):
    if [ -n "$avail" ] && ! printf ' %s ' "$avail" | grep -q " $gov "; then
        case "$gov" in
            performance) ... ;;
            *)           ... m
```

## 38. [MEDIUM] branding.desc's entire style: block uses Calamares 3.2 key names; all four keys are silently discarded
- **Where:** `iso/calamares/branding/refractos/branding.desc`:46
- **Category:** config-schema
- **Trigger:** Every GUI strain, every install, unconditionally — the moment the Calamares window opens.
- **Consequence:** Calamares 3.3.5 recognises exactly four style keys, capitalised: SidebarBackground, SidebarText, SidebarTextCurrent, SidebarBackgroundCurrent (upstream src/branding/default/branding.desc; src/libcalamaresui/Branding.cpp runs validateStyleEntries() and logs "Unknown branding *style* entry" for anything else). All four Refract keys fail: the leading letter is lowercase, and `sidebarTextSelect` / `sidebarBackgroundSelected` are not 3.3 names at all (3.2 had `sidebarTextSelect` and `sidebarTextHighlight`; `sidebarBackgroundSelected` never existed in any version). Every key is dropped and the sidebar falls back to the stock Calamares palette — #292F34 background with the #D35400 orange current-step highlight. The advertised Refract dark theme and prism-violet accent never render, so the installer looks like generic Calamares while the rest of the OS is themed.
- **Proposed fix:** Rename to the 3.3 keys: `SidebarBackground: "#1c1c22"`, `SidebarText: "#d8d8e0"`, `SidebarTextCurrent: "#1c1c22"` (this is the text colour drawn ON the current-step background, so it must contrast with it — the old value #c9a5ff was written as if it were the accent), `SidebarBackgroundCurrent: "#c9a5ff"`.

```
branding.desc:45-51
# Dark theme with the Refract prism-violet accent for the active step + a
# subtle selected-row background, so the left-hand step list reads clearly.
style:
  sidebarBackground:         "#1c1c22"
  sidebarText:               "#d8d8e0"
  sidebarTextSelect:         "#c9a5ff"
  sidebarBackgroundSelected: "#2c2c38"
```

## 39. [MEDIUM] No umount.conf, so umount is not an emergency module — a failed install leaves the target mounted and cannot be retried
- **Where:** `iso/calamares/settings.conf`:48
- **Category:** correctness
- **Trigger:** Any exec module failing mid-install — which, per this repo's own README ("Entirely unverified... this installer has never completed a verified install"), is the current normal outcome. Reproducible on any strain.
- **Consequence:** Upstream ships src/modules/umount/umount.conf whose only content is the `emergency` key: "Setting emergency to true will make it so this module is still run when a prior module fails". Calamares' Module::loadConfigurationFile warns ("No config file for ... found anywhere at") and hands the module an EMPTY config map, so m_emergency stays false. When a job fails, Calamares stops the sequence without unmounting: the target root, the ESP and the bind mounts stay live under /tmp/calamares-root-*. Relaunching the installer in the same live session then fails at the partition step because the disk is busy — the user has to reboot the live USB between every attempt, which is exactly the debugging loop this installer is currently stuck in. Lubuntu ships common/modules/umount.conf with `emergency: true` for this reason.
- **Proposed fix:** Add iso/calamares/modules/umount.conf containing `---` and `emergency: true`.

```
settings.conf:48
  - umount

No /Users/skyler/refract-os-work/iso/calamares/modules/umount.conf exists (the modules/ dir holds only bootloader, displaymanager, mount, packagechooser_modes, partition, shellprocess_modes, unpackfs, users, welcome).
```

## 40. [MEDIUM] No machineid.conf, so the machineid job is a complete no-op and the installed system inherits the build chroot's machine-id
- **Where:** `iso/calamares/settings.conf`:32
- **Category:** correctness
- **Trigger:** Every install from a given ISO, on every strain. Becomes visible when two machines installed from the same ISO are on one LAN.
- **Consequence:** Calamares 3.3.5's MachineIdJob::setConfigurationMap reads every switch with a false default — `Calamares::getBool( map, "systemd", false )`, same for "dbus" and "entropy-copy", and dbus-symlink only follows dbus. With no config file the module runs and does nothing at all, so /etc/machine-id (and the /var/lib/dbus/machine-id symlink) is whatever the systemd/dbus postinst wrote during `lb chroot` and unpackfs copied out of the squashfs — identical on every machine installed from that ISO. NetworkManager and systemd-networkd derive the DHCPv4 client identifier and the DHCPv6 DUID from /etc/machine-id, so two Refract boxes on the same network collide on a single lease; journal and D-Bus machine IDs collide too. Lubuntu ships common/modules/machineid.conf with systemd/dbus/dbus-symlink all true precisely to prevent this. (If live-build happens to truncate /etc/machine-id before squashing, this is harmless — but nothing in this repo makes that true, and the fix costs one file.)
- **Proposed fix:** Add iso/calamares/modules/machineid.conf with `systemd: true`, `dbus: true`, `dbus-symlink: true` — the same content Lubuntu ships for noble.

```
settings.conf:31-33
  - unpackfs
  - machineid
  - fstab

No /Users/skyler/refract-os-work/iso/calamares/modules/machineid.conf exists, and `grep -rn "machine-id\|machineid" iso/ modes/` returns no hit outside iso/calamares/settings.conf — nothing in the build clears it either.
```

## 41. [LOW] Conditionally-staged files are never unconditionally purged, so the polish dconf and the handheld script leak into other strains on repeat builds in one tree
- **Where:** `iso/build.sh`:517
- **Category:** strain-leak
- **Trigger:** config/includes.chroot/{etc,opt,usr} is gitignored (iso/.gitignore) and persists between runs — build.sh:280-284 already relies on that fact for the usr/local/bin wipe. The --delete at :286 only prunes $INCLUDES/opt/distro/modes and /drivers, not /strains. So docs/first-hardware-runbook.md:110's own line, `sudo ./build.sh laptop && sudo ./build.sh lowspec && sudo ./build.sh server`, stages 10-refract-polish during the laptop run and never removes it for lowspec or server; likewise `./build.sh handheld && ./build.sh workstation` leaves /opt/distro/strains/handheld/ in the workstation image. CI cannot catch either (fresh checkout every run, so the includes tree starts empty).
- **Consequence:** The lowspec (LXQt) and server/cloud ISOs from a chained local build ship /etc/dconf/db/local.d/10-refract-polish — a fragment that is 100% org/gnome/* paths (touchpad, mutter, wm, sound) and is exactly the layer :516 exists to withhold; verify-boot-fixes.yml:175 states "Only build.sh's GNOME strains get this layer". Non-handheld images ship /opt/distro/strains/handheld/setup-handheld-ui.sh, which flips on the on-screen keyboard and 1.25x text scaling if a user finds and runs it on a workstation. Both are dead/wrong-strain payload rather than a crash, but they break the per-strain guarantee this file enforces everywhere else.
- **Proposed fix:** Apply the same "always remove, then conditionally keep" pattern used at :158-166 and :284: add `rm -f "$INCLUDES/etc/dconf/db/local.d/10-refract-polish"` immediately before the `if` at :516, and `rm -rf "$INCLUDES/opt/distro/strains"` immediately before the handheld block at :372.

```
build.sh:516-518  if [[ ! " ${NON_GNOME_STRAINS[*]} " == *" $STRAIN "* ]]; then
                      cp "$REPO_ROOT/iso/branding/dconf/local.d/10-refract-polish" "$INCLUDES/etc/dconf/db/local.d/10-refract-polish"
                  fi
build.sh:372-377  if [ "$STRAIN" = handheld ] && [ -f ... ]; then
                      mkdir -p "$INCLUDES/opt/distro/strains/handheld"
                      cp ... "$INCLUDES/opt/distro/strains/handheld/setup-handheld-ui.sh"
build.sh:286      rsync -a --delete "$REPO_ROOT/modes" "$REPO_ROOT/drivers" "$INCLUDES/opt/distro/"
grep -n '10-refract-polish|opt/distro/strains' iso/build.sh -> only the two cp/mkdir sites above; no matching rm anywhere.
```

## 42. [LOW] iso/strains/README.md contradicts itself about the cloud strain in a single paragraph
- **Where:** `iso/strains/README.md`:42
- **Category:** docs
- **Trigger:** Reading iso/strains/README.md — the file the strain table points at for per-strain status. The two sentences are adjacent and directly opposed. DESIGN.md:211-216 and iso/cloud-image/README.md were both corrected for exactly this staleness in b6ce565/ea1f1f4; this file was missed by that sweep, and the new sentence was appended after the old claim instead of replacing it.
- **Consequence:** A contributor deciding whether to implement cloud delivery is told in one sentence that it is unbuilt and in the next that it exists, with no way to tell which is current — the same failure mode already fixed twice this session in DESIGN.md and iso/README.md. The table row is also now understated: since ea1f1f4 the cloud image is no longer "`cloud-init` only", it ships /opt/distro (modes + drivers), distro-modectl on PATH, an enabled-modes registry listing `server`, and a full os-release/hostname/GRUB_DISTRIBUTOR identity layer.
- **Proposed fix:** Delete the stale clause ("`cloud` is still scaffolding — its actual differentiation … is unbuilt.") and keep only the accurate statement, extended with the fact that actually matters and is stated in iso/cloud-image/README.md:57-58 — the pipeline exists, applies a headless Refract identity, and no CI job builds it. Update the line 16 Notes cell from "`cloud-init` only" to note the headless identity layer + mode tree.

```
lines 41-46:
    `cloud` is still
    scaffolding — its actual differentiation (a cloud-image delivery format
    instead of an ISO) is unbuilt. Don't mistake "this strain exists in the
    list" for "this strain is done." `cloud` now has a real (if unrun) delivery
    pipeline too — see `iso/cloud-image/README.md`.

and line 16 of the same file already documents the pipeline as existing:
    | `cloud` | none | `cloud-init` only. Real qcow2 delivery format: `iso/cloud-image/build-cloud-image.sh` …
```

## 43. [LOW] Installer preview PNGs are 2.5x the size the code's own budget comment claims, because the dithered render is what gets downscaled
- **Where:** `branding/make-wallpapers.py`:210
- **Category:** size-accounting
- **Trigger:** Reading either comment while sizing a change against the 1 MiB lowspec margin — the same margin both comments invoke as justification.
- **Consequence:** A maintainer budgeting ISO size from these comments under-counts the shipped preview payload by ~250 KB (a quarter of lowspec's entire remaining headroom) and over-counts the saving from omitting a mode by ~143 KB per mode. Nothing breaks today, but every size decision in this repo is made from these written figures.
- **Proposed fix:** Correct line 210 to the measured ~100 KB each / ~410 KB total, and correct iso/build.sh:247 to ~100 KB each. If the ~40 KB budget is the one actually wanted, generate the previews from an UNdithered render (dither is a 2560x1440 8-bit-panel banding fix and is meaningless at 640x360): keep the pre-dither composite from build() and downscale that, which removes the incompressible noise the LANCZOS pass currently preserves.

```
209: # Downscaled to 640x360, which is both plenty for a chooser thumbnail and a size
210: # WIN — the stale full-resolution copies were ~245 KB each; these are ~40 KB.
211: # That matters: lowspec clears the publish threshold by about 1 MiB.
...
236:             rendered[name].resize(PREVIEW_SIZE, Image.LANCZOS).save(path, optimize=True)

`rendered[name]` is the output of build(), which ends `return dither(img)` (line 196) — i.e. the per-pixel-noise version. Actual committed sizes: iso/calamares/branding/refractos/gaming.png 103856, ai.png 102386, server.png 102801, creative.png 102226 = 411,269 B total, vs the 4 x ~40 KB = ~160 KB the comment budgets. The figure was never true: commit e3c0
```

## 44. [LOW] Stale cache comment left behind by the cfeb8c0 revert describes an optimization that was deliberately removed
- **Where:** `branding/make-wallpapers.py`:220
- **Category:** stale-comment
- **Trigger:** Anyone reading main() to understand the caching strategy, e.g. while re-optimizing the ~11 s of redundant Gaussian blurs.
- **Consequence:** The comment asserts the ray cache is already the design, so the natural next edit is to "finish" it by hoisting the blur out of the strength multiply — reinstating exactly the change cfeb8c0 reverted, and silently altering the bytes of all six shipped wallpapers plus the four installer previews (up to 5/255 on ~13% of pixels), breaking byte-identical rebuilds that branding/README.md:64 promises.
- **Proposed fix:** Trim line 220-221 to what the code does: `# The emphasis-independent background (gradient + incoming beam) is composited once and reused by all six outputs; rays are re-rendered per output on purpose — see ray_layer's docstring for why strength must stay pre-blur.`

```
218: def main():
219:     os.makedirs(OUT, exist_ok=True)
220:     # Everything emphasis-independent, computed exactly once: the gradient with
221:     # the incoming beam screened in, and each ray blurred at full strength.
222:     cache = {"bg": ImageChops.screen(base_gradient(), incoming_beam())}

`cache` holds only "bg". No ray is cached: build() re-renders every ray at every strength on every one of the six outputs — line 195 `img = ImageChops.screen(img, ray_layer(i, k))`, and ray_layer applies strength BEFORE the blur (line 108-ish, `fill=tuple(round(c * strength) for c in colour)` then `layer.filter(ImageFilter.GaussianBlur(46))`). The ray cache existed only in the blur-linearity ref
```

## 45. [LOW] apply_theme reports "Applied <mode> look" even when every gsettings call silently failed for want of a session bus
- **Where:** `modes/modectl/distro-modectl`:437
- **Category:** misleading-success
- **Trigger:** Admin SSHes into a Refract box where the desktop user is NOT currently logged in (so systemd-logind has torn down /run/user/<uid>) and runs `sudo distro-modectl switch creative`. target_user resolves via SUDO_USER, so the no-desktop-user guard passes, but every gsettings/dconf write fails against the non-existent bus.
- **Consequence:** The switch prints `Applied Creative look: macOS-style (WhiteSur-Dark) + wallpaper, liquid-glass=false.` and `Now in: Creative mode`, and writes `creative` to the state file — yet no wallpaper, theme, icon theme, color-scheme or blur setting changed. Worse, the result is half-applied and reported as whole: apply_accent's `run_as_user tee` (line 392) is plain filesystem I/O and DOES succeed, so the GTK accent CSS flips to magenta while the wallpaper and shell theme stay on the previous mode. The user has no signal that anything went wrong.
- **Proposed fix:** Have run_as_user (or apply_theme) verify the bus socket exists — e.g. `[ -S "/run/user/${uid}/bus" ]` in the root branch, and check the exit status of at least the first gsettings call instead of `|| true` — and downgrade the line-437 message to a NOTE ("no live session for <user> — theme will apply on next login") when the session-bus writes did not land.

```
distro-modectl:417-426 — every call is swallowed:
        run_as_user gsettings set org.gnome.desktop.background picture-uri "file://$WALLPAPER" 2>/dev/null || true
        ...
    run_as_user gsettings set org.gnome.desktop.interface gtk-theme 'WhiteSur-Dark' 2>/dev/null || true
distro-modectl:437
    echo "Applied ${MODE_NAME} look: macOS-style (WhiteSur-Dark)${WALLPAPER:+ + wallpaper}, liquid-glass=${LIQUID_GLASS:-false}."
The only guards before this are `command -v gsettings` (411) and `[ -z "$(target_user)" ]` (412) — neither tests whether the bus at distro-modectl:148 (`unix:path=/run/user/${uid}/bus`) actually exists.
```

## 46. [LOW] tests/README.md's coverage table omits test_apply_mode_selection.sh and never mentions mode-mechanism.sh
- **Where:** `tests/README.md`:23
- **Category:** coverage-claim drift
- **Trigger:** Any contributor using tests/README.md as the coverage map — e.g. deciding whether distro-apply-mode-selection is tested before changing it, or running ./tests/run.sh and assuming that is the whole of tests/.
- **Consequence:** The one test that exercises a destructive installer helper is invisible in the coverage map, and the 5-mode contract harness looks absent to anyone who runs the documented `./tests/run.sh` — it only ever runs via a manual `workflow_dispatch` of mode-test.yml, so a regression in it can sit unnoticed indefinitely.
- **Proposed fix:** Add a `test_apply_mode_selection.sh` row (script under test: `distro-apply-mode-selection`; guards: literal `gs[...]` treated as empty, 0644 registry perms, whitelist/dedupe, HARD removal opt-in). Add a short section documenting `mode-mechanism.sh` — what it asserts, that run.sh deliberately excludes it, and how to run it (mode-test.yml's mechanism job). Correct the "gsettings/GNOME ... NOT here" sentence to scope it to the `test_*.sh` suite.

```
tests/README.md:23-33 is a nine-row table headed "## What's covered" listing test_modectl, test_gaming_compat, test_creative_scratch, test_ai_ask, test_cloud_toggle, test_detect_tier, test_ai_model, test_ai_setup, test_compat_db_schema — while `ls tests/test_*.sh` returns ten files. `test_apply_mode_selection.sh` (distro-apply-mode-selection, the Calamares mode-selection persistence + the destructive APPLY_HARD_REMOVAL path) has no row. tests/mode-mechanism.sh — 349 lines, the 5-mode contract harness — is not mentioned anywhere in the README, and tests/run.sh:16 globs only "$TESTS_DIR"/test_*.sh so it never runs locally. README:47-49 further says "The GPU-/desktop-/build-host-dependent scrip
```

## 47. [LOW] Assertion counts quoted in TODO.md, the Pi runbook and modes/ai/README.md have drifted well below the real totals
- **Where:** `TODO.md`:150
- **Category:** docs drift
- **Trigger:** Following docs/pi-test-runbook.md:15 on the Pi box: the runbook's "Expected" column tells the operator to look for ~190 assertions, and the suite prints per-file totals summing to ~261.
- **Consequence:** An operator running the documented acceptance check sees a number ~40% above the documented expectation and cannot tell whether the suite grew or something double-ran; the per-file numbers in TODO.md:40-41 are similarly unusable as a regression signal (a test file could lose 20 assertions and still "match" the doc).
- **Proposed fix:** Replace the hard numbers with the file count plus a pointer to the runner's own tally (`tests/run.sh` already prints "N/M assertions passed" per file), or refresh them to ≈261 total / ≈84 for test_detect_tier.sh / 41 for test_ai_model.sh and update modes/ai/README.md:215's "30+ assertions" at the same time.

```
TODO.md:150 "a stub-based suite (10 `test_*.sh` files, ~190 assertions)"; TODO.md:219 "— 10 files / ~190 assertions"; docs/pi-test-runbook.md:15 "| Full hermetic test suite on real Linux | `bash tests/run.sh` | 10/10 files, ~190 assertions pass |"; TODO.md:40 "`tests/test_detect_tier.sh`, 63 assertions"; TODO.md:41 "`tests/test_ai_model.sh`, 30 assertions". Counting the assertion call sites and expanding the helper/loop multipliers gives ≈261 total: test_detect_tier.sh ≈84 (38 direct + check_tier×17 + check_profile×5 + check_image×7 + gpu_case×5×2 + arc_tier×7), test_ai_model.sh 41, test_modectl.sh 49, test_ai_setup.sh 22, test_apply_mode_selection.sh 19, test_gaming_compat.sh 15, test_ai_as
```

## 48. [LOW] users.conf's defaultGroups drops Ubuntu's adm/cdrom/dip and substitutes groups that do not exist on Ubuntu
- **Where:** `iso/calamares/modules/users.conf`:2
- **Category:** correctness
- **Trigger:** Every install, every strain — the account created on the users page gets exactly this group list.
- **Consequence:** `adm` is missing. systemd's /usr/lib/tmpfiles.d/systemd.conf grants read ACLs on /var/log/journal to groups adm and wheel, and Ubuntu's /var/log/syslog is root:adm 0640 — so the primary user of a Refract install cannot read the system journal or syslog without sudo, unlike every stock Ubuntu install. That is a bad default for a distro whose whole story is mode-switching and diagnostics. `cdrom` (optical media) and `dip` (ppp/dialout) are also missing. Meanwhile `network` and `storage` are Arch conventions that do not exist on Ubuntu; Calamares' SetupGroupsJob will create them as empty groups that nothing consults. Lubuntu's noble users.conf, on the same base, is `adm, cdrom, dip, lpadmin, plugdev, sambashare(must_exist:false, system:true), sudo`.
- **Proposed fix:** Replace with Ubuntu's actual first-user set: sudo, adm, cdrom, dip, plugdev, lpadmin, and (as a map with must_exist:false, system:true) sambashare. Drop `network` and `storage`; keep `audio` and `video` only if a mode setup script actually depends on them.

```
users.conf:2-9
defaultGroups:
  - sudo
  - audio
  - video
  - network
  - storage
  - plugdev
  - lpadmin
```


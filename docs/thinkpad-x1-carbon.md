# Flashing Refract OS onto a ThinkPad X1 Carbon

The X1 Carbon is Refract's **first real-hardware target**, and it's a great one:
Intel CPU + Intel integrated graphics (no NVIDIA to fight), Intel WiFi, a
trackpad, and a fingerprint reader. Use the **`laptop`** strain — it ships the
Intel-laptop bits (`power-profiles-daemon`, `thermald`, Intel VAAPI video decode,
`fprintd` fingerprint stack, firmware) tuned for exactly this class of machine.

This is a general Intel-laptop guide too; the X1 is just the reference device.

## 0. Before you start

- **Back up the laptop.** Installing erases the target disk.
- You need the **`laptop`** ISO from the
  [Releases page](https://github.com/Mr-Pythoneer/refract-os/releases) (rejoin the
  `.part*` files: `cat refract-os-laptop.iso.part* > refract-os-laptop.iso`).
- A **USB stick** (8 GB+).

## 1. Write the ISO to USB

The ISO is a hybrid BIOS+UEFI image — write it raw, don't "burn files onto" the stick.

- **From macOS:** [balenaEtcher](https://etcher.balena.io/) is the no-footgun choice
  (pick the ISO, pick the USB, Flash). Or the CLI:
  ```sh
  diskutil list                      # find your USB, e.g. /dev/disk4
  diskutil unmountDisk /dev/disk4
  sudo dd if=refract-os-laptop.iso of=/dev/rdisk4 bs=4m status=progress
  ```
- **From Windows/Linux:** balenaEtcher, or `dd` on Linux.

## 2. ThinkPad firmware (BIOS) settings

Reboot the X1 and press **Enter** at the Lenovo splash → **F1** for BIOS setup
(or **F12** for a one-time boot menu). Then:

- **Secure Boot → Disabled.** Refract's bootloader isn't signed for Secure Boot
  yet, so the X1 won't boot the USB with it on. (Security → Secure Boot.)
- **Boot mode: UEFI** (the default on modern X1s — leave it). The ISO boots UEFI
  natively; you do **not** need Legacy/CSM.
- Optionally move **USB HDD** above the internal disk in the boot order, or just
  use the **F12** one-time boot menu and pick the USB stick.

Save & exit (**F10**).

## 3. Boot the live session (try before you install)

Pick the USB at boot. You'll land on the **Refract live desktop** (no Ubuntu setup
wizard — it's removed). Sanity-check the hardware that matters on a laptop *before*
committing to install:

- **WiFi:** click the top-right menu → is your network listed? (Intel `iwlwifi`
  firmware is baked in.)
- **Trackpad:** two-finger scroll, tap-to-click, natural scrolling should all feel
  right out of the box.
- **Display:** if the panel is HiDPI, **Settings → Displays** should offer
  fractional scaling (125% / 150%).
- **Battery:** the top-right menu shows a battery percentage.

If WiFi/trackpad/display look good live, they'll work installed.

## 4. Install

Launch **Install Refract OS** and follow the Calamares walkthrough — the per-page
steps are the same as the VM guide, so see
[`utm-guide.md` §5](utm-guide.md) for the click-through (Welcome → Location →
Keyboard → **Partitions: Erase disk** → Users → Install → Restart). On real
hardware the only difference is that **"Erase disk" erases the laptop's real SSD** —
make sure you backed up.

When it finishes: **Restart**, pull the USB at the Lenovo splash.

## 5. First boot — what works, and the one manual step

After install you boot straight to the WhiteSur macOS-style desktop (bottom dock,
prism wallpaper). On the X1:

| Works out of the box | Needs one action |
|---|---|
| WiFi, Bluetooth, trackpad gestures, display/scaling | **Fingerprint:** enroll it in **Settings → Users → Fingerprint Login** (the `fprintd` stack is installed; enrollment is per-user) |
| Hardware video decode (Intel VAAPI) — cool, quiet 4K playback | — |
| Suspend/resume on lid close (systemd/GNOME defaults) | — |
| `thermald` thermal management (keeps the thin chassis from throttling hard) | — |
| **⌘-style keys** via `keyd`: Super+C/V/X/A/Z/S = Ctrl (and Ctrl still works) | — |
| Firmware updates: run `fwupdmgr update` for Lenovo BIOS/EC updates | — |

There is **no NVIDIA driver step** — the X1 is Intel-only, and Refract's NVIDIA
installer refuses to run on a machine with no NVIDIA GPU, so nothing to do.

## 6. Pick a mode

```sh
sudo distro-modectl switch normal     # balanced everyday (the default look)
sudo distro-modectl switch creative   # for editing/CAD
sudo distro-modectl switch ai         # local AI — on the X1 this detects the CPU
                                      # tier (no GPU) and stays lightweight
```
On this Intel laptop the CPU governor is set correctly per mode
(`intel_pstate` only offers powersave/performance, and the switcher maps to those
automatically — no scary warnings), and power is managed by
`power-profiles-daemon`.

Optional local AI: `distro-ai-setup` (add `--install` to actually install LM Studio
+ a CPU-sized model). Expect small models only — the X1 has no discrete GPU.

## 7. Known caveats on the X1 specifically

- **Secure Boot stays off** until the bootloader is signed (roadmap item). If you
  turn it back on, the installed system may not boot.
- **Fingerprint sensor coverage varies by X1 generation** — most Synaptics/validity
  sensors work with the in-tree `libfprint`, but a few newer match-on-chip sensors
  don't yet. If enrollment fails, that sensor isn't supported yet upstream; nothing
  Refract can fix.
- **Fractional scaling** is enabled but verify 125%/150% actually appears in
  Settings on your panel — flag it if not.

Hit a snag? The mode-switcher and drivers all degrade gracefully and log what they
did; capture the terminal output and the `journalctl -b` tail.

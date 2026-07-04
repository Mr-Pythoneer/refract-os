# Hardware strains

A *strain* is a build-time hardware-class profile: what desktop environment
(if any) ships, and which packages are baked in by default. This is
deliberately separate from the 5 runtime *modes* (`modes/modectl/`) — every
strain still gets all 5 modes; a strain just decides what's a sensible
starting point for that class of machine.

| Strain | DE | Notes |
|---|---|---|
| `workstation` (default) | GNOME (`ubuntu-desktop-minimal`) | Full feature set, no special tuning |
| `laptop` | GNOME | + `power-profiles-daemon` power management (NOT tlp — conflicts with p-p-d on 24.04), `thermald`, `fprintd` (fingerprint), Intel VAAPI + firmware |
| `lowspec` | LXQt (`lubuntu-desktop`) | Lightest official Ubuntu DE; skips gamemode/mangohud/winetricks by default (added on-demand via `modes/gaming/setup/` if actually needed) |
| `server` | none | Headless; relies on `modes/server/setup/*.sh` post-boot, same lean-image philosophy as the rest of `iso/` |
| `handheld` | GNOME | Same package set as `workstation`; real differentiation is `handheld/setup-handheld-ui.sh` — on-screen keyboard, UI text scaling, Steam Big Picture autostart |
| `cloud` | none | `cloud-init` only. Real qcow2 delivery format: `iso/cloud-image/build-cloud-image.sh` (debootstrap + loop-device + grub-install + qemu-img convert), separate from this ISO pipeline entirely — see `iso/cloud-image/README.md` |

## Usage

```bash
./build.sh workstation   # or laptop | lowspec | server | handheld | cloud
```

`build.sh` copies the selected strain's `.list.chroot` into
`config/package-lists/` (deleting any other strain's leftover file first —
verified by actually running the copy/cleanup logic with a stubbed `lb`,
see TODO.md) before calling `lb config`/`lb build`. The strain name also
shows up in the ISO's `--iso-application` string and the output filename
(`refract-os-<strain>.iso`).

## What's real vs. what's a placeholder here

`workstation`/`laptop`/`lowspec`/`server` are real package-selection
differences. `handheld` now has real differentiation too, just not at the
package-list level — see `handheld/setup-handheld-ui.sh`
(execution-tested: root/session guards, on-screen keyboard + text-scaling
gsettings calls, and both the Steam-present and Steam-absent autostart
branches, all with stubbed `gsettings`/`steam`). `cloud` is still
scaffolding — its actual differentiation (a cloud-image delivery format
instead of an ISO) is unbuilt. Don't mistake "this strain exists in the
list" for "this strain is done." `cloud` now has a real (if unrun) delivery
pipeline too — see `iso/cloud-image/README.md`.

## Explicitly out of scope for this repo

ARM64 (Raspberry Pi-class), Apple Silicon, RISC-V — different CPU
architecture means a different kernel config, different bootloader
(u-boot, not GRUB), often cross-compilation, and a different image format
entirely. That's not a strain of this project, it's close to a separate
distro effort. Apple Silicon specifically would mean depending on the
Asahi Linux project's out-of-tree kernel work rather than anything live-build
provides. Flagging this so it's a deliberate, visible decision, not a
silent gap — see DESIGN.md.

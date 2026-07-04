# Try Refract OS in a VM with UTM (macOS)

You don't need a spare PC to try Refract — [UTM](https://mac.getutm.app/) runs it in a
virtual machine on your Mac. Two honest caveats up front:

- **Apple Silicon (M1–M4):** Refract is an **x86-64** OS, so UTM has to **emulate**
  x86 (it can't *virtualize* it on ARM). That works but is **slow** — fine for
  clicking around and testing the installer, not for real use or gaming.
- **Intel Mac:** UTM can virtualize x86 with near-native speed. Much nicer.

The ISO boots both **UEFI** and **legacy BIOS**, so UTM's default (UEFI) is fine.

## 1. Get the ISO (rejoin the parts)

The image is published in <2 GB parts on the
[Releases page](https://github.com/Mr-Pythoneer/refract-os/releases). Download every
`refract-os-workstation.iso.part*`, then rejoin:

```sh
cat refract-os-workstation.iso.part* > refract-os-workstation.iso
# optional: verify against the .sha256 in the release
shasum -a 256 refract-os-workstation.iso
```

## 2. Create the VM

1. Open UTM → **Create a New Virtual Machine** → **Emulate** (on Apple Silicon) or
   **Virtualize** (Intel Mac).
2. **Operating System:** *Other*.
3. **Architecture:** `x86_64` · **System:** `Standard PC (Q35 + ICH9)` ·
   **Memory:** `4096 MB` or more · **CPU cores:** 2–4.
4. **Storage:** create a `25 GB`+ virtual disk (this is where you'll install to).
5. **Shared/removable:** skip.
6. **Summary:** name it *Refract OS*, **Save**.

## 3. Attach the ISO and boot

1. Edit the VM → **Drives** → **New Drive** → **Removable / CD-ROM (USB or IDE)** →
   point it at your rejoined `refract-os-workstation.iso`.
2. Make sure the CD/ISO is **above the disk** in boot order (Drives list order), or
   use the UTM boot menu.
3. **Start** the VM. You'll land in the **live desktop** first (give emulation a few
   minutes on Apple Silicon).

## 4. Try it live first

You land on the **live desktop** without touching the disk. Poke around before you
commit to installing:

- The **dock** is macOS-style and auto-hides — push the cursor to the bottom edge to
  reveal it.
- Open a **Terminal** and try a mode switch: `sudo distro-modectl switch gaming`
  (in the VM it will print WARNINGs that it can't set a real CPU governor / power
  profile — that's expected; it still applies everything it can and switches).
- **Settings → About** should say *Refract OS* (not Ubuntu).
- There is **no "Welcome!" setup wizard** — if you ever see one, that's a bug (it was
  purged); the live session should drop you straight on the desktop.

## 5. Install it (the Calamares walkthrough)

Launch **Install Refract OS** — either the desktop icon or Activities → search
"Install". It opens as root (a polkit rule authorizes it automatically). It's a
~7-page wizard; here's each page and what to pick for a throwaway VM:

1. **Welcome** — pick your language → **Next**.
2. **Location** — pick your region/timezone (it usually auto-guesses) → **Next**.
3. **Keyboard** — pick your layout; use the test box to confirm → **Next**.
4. **Partitions** — the important one. Choose **Erase disk**. In a VM this only
   touches the *virtual* 25 GB disk you created, never your Mac. (Leave encryption
   off for a test; you can tick "Encrypt system" if you want to rehearse LUKS.)
   → **Next**.
5. **Users** — your name, a username, a password (tick *Log in automatically* if you
   want no login prompt), and a **hostname** (this becomes your machine name —
   e.g. `refract`, not `ubuntu`) → **Next**.
6. **Summary** — review; nothing is written until you click **Install**. → **Install**.
7. **Install progress** — the prism slideshow plays while it copies the system
   (a few minutes; longer under Apple-Silicon emulation).
8. **Finish** — tick **Restart now**, click **Done**.

Then **power off**, **remove the ISO drive** (Edit VM → Drives → delete the CD/ISO,
or it'll just boot the installer again), and **start** the VM to boot your installed
system.

## 6. First boot after install

- Log in (or straight to desktop if you enabled autologin). The WhiteSur macOS theme,
  bottom dock, and prism wallpaper are already applied.
- **⌘-style keys:** thanks to `keyd`, **Super+C / V / X / A / Z / S** act as Ctrl
  (copy/paste/etc., macOS muscle memory) — and plain Ctrl still works too.
- **Pick a mode** for what you're doing:
  `sudo distro-modectl switch normal|gaming|creative|server|ai`.
- **Set up local AI** (optional): run `distro-ai-setup` — it detects your hardware
  tier and, with `--install`, installs LM Studio + the models that fit. In a VM this
  detects the **cpu** tier (no GPU) and stays lightweight.

## What works in the VM vs. what needs a real box

| In the VM ✓ | Needs real hardware ✗ |
|---|---|
| Boot (UEFI+BIOS), desktop, the macOS-style shell, no setup wizard | GPU driver install (`-open` module) |
| The full installer (partition → install → reboot into your system) | LLM inference in AI mode (LM Studio + a GPU) |
| Mode switching (governor/service changes; degrade gracefully with no real hardware) | Real FPS / Proton games, NVENC encode |
| `keyd` ⌘ remap, theme, dock, `distro-ai-setup` cpu-tier detection | Fractional-scaling on a real HiDPI panel, fingerprint |

For anything in the right column you'll want an actual Nvidia/AMD box (or a real
laptop) — see [`first-hardware-runbook.md`](first-hardware-runbook.md). To flash a
real machine instead of a VM, see [`install.html`](install.html).

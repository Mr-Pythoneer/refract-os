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

## 4. Try it live, or install

- **Live:** poke around — the dock, the five modes (`distro-modectl switch gaming`
  in a terminal), Settings → About (says *Refract OS 1.0*).
- **Install:** launch **Install Refract OS** (Activities → search "Install"). Calamares
  walks language → keyboard → **partitioning** (pick *Erase disk* — it only touches the
  VM's virtual disk) → user account → install. When it finishes, **power off, remove
  the ISO drive**, and boot the installed disk.

## What works vs. what needs real hardware

| In the VM ✓ | Needs a real GPU box ✗ |
|---|---|
| Boot, desktop, the macOS-style shell | GPU driver install (`-open` module) |
| The installer (partition → install → reboot) | LLM inference in AI mode (LM Studio) |
| Mode switching (governor/service changes degrade gracefully with no real hardware) | Real FPS / Proton games, NVENC |

For anything in the right column you'll want an actual Nvidia/AMD box — see
[`first-hardware-runbook.md`](first-hardware-runbook.md).

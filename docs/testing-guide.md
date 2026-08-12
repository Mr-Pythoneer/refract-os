# Testing Refract OS with balenaEtcher

These are WIP builds. Nothing here has ever completed an install on real
hardware — that is exactly what you are testing.

**The installer erases the whole disk it installs to.** Use a spare machine, a
spare SSD, or a VM. Do not install on a machine whose contents you care about.
Booting the USB *without* installing is safe and changes nothing on the computer.

---

## 1. Download

Releases: <https://github.com/Mr-Pythoneer/refract-os/releases>

| Strain | Tag | Use it for |
|---|---|---|
| workstation | `latest-workstation` | Desktop/tower, dedicated GPU |
| laptop | `latest-laptop` | Laptops — power saving, fingerprint, Intel graphics |
| lowspec | `latest-lowspec` | Old or ≤4 GB RAM machines |
| server | `latest-server` | Headless, ships sshd |
| handheld | `latest-handheld` | Small-screen / gamepad devices |

`cloud` is a VM disk image (`.qcow2`), **not** flashable — ignore it here.

Each release has the image plus a `.sha256` file.

**If the file ends in `.xz`, do not decompress it.** Etcher expands it while
flashing. Only Ventoy/`dd` users need to decompress by hand.

### Verify the download (worth the 30 seconds)

macOS:
```bash
shasum -a 256 ~/Downloads/refract-os-laptop.iso
```

It must match the number in the `.sha256` file. If it doesn't, the download is
corrupt — re-download rather than flashing it, or you'll spend an hour debugging
a bad USB stick.

---

## 2. Flash with balenaEtcher

Get it from <https://etcher.balena.io/> — 8 GB USB stick or larger.

1. Open Etcher.
2. **Flash from file** → pick the `.iso` (or `.iso.xz`).
3. **Select target** → pick your USB stick.
   Read the drive name and size out loud before continuing. Etcher hides system
   drives by default, but an external backup drive shows up here like any other
   stick, and flashing wipes it completely.
4. **Flash!** → enter your Mac password when asked (it needs raw disk access).
5. Let it finish the **Validating** pass. Don't skip it — a silent bad write is
   indistinguishable from a Refract bug, and you'd be filing an issue against a
   corrupt stick.
6. macOS will pop up **"The disk you inserted was not readable by this
   computer."** That is expected and correct — macOS can't read Linux
   filesystems. Click **Eject**, not Initialise. Clicking Initialise destroys the
   stick you just wrote.

---

## 3. Boot it

Plug into the target machine, power on, and hold the boot-menu key:

| Make | Key |
|---|---|
| ThinkPad / Lenovo | `F12` (or `Enter` then `F12`) |
| Dell | `F12` |
| HP | `F9` |
| Acer / Asus | `F12` or `Esc` |
| Generic PC | `F11` / `F12` / `Esc` / `F8` |

Pick the USB entry. If there are two, **prefer the one that says UEFI** — that's
the path real machines use, and the one with the least testing so far.

**Secure Boot must be off.** These ISOs are not signed with a Microsoft-trusted
key. If the stick is skipped or you get a security error, disable Secure Boot in
BIOS/UEFI setup (usually `F2` or `Del` at power-on) and retry.

You should land on a desktop automatically, with no password prompt.

---

## 4. What to actually test

In rough priority order. Stop and file an issue the moment something breaks —
don't push through.

### A. Live desktop (safe, no disk changes)
- [ ] Boots to a desktop without asking for a password
- [ ] Wi-Fi/ethernet works; a website loads in Chrome
- [ ] Sound plays; volume keys work
- [ ] Screen resolution is correct (not stretched or 1024×768)
- [ ] Laptop: brightness keys, battery icon, trackpad gestures, suspend/resume on
      lid close
- [ ] Files, Terminal, Settings all open from the dock

### B. The installer — the big one
This has **never completed on real hardware**. Everything below is unproven.

- [ ] Double-click **Install Refract OS** — a window appears (no auth prompt that
      goes nowhere)
- [ ] Welcome / Locale / Keyboard pages work
- [ ] Partition page: pick **Erase disk**
- [ ] Users page: name, username, hostname, password all accept input
- [ ] **Look page** — brand new. Refract should already be selected. Do the
      preview images show? Do the four options look right?
- [ ] **Modes page** — tick one or more
- [ ] Summary, then **Install**
- [ ] It finishes without an error dialog ← *the thing most likely to fail*
- [ ] Reboot, remove USB, and it boots from the internal disk
- [ ] Your username and password work
- [ ] The layout you chose is actually what you get
- [ ] `distro-modectl status` and `distro-layoutctl status` report sensibly

### C. If the install fails
Grab the log before rebooting — it is the single most useful thing in an issue:

1. `Ctrl+Alt+F3` (a text console, auto-logged-in)
2. `sudo cp /root/.cache/calamares/session.log /tmp/`
3. Get it onto a USB stick, or just photograph the error dialog and the last
   screen of `sudo tail -50 /root/.cache/calamares/session.log`
4. `Ctrl+Alt+F2` returns to the desktop

Also useful: `lsblk -f` and `sudo sfdisk -l /dev/sda` (or `nvme0n1`).

---

## 5. Filing issues

<https://github.com/Mr-Pythoneer/refract-os/issues/new/choose> — pick **Test
report**. It prompts for what's needed.

Please include, always:
- **Which strain and release tag** (e.g. `latest-laptop`)
- **The machine** — make, model, CPU, GPU, RAM
- **UEFI or BIOS**, and whether Secure Boot was off
- **What you expected vs what happened**
- A **photo of the screen** if it's visual, or the Calamares log if it's an
  install failure

One issue per problem. Ten small issues are far more useful than one long one —
they can be closed independently as each is fixed.

Don't bother triaging or guessing causes. "The install died here, photo
attached" is a perfect issue.

---

## No hardware to spare?

`docs/utm-guide.md` runs the same ISO in a VM on your Mac. It won't catch
firmware, GPU or Wi-Fi bugs — the whole point of real hardware — but it does
exercise the full installer safely.

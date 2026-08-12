# Refract OS — where we stopped, 2026-08-12

Repo clean, `main` = `eeb300c`, pushed. Build `31577472078` in flight carrying the
partition fix; `install-smoke` auto-fires on it.

This file is the narrative log. The authoritative per-change log is the git
history — 35 commits since `ad57517`, ~977 lines of commit-body prose, each one
carrying the root cause it fixes. Every hook also carries a comment block naming
the failure it exists to prevent. This file exists so the *sequence* is readable
without replaying 35 commits.

---

## 1. The install path — the headline

**The installer had never once completed.** Not "was flaky" — had never worked,
on any strain, ever. Four distinct bugs stacked in series; each had to be cleared
before the next became visible. In order of discovery:

### a. The live session never created a user (`6feacdb`)

The ISO booted to a GDM prompt with no password that would work. Autologin was
configured and *was* embedded in the initrd — verified directly, which killed my
own initrd-staleness theory before it cost a rebuild.

Real cause: `keyd`'s upstream Makefile runs `groupadd keyd` with no `-r`, so it
took a **regular** GID — 1000 — at image build time. casper's `25adduser` then
calls `user-setup-apply`, which needs GID 1000 for the live user and aborts:

    fatal: The GID 1000 is already in use.

No live user → nothing to autologin as → GDM prompt. One line in
`iso/config/hooks/0410-keyd.chroot` pre-creates it as a *system* group:

    getent group keyd >/dev/null 2>&1 || groupadd -r keyd 2>/dev/null || true

### b. `rsync` was not in the image (`62ff7ad`)

Calamares' `unpackfs` shells out to `rsync`. It was in no package list and
nothing pulled it in transitively, so the job died with exit **127** and the
wizard showed *"Failed to unpack image… rsync failed with error code 127."*
Pinned `rsync` + `squashfs-tools` in `base.list.chroot`.

### c. `cryptsetup` was missing while the UI offered encryption (`fdc5418`)

`partition.conf` sets `luksGeneration: luks1` and the partition page shows
"Encrypt system" — but cryptsetup was absent. Anyone ticking that box got a
failed install, or a system that could not unlock its own root. Pinned
`cryptsetup` **and** `cryptsetup-initramfs` (the half people forget — without it
an encrypted install boots to a dead prompt).

### d. No partition was ever created — the real root cause (`eeb300c`)

With a/b/c cleared, `unpackfs` still failed with alternating rsync exit 10/11.
A `shellprocess_verifyroot` guard (`8623756`) proved why: `${ROOT}` was **not a
mount point**. Serial capture of Calamares' own log (`9c52c66`) confirmed the
target disk had *no partition table at all* — only `CreatePartitionTableJob` was
ever queued.

Traced to Ubuntu's Calamares patch
`enable-only-present-with-encryption-partitions.patch`. It declares

    bool partOnlyPresentWithEncryption;

in `PartitionLayout.h` with **no initialiser**. When no `partitionLayout:` key is
present, `init()` falls back to `addEntry( { FileSystem::Type::Unknown, "/", "100%" } )`
— which selects a 5-arg constructor the patch never updated. The member is
therefore **indeterminate**, and four separate guards of the form

    if ( luksPassphrase.isEmpty() && entry.partOnlyPresentWithEncryption ) continue;

skip the sole entry. Empty partition list → no partition → nothing to mount →
`unpackfs` rsyncs into the live RAM disk → ENOSPC.

Lubuntu never hits this because it always declares `partitionLayout:` explicitly.
So do we now, in `iso/calamares/modules/partition.conf`:

    partitionLayout:
      - name: "root"
        filesystem: "unknown"
        mountPoint: "/"
        size: "100%"

Two traps deliberately avoided:

- **`defaultPartitionTableType` is NOT pinned.** Leaving it unset is what selects
  gpt for EFI and msdos for BIOS. Pinning `msdos` would give every UEFI machine
  an MBR table — trading a VM bug for a real regression on the X1 Carbon.
- **`filesystem: "unknown"`, not `"ext4"`.** Hard-coding it silently kills the
  btrfs option; omitting the key entirely yields an *unformatted* root.

Three earlier theories were killed against verbatim source before this one
survived: `ChoicePage` short-circuiting (no early return exists; `dumpQueue`
proves execution passed `layoutApply`), bad geometry (a percent size cannot
compute to zero sectors — it would produce a *bogus* job, not none), and a
missing mkfs toolchain (asserted present in CI, `855b5ec`).

**Relapse detector added.** A malformed layout entry makes `init()` fall back to
the *same* broken path with an identical symptom, so `install-smoke` now greps
the serial log for `switching to default layout` and `size is invalid, skipping`
and fails loudly instead of burying it in 1500 lines.

### e. The installer shipped onto the systems it installed (`abd52fc`)

Calamares and its desktop launchers were copied to the target by `unpackfs`, so
every freshly installed machine carried an installer offering to install again.
`shellprocess_cleanup.conf` removes the launchers and purges calamares from the
target.

---

## 2. Bloat — measured, not asserted

The classic Ubuntu app bloat was already absent (thunderbird, libreoffice,
rhythmbox, cheese, shotwell, the games, simple-scan — all confirmed missing).
What remained was Canonical's service layer plus assets this distro replaced but
kept paying for. `0500-debloat.chroot` removes **331 MB**: snapd, firefox,
yaru-theme-icon, gcc-13/cpp-13, pocketsphinx-en-us, ubuntu-pro-client, whoopsie,
apport. Shipped image: **1,696 packages**.

**This hook deleted the entire desktop on its first attempt** (`cf05d26`).
`ubuntu-wallpapers` cascades to `gnome-shell`/`gdm3`; `cpp-13` also pulls `gdm3`.
The guard was blind because it matched only `Remv` lines and apt prints `Purg`
for purges. Worse: `verify-boot-fixes` **passed the desktop-less image**, because
it detects the desktop *from* the image and read "no gnome-shell" as "headless
strain → skip the GNOME assertions." It was found by looking at a screenshot.

Both fixed. The guard now matches `^(Remv|Purg)`, logs the full cascade instead
of discarding it, and — the part that actually matters — the hook **asserts the
outcome**: if the image had a desktop before the purges it must still have one
after, or the build fails. Verification cross-checks the strain manifest rather
than trusting the image.

---

## 3. The look — pivoted away from macOS-as-default

Original framing was a macOS clone. The user's actual intent was only the
"liquid glass" part, so the design changed: **Refract is its own look and the
default**, with the desktop style picked on the installer.

Four layouts in `modes/layouts/profiles/`: **refract** (default), **classic**,
**macos**, **minimal**. Selected via a Calamares `packagechooser` page, applied
on first login by `apply-layout-once`, switchable later with `distro-layoutctl`.

The reason this is more maintainable, not just different: refract/classic/minimal
use **Adwaita-dark**, which *is* what libadwaita renders natively — so GTK3 and
GTK4 agree by construction. Imitating another OS means fighting the toolkit on
every GNOME release, because GTK4/libadwaita deliberately ignores GTK themes.
macOS stays available as an explicit choice rather than something everyone
inherits. Window controls now follow the system default for the same reason
(`bc9960e`).

`distro-modectl`'s `apply_theme()` no longer hardcodes `MacTahoe-Dark`; it defers
to the active layout. Layout sets the liquid-glass baseline; mode gets the last
word (performance modes turn it off).

---

## 4. Defaults added this session

- **Google Chrome** as default browser (`8dd353f`), from Google's apt repo using
  a `signed-by` keyring, not deprecated `apt-key`. Writes
  `/etc/refract-chrome-installed` only when the binary genuinely exists, and
  debloat removes Firefox/snapd **only** if that stamp is present — a network
  hiccup fetching Google's key must not leave an image with no browser at all.
- **ufw** (`fa12c57`), default-deny inbound. The image measurably shipped with no
  firewall of any kind. The SSH allow rule is added **before** enabling, and only
  on strains that actually ship sshd — the reverse order is the classic way to
  lock an owner out of their own server between two commands.
- **App catalog + security posture** reported by CI (`d47b4fb`) so "what is
  installed and why" is answerable from a build log, not from memory.

---

## 5. CI honesty fixes

A recurring theme worth stating plainly: **several of these bugs were invisible
because the tests were structurally incapable of failing.**

- `install-smoke`'s install job was `continue-on-error` — a totally broken
  install stayed green. Removed.
- The libadwaita assertion tested a path `build.sh`'s accent bake always creates,
  so it passed vacuously (`ef14213`). It now tests the `assets/` dir, and
  currently **fails honestly** — MacTahoe's `-l` flag does not produce a GTK4
  config. Known-open, not hidden.
- The bloat report killed itself on `pipefail` + `head` SIGPIPE (`e4fb847`).
- A blind `Tab`+`Enter` fallback moved focus to **Cancel** — one keystroke from
  aborting the install it was meant to drive (`24792a1`). Now uses Alt+N
  accelerators.
- One `vncdo key super-Up` hung and consumed the entire 40-minute job budget
  (`6f3d2b5`). All VNC calls are now `timeout 45` and non-fatal.

Also worth recording: the four `install-smoke` runs that read as "cancelled" at
exactly 40m17s were not cancellations — that is `timeout-minutes: 40` expiring.

---

## Pick up here

1. **Verify the install.** Build `31577472078` → `install-smoke`. First thing to
   grep in the new serial log is `switching to default layout` (means the YAML
   was rejected and it relapsed into the broken fallback). If the partition is
   created, the next observables are `verifyroot` passing and `unpackfs` running
   against a real ext4 root; likeliest next failures are `bootloader`
   (grub-install), then `fstab`/`grubcfg`.
2. **Then: full fan-out bug check** for review — explicitly requested.
3. **Then: small stuff.** Dock Terminal never launches; duplicate installer
   entries; `docs/utm-guide.md` omits the Modes page; welcome image cropped left;
   MacTahoe libadwaita `-l` failure (above).
4. **User-owned, not ours:** issue 2 is the user booting an installed disk;
   issue 3 (republish all six strains) waits on that verdict.
5. **Releases have not updated since Aug 3** despite `publish_release=true` — the
   publish step may be failing silently. Unconfirmed.
6. **`.audit/audit-partial-2026-08-11.md`** — 48 raw findings (18 HIGH / 22
   MEDIUM / 8 LOW) from the deep audit, stopped mid-flight. Verification coverage
   is uneven; synthesis/dedup/critic never ran. Do NOT treat it as a fix list.
   Standout, already sanity-read: `modes/ai/setup/02-preload-models.sh` still
   defaults to the `max` tier, so an undetected 8 GB laptop pulls a 20 GB model
   and `distro-ai-model` then disagrees and downloads a second one. Same bug was
   fixed in `distro-ai-model` (`f160364`) but not in its mirror.
7. Still never done: **one human clicking through Calamares onto a real disk**,
   and one real Etcher flash from the ThinkPad.

## Open product decision

The website still carries the prism badge (`docs/logo.png` in the nav) the OS no
longer has. Removal was requested because it "caused too much trouble" at boot,
which does not apply to a web page — left alone deliberately, pending a call.

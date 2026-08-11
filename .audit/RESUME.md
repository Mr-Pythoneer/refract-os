# Refract OS — where we stopped, 2026-08-11

Work paused at the user's request. Repo clean, `main` = `ad57517`, pushed.

## The big result: the macOS look has never once shipped, and now does

Two separate environment landmines in WhiteSur's installer, both fixed, both
confirmed against real build logs.

1. **`bf54b34`** — `install.sh` sources `libs/lib-core.sh`, which opens
   `set -Eeo pipefail` then runs
   `MY_USERNAME="${SUDO_USER:-$(logname || echo "$USER")}"` followed by
   `getent passwd "$MY_USERNAME" | cut -d: -f6`. In a live-build chroot there is
   no `SUDO_USER`, `logname` fails (no controlling terminal) and `USER` is
   unset — so the name is empty, `getent passwd ""` exits 2, and errexit kills
   the installer at source time in ~27 ms with **zero output**.
   Fix: `export USER=root LOGNAME=root HOME=/root`.

2. **`ad57517`** — that fix got the banner printing but it still died 0.8 s
   later, silently. `install_themes()` → `start_animation()` → `setterm -cursor
   off`, which needs a real terminal the chroot does not have. Same errexit
   death, one function deeper.
   Fix: `--silent-mode`, upstream's own non-interactive path, which
   early-returns from `start_animation`/`stop_animation`. The old
   `script -qfec` pseudo-TTY fallback was removed — it failed identically,
   because the problem was never a missing pty. A traced retry now dumps the
   failing command so a third landmine is read off the log, not reverse
   engineered.

**Proof it works** (run 31457442471, new workstation build):
`Installing 'WhiteSur' themes… / Done! / WhiteSur-Dark GTK present — default
desktop renders macOS-style.`

**Proof the new assertion is not vacuous** (run 31457471459, *pre-fix* ISO):
GTK theme + shell theme FAIL, icons PASS, blur PASS, phantom-theme check PASS.
The icon/GTK asymmetry is exactly what the root cause predicts — the icon
installer does not source those libs, which is why icons always worked.

## Everything else that landed this session

| Commit | What |
|---|---|
| `99f5a78` | install-smoke's installed-disk assertion **could never pass** — the target boots its own GRUB with `quiet splash`, no `console=`, so the serial log was always empty and the grep only ever took its failure branch, which `continue-on-error` swallowed into green. Now injects a serial console via qemu-nbd into the test artifact only. Also killed `\bgdm3?\b` as a success marker (it matches `gdm3.service: Main process exited, status=1/FAILURE`). |
| `1856fba` | Hardened that nbd step: nbd-module diagnostics, `lsblk -P` instead of column-shift-prone parsing, accept btrfs/xfs/f2fs. |
| `b95bf25` | Omitted-mode leaks: the baked welcome PNG said "Five modes / Local-first AI" with an AI chip on a "provably AI-free" build; `show.qml`'s unstrippable intro slide promised Windows game compat no strain ships. Plus Normal's accent baked into `/etc/skel` — fresh installs had no accent at all. |
| `ea1f1f4` | `handheld` was byte-for-byte `workstation` (setup script existed, was never staged). Cloud qcow2 was plain Ubuntu with a Refract filename. |
| `b6ce565`, `6af3d1b`, `9bcc9da` | Doc status corrections. |

## Published releases

All six strains rebuilt and published from fixed HEADs. The three GNOME strains
(workstation/laptop/handheld) were rebuilt a second time to pick up `ad57517`,
so they are the ones carrying the working macOS look. lowspec/server/cloud never
had that hook (build.sh strips it for non-GNOME strains).

## Pick up here

1. **`.audit/audit-partial-2026-08-11.md`** — 48 raw findings (18 HIGH /
   22 MEDIUM / 8 LOW) from the deep audit, which was stopped mid-flight.
   Verification coverage is uneven and synthesis/dedup/critic never ran. Do NOT
   treat it as a fix list; re-verify each. The standout, already sanity-read:
   `modes/ai/setup/02-preload-models.sh` still defaults to the `max` tier, so an
   undetected 8 GB laptop pulls a 20 GB model, and `distro-ai-model` then
   disagrees and downloads a second one. The same bug was fixed in
   `distro-ai-model` (`f160364`) but not in its mirror.
2. **CI left running deliberately** (free, remote, results wait):
   - `install-smoke` 31457487068 — first ever end-to-end VNC-driven install
   - `verify-boot-fixes` 31459315239 — against the *fixed* workstation ISO
   - `boot-smoke` 31459320557 — same
   - build-lowspec 31455855439
   Check with `gh run list`.
3. Still never done: **one human clicking through Calamares onto a real disk**,
   and one real Etcher flash from the ThinkPad.

## Open product decision

The website still carries the prism badge (`docs/logo.png` in the nav) the OS no
longer has. Removal was requested because it "caused too much trouble" at boot,
which does not apply to a web page — left alone deliberately, pending a call.

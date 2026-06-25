# ISO build pipeline

live-build (`lb config`/`lb build`) skeleton per DESIGN.md §6.

```bash
./build.sh [workstation|laptop|lowspec|server|handheld|cloud]   # default: workstation
# MUST run on a real Debian/Ubuntu Linux host with live-build installed
```

See `strains/README.md` for what each hardware-class strain actually
includes — strains are a build-time hardware-class profile, separate from
the 5 runtime modes (`modes/modectl/`); every strain still gets all 5 modes.

## Architecture decision: lean baked image, heavy lifting stays post-boot

The ISO's chroot only gets packages that install cleanly from stock Ubuntu
repos (`main`/`restricted`/`universe`/`multiverse`) with no extra apt
sources — see `config/package-lists/*.list.chroot`. Everything that needs
its own repo, a Flatpak, or a GitHub-release fetch (Steam, Lutris,
Wine-staging, Proton-GE, Bottles, Docker, Netdata, FreeCAD, Blender,
Kdenlive, the WhiteSur theme, Crucible12 itself) is **not** baked into the
image — it's installed by the already-built `modes/*/setup/*.sh` scripts,
which `build.sh` copies into the image at `/opt/distro/modes/` so they're
available on first boot, run on demand rather than during the ISO build.

This was a deliberate scope decision, not a shortcut. live-build does have
a documented mechanism for adding extra apt repos at build time
(`config/archives/<name>.list.chroot` + `.key.chroot`, etc.) — **now
researched and verified** against Debian's own live-manual
(`customizing-package-installation`) rather than left unconfirmed: it's a
plain `deb` sources.list line plus an ASCII-armored GPG key file, file
names ending in `.chroot` (build-time) or `.binary` (shipped to the
running system's `/etc/apt/sources.list.d/`).

**Decision: not adopted, deliberately.** Every repo-dependent tool in this
project (Docker, Steam, Lutris, WineHQ, Proton-GE, the WhiteSur theme,
Netdata) belongs to a **mode**, and modes are opt-in/switchable at runtime
on any strain — strains are a build-time DE/package-selection profile,
deliberately orthogonal to modes (`strains/README.md`: "every strain still
gets all 5 modes"). Baking a mode's apt repo into specific strains' images
would reintroduce exactly the "strain gatekeeps what's possible" problem
that doc explicitly warns against, and would create a second, divergent
apt-source path that conflicts with the existing runtime ones (e.g.
`modes/server/setup/02-install-docker.sh` already writes its own
`/etc/apt/sources.list.d/docker.list` and key on first run). There's also
no package in `base.list.chroot` or any strain list that currently needs a
non-stock repo at all — see DESIGN.md §1 on why no separate Mesa/kernel PPA
is needed either. If a genuinely strain-universal (not mode-specific)
package ever needs a third-party repo, this is the real, now-confirmed
mechanism to reach for — using the same strain-conditional copy-in/cleanup
pattern `build.sh` already uses for Calamares and the casper-bottom hook.

## What's in here

- `build.sh` — copies `modes/` and `drivers/` from the repo root into
  `config/includes.chroot/opt/distro/` (symlinking `distro-modectl` and
  `distro-ai-preset` into `/usr/local/bin/` — as symlinks, not copies,
  since `distro-modectl` looks up its `profiles/` directory relative to
  its own location), then runs `lb config` + `lb build`.
- `config/package-lists/base.list.chroot` — universal CLI tools every
  strain needs regardless of DE/headless (curl, jq, git, build-essential,
  cmake, power-profiles-daemon, mokutil, ffmpeg, openssh-server)
- `strains/*.list.chroot` — per-strain DE choice + strain-specific packages
  (see `strains/README.md`); `build.sh` copies the selected one into
  `config/package-lists/strain-<name>.list.chroot` at build time, deleting
  any other strain's leftover copy first
- `config/includes.chroot/` — populated by `build.sh`, gitignored, not
  committed (avoids two copies of the same scripts drifting apart)

## CI: `.github/workflows/build-iso.yml`

A `workflow_dispatch`-only GitHub Actions workflow (strain chosen via a
dropdown input) that actually runs `./build.sh` on a real Ubuntu runner —
GitHub's `ubuntu-latest` runners have root and loop-device access, unlike
this Mac, so this is genuinely the first place the full pipeline CAN run,
not just another lint pass. Deliberately **not** wired to `push`/`schedule`:
the pipeline has never succeeded even once yet, so an automatic nightly
build would just be a guaranteed-red CI run with no information value
until a manual run actually gets it working. **Not yet triggered** — this
costs real CI minutes/runner time for a multi-stage live-build that may
take well over an hour and is unverified, so it's left for an explicit,
deliberate manual run rather than fired automatically as part of this
session's work.

## Status

**`lb build` itself has never run — at all.** live-build doesn't run on
macOS (debootstrap, chroot, bind-mounts), so only `lb config`'s arguments
and the file-copy mechanics have had any real execution. The new CI
workflow above is where that would actually get tested next.

What HAS actually been verified (not just read and assumed): the strain
selection logic itself — `build.sh`'s copy-in/clean-up of
`config/package-lists/strain-*.list.chroot` — by stubbing out `lb` as a
no-op and running `build.sh` for real with `lowspec` then `laptop`,
confirming the prior strain's file gets removed and only the new one is
present before each (fake) `lb config` call. That's the one piece of this
directory that's been execution-tested, not just written and hoped about.

Still unverified:
- [ ] Run `./build.sh` on an actual Ubuntu host, confirm `lb config`'s flags are still valid for the live-build version installed
- [ ] Confirm the resulting ISO boots in a VM at all, for each strain
- [ ] Confirm `lubuntu-desktop`/`ubuntu-desktop-minimal` are still the correct current metapackage names on whatever Ubuntu release is actually targeted
- [ ] Confirm `/opt/distro/modes/` and the `/usr/local/bin` symlinks land correctly and `distro-modectl status` works on first boot
- [x] `config/archives/` decision made and documented above (not adopted — see "Architecture decision")

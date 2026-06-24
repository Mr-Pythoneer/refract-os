# ISO build pipeline

live-build (`lb config`/`lb build`) skeleton per DESIGN.md §6.

```bash
./build.sh   # MUST run on a real Debian/Ubuntu Linux host with live-build installed
```

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

This was a deliberate scope decision, not a shortcut: live-build has a
documented mechanism for adding extra apt repos at build time
(`config/archives/`), but I don't have a live-build host to verify the
exact current syntax against, and shipping a guessed-at config for that
mechanism would be exactly the kind of unverified-but-confident-looking
file this project is trying to avoid (same principle as the `modes/*`
READMEs' "don't fabricate dconf keys" stance). Plain package lists and
file copies (`includes.chroot`) are mechanisms I'm confident about; the
apt-archives mechanism is not, so it's deferred to whoever next has an
actual build host to test against.

## What's in here

- `build.sh` — copies `modes/` and `drivers/` from the repo root into
  `config/includes.chroot/opt/distro/` (symlinking `distro-modectl` and
  `distro-ai-preset` into `/usr/local/bin/` — as symlinks, not copies,
  since `distro-modectl` looks up its `profiles/` directory relative to
  its own location), then runs `lb config` + `lb build`.
- `config/package-lists/base.list.chroot` — tools every mode depends on
  (curl, jq, git, build-essential, cmake, power-profiles-daemon, flatpak,
  gnome-shell-extensions, gnome-tweaks, mokutil, ffmpeg, openssh-server)
- `config/package-lists/gaming.list.chroot` — gamemode, mangohud,
  winetricks (the only Gaming-mode pieces that need no extra repo)
- `config/includes.chroot/` — populated by `build.sh`, gitignored, not
  committed (avoids two copies of the same scripts drifting apart)

## Status

**Not yet run — at all.** live-build doesn't run on macOS (debootstrap,
chroot, bind-mounts), so this has had zero real execution, only careful
reading of `lb`'s documented behavior. Before trusting this:

- [ ] Run `./build.sh` on an actual Ubuntu host, confirm `lb config`'s flags are still valid for the live-build version installed
- [ ] Confirm the resulting ISO boots in a VM at all
- [ ] Confirm `/opt/distro/modes/` and the `/usr/local/bin` symlinks land correctly and `distro-modectl status` works on first boot
- [ ] Decide whether to invest in the `config/archives/` mechanism later to bake Docker/Steam/etc. in at build time instead of post-boot, once someone can verify it against a real build host

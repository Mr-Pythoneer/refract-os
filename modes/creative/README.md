# Creative mode

CAD + video editing per DESIGN.md §4 (detailed section: "Creative mode, detailed: CAD + video editing focus"). Run in order:

```bash
./setup/01-install-freecad.sh
./setup/02-install-blender.sh
./setup/03-install-kdenlive.sh
./setup/04-install-davinci-resolve.sh /path/to/downloaded.zip   # manual download required, see below
./setup/05-install-ffmpeg-nvenc.sh
./setup/verify-creative.sh

sudo ./bin/distro-creative-scratch setup   # see "Scratch-disk / cache path defaults" below
```

## What's covered, and what's explicitly NOT promised

Matches DESIGN.md's stance exactly: native, working apps are the pitch — Windows CAD/video apps under Wine are not.

- **FreeCAD** — Flatpak, native, full parametric CAD
- **Blender** — Flatpak, native, modeling/CAD-adjacent + full render pipeline
- **Kdenlive** — Flatpak, native, lighter video editor
- **DaVinci Resolve** — official native Linux build, headline video app. **Cannot be auto-downloaded**: Blackmagic Design requires an email registration on their site before generating a download link, so there's no stable URL to curl. `04-install-davinci-resolve.sh` takes a path to a .zip you download yourself once, then handles extraction + running BMD's own `.run` installer.
- **ffmpeg with NVENC/NVDEC** — Ubuntu's repo build typically lacks NVENC (build-dependency/licensing reasons). The script checks the system ffmpeg first, and if it's missing NVENC, fetches BtbN's prebuilt static Linux build (which does include it) rather than building from source. The download is integrity-checked against BtbN's `checksums.sha256` manifest before install.

**Not attempted, by design**: SolidWorks, AutoCAD, Premiere Pro, After Effects under Wine. DESIGN.md §4 covers why — DRM, .NET dependencies, and plugin-architecture issues that even CodeWeavers (CrossOver, years of dedicated AutoCAD-support work) hasn't fully solved. Promising these would repeat the same overreach risk flagged for "every Windows app" in DESIGN.md §2. Fusion 360's browser/cloud tier is the one realistic path for CAD users who specifically need an Autodesk product, and it sidesteps Wine entirely.

## Scratch-disk / cache path defaults

`bin/distro-creative-scratch` — per DESIGN.md §4 ("scratch-disk/cache paths
defaulting to the fastest local NVMe"):

```bash
distro-creative-scratch detect   # print the best local mount, do nothing else
distro-creative-scratch setup    # create the scratch dir + wire it up
```

Detection: `df -lP` (local filesystems only) for every mounted filesystem +
free space, cross-checked against `lsblk -ndo ROTA` on each mount's backing
device to find non-rotational storage, preferring devices named `nvme*`
over any other SSD, and the most free space within whichever tier is
available. Falls back honestly (with a stderr note) to a non-NVMe SSD if no
NVMe exists, or to `/var/tmp` if nothing non-rotational is found at all —
never silently picks a spinning disk without saying so.

`setup` creates the scratch directory, exports `CRUCIBLE_SCRATCH_DIR` via
`/etc/profile.d/`, and best-effort sets Blender's temporary-files
preference via `blender --background --python-expr`. DaVinci Resolve and
ffmpeg have **no scriptable way to set this** (Resolve's cache/working-folder
paths are a per-project GUI setting stored in its project database; ffmpeg
has no dedicated scratch-dir flag) — both are flagged honestly rather than
faking automation, with manual instructions printed instead.

Execution-tested (bash 5, stubbed `df`/`lsblk`/`blender`) across: NVMe-present
selection by free space, NVMe-absent SSD fallback, no-SSD-at-all fallback,
and both the Blender-success and Blender-failure setup paths (confirming the
script still exits 0 when the non-fatal Blender step fails).

## Known gaps / unverified

- `01-install-freecad.sh`'s Flathub app ID guess (tries `org.freecad.FreeCAD` then falls back to `org.freecadweb.FreeCAD`, then a live search) — FreeCAD rebranded their Flathub ID around the 0.21 release and I'm not certain which is current as of whenever this actually runs. The script handles either outcome instead of assuming.
- Nothing here has run against a real Nvidia GPU yet (NVENC check, Resolve's GPU dependency) — same hardware-availability gap as everywhere else in this repo.
- Color-managed display profile loading — now **scaffolded** as `bin/distro-creative-color` (colord/colormgr import + assign-to-default-display; web-verified command sequence). It can only be *run* on a machine with a real connected monitor + a measured `.icc` profile and colord running — so it's a correct, parameterized scaffold, not something verifiable headless. Usage: `distro-creative-color apply <profile.icc>`.

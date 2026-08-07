# Brand assets

Real, version-controlled sources for Refract OS's logo, Calamares welcome
banner and desktop wallpapers.

The motif is a **prism**: one white beam enters, and five coloured rays leave
it — the five modes. Geometry is solved, not eyeballed (equilateral triangle,
beam entering and exiting on real faces, rays fanning in true dispersion order
with red deviating least and magenta most), and the five hexes are identical
everywhere they appear: logo, wallpapers, installer, `docs/index.html`'s
`--m-*` tokens, and `modes/modectl/profiles/*.conf`'s `ACCENT`.

> This file used to describe a *"refract-vessel motif (molten glow, twin
> handles, rising sparks)"*. That was the pre-prism identity, and
> `src/welcome.svg` was still drawing it — so the installer shipped a logo the
> product no longer used, in five colours that matched nothing. Both are fixed;
> the note stays as a reminder that these assets drift silently because nobody
> looks at a PNG in a diff.

- `src/logo.svg` — circular badge, used as both Calamares' `productLogo`
  and `productIcon`
- `src/welcome.svg` — wide banner with the mark, wordmark and the 5 labelled
  mode colour chips, used as Calamares' `productWelcome`
- `make-wallpapers.py` — generates the six desktop wallpapers (see below)

## Building

```bash
./build.sh
```

Rasterizes both SVGs to PNG and copies them into
`iso/calamares/branding/refractos/` (the paths `branding.desc` expects),
plus a square `favicon.png` for the website (`docs/favicon.png`,
`docs/logo.png` — copied in manually, not by this script, since wiring them
into `docs/index.html` is a website-content decision).

Built/verified on macOS using `qlmanage -t` (QuickLook's bundled thumbnail
generator) as the SVG rasterizer, since no CLI SVG tool (`rsvg-convert`,
Inkscape, `cairosvg`) is installed here. `qlmanage` always pads non-square
input to a square canvas — `build.sh` detects and crops that letterboxing
back out automatically based on each SVG's actual aspect ratio, rather than
hand-coded crop offsets that would silently break if a source SVG's
proportions ever change. Verified output dimensions: `logo.png` 512×512,
`welcome.png` 1024×460, `favicon.png` 256×256 — all confirmed via Pillow
after a real run, not just asserted.

**On a real Linux box**, swap to `rsvg-convert -w W -h H src/X.svg -o
out/X.png` instead — it's the standard tool there, doesn't need the
letterbox-crop workaround, and should be considered the long-term path once
this repo is actually built/maintained from Linux rather than this Mac.

## Wallpapers

```bash
python3 make-wallpapers.py
```

Writes `out/wallpapers/{base,normal,gaming,ai,server,creative}.png` at
2560×1440. `iso/build.sh` copies them to `/usr/share/backgrounds/refract/`,
and `base.png` additionally becomes the GNOME/login default.

Needs only Pillow — no SVG rasterizer, so it runs the same on macOS and Linux.
Output is deterministic (fixed dither seed), so a rebuild is byte-identical.

**Why they carry no text or logo.** The previous wallpapers put the mark, the
wordmark in tracked-out caps *and* the marketing tagline in a centred stack on
the desktop. No shipping OS does that — macOS ships abstract art, Windows ships
the bloom — because the wallpaper is the surface you stare at all day, not ad
space, and branding on it is the loudest "hobby distro" signal a desktop can
send. The brand idea survives as the *artwork*: the beam, the implied prism and
the dispersed rays. Each mode's wallpaper is the same composition with that
mode's ray brought up and the others dimmed, so switching modes reads as one
system in a different state rather than six unrelated pictures.

They are also built to sit *behind* things: dark and quiet through the middle
where windows land, interest pushed off-centre, peak brightness held well under
white so text on top always wins, and lightly dithered because wide dark
gradients band badly on 8-bit panels.

## Status

Built and visually reviewed (rendered + read back as images during
this work) — not yet seen rendered inside an actual Calamares run, which
needs the real installer test pass tracked in `iso/calamares/README.md`.
